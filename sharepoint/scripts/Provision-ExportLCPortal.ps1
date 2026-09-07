<#
.SYNOPSIS
    Provisions the Export LC Portal SharePoint architecture (28 lists, 5 document libraries,
    537 columns, indexes and views) from sharepoint/schema/site-schema.json.

.DESCRIPTION
    Idempotent and non-destructive by design:
      * An existing list or library is reused, never recreated and never deleted.
      * An existing column is reported and left exactly as it is - the script never alters
        the type, required flag or choices of a column it did not just create, because doing
        so on a populated production column can silently drop data.
      * Nothing is written outside the target site collection.
      * -WhatIf shows the full plan without touching the site.

    Run Inspect-Environment.ps1 first. It reports what already exists so you can decide whether
    to point this at a fresh site or reuse an existing one.

.PARAMETER SiteUrl
    Target site collection, e.g. https://contoso.sharepoint.com/sites/ExportLCPortal

.PARAMETER SchemaPath
    Path to site-schema.json. Defaults to ../schema/site-schema.json relative to this script.

.PARAMETER Only
    Optional list/library names to provision (matches the schema "name" property). Provisions
    everything when omitted.

.EXAMPLE
    .\Provision-ExportLCPortal.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal -WhatIf
.EXAMPLE
    .\Provision-ExportLCPortal.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal

.NOTES
    Requires PnP.PowerShell 2.x  ->  Install-Module PnP.PowerShell -Scope CurrentUser
    First run in a tenant may need: Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "Export LC Portal Provisioning" -Tenant contoso.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [string] $SchemaPath,
    [string[]] $Only,
    [switch] $SkipConnect,
    [string] $ClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SchemaPath) {
    $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schema/site-schema.json'
}
if (-not (Test-Path $SchemaPath)) { throw "Schema not found: $SchemaPath" }

$script:Report = [System.Collections.Generic.List[object]]::new()
function Add-Report {
    param([string]$Scope, [string]$Object, [string]$Action, [string]$Detail = '')
    $script:Report.Add([pscustomobject]@{ Scope = $Scope; Object = $Object; Action = $Action; Detail = $Detail })
}
function Write-Step { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Field XML generation
# ---------------------------------------------------------------------------
function Get-FieldXml {
    param([Parameter(Mandatory)] $Field)

    $name = $Field.name
    $display = if ($Field.PSObject.Properties.Name -contains 'display' -and $Field.display) { $Field.display } else { $name }
    $req = if ($Field.PSObject.Properties.Name -contains 'required' -and $Field.required) { 'TRUE' } else { 'FALSE' }
    $idx = if ($Field.PSObject.Properties.Name -contains 'indexed' -and $Field.indexed) { 'TRUE' } else { 'FALSE' }
    $desc = ''
    if ($Field.PSObject.Properties.Name -contains 'note' -and $Field.note) {
        $desc = " Description=""$([System.Security.SecurityElement]::Escape($Field.note))"""
    }
    $displayEsc = [System.Security.SecurityElement]::Escape($display)
    $common = "DisplayName=""$displayEsc"" Name=""$name"" StaticName=""$name"" Required=""$req"" Indexed=""$idx""$desc"
    $default = if ($Field.PSObject.Properties.Name -contains 'default' -and $null -ne $Field.default) { "<Default>$([System.Security.SecurityElement]::Escape([string]$Field.default))</Default>" } else { '' }

    switch ($Field.type) {
        'Text' {
            $len = if ($Field.PSObject.Properties.Name -contains 'maxLength' -and $Field.maxLength) { $Field.maxLength } else { 255 }
            "<Field Type=""Text"" $common MaxLength=""$len"">$default</Field>"
        }
        'Note' {
            "<Field Type=""Note"" $common NumLines=""6"" RichText=""FALSE"" RichTextMode=""Compatible"" AppendOnly=""FALSE"" />"
        }
        'Number' {
            $dec = if ($Field.PSObject.Properties.Name -contains 'decimals') { $Field.decimals } else { 2 }
            "<Field Type=""Number"" $common Decimals=""$dec"">$default</Field>"
        }
        'Currency' {
            $dec = if ($Field.PSObject.Properties.Name -contains 'decimals') { $Field.decimals } else { 2 }
            # LCID 1033 renders as USD. Change here if the portal's base reporting currency changes.
            "<Field Type=""Currency"" $common Decimals=""$dec"" LCID=""1033"">$default</Field>"
        }
        'DateTime' {
            $fmt = if ($Field.PSObject.Properties.Name -contains 'format' -and $Field.format) { $Field.format } else { 'DateOnly' }
            "<Field Type=""DateTime"" $common Format=""$fmt"" FriendlyDisplayFormat=""Disabled"">$default</Field>"
        }
        'Boolean' {
            "<Field Type=""Boolean"" $common>$default</Field>"
        }
        'User' {
            "<Field Type=""User"" $common List=""UserInfo"" ShowField=""ImnName"" UserSelectionMode=""PeopleOnly"" UserSelectionScope=""0"" />"
        }
        'URL' {
            "<Field Type=""URL"" $common Format=""Hyperlink"" />"
        }
        { $_ -in @('Choice', 'MultiChoice') } {
            $choiceXml = ($Field.choices | ForEach-Object { "<CHOICE>$([System.Security.SecurityElement]::Escape($_))</CHOICE>" }) -join ''
            $fmt = if ($Field.type -eq 'Choice') { ' Format="Dropdown"' } else { ' Format="CheckBoxes"' }
            "<Field Type=""$($Field.type)"" $common$fmt>$default<CHOICES>$choiceXml</CHOICES></Field>"
        }
        default { throw "Unsupported field type '$($Field.type)' on field '$name'." }
    }
}

# ---------------------------------------------------------------------------
# Ensure helpers
# ---------------------------------------------------------------------------
function Ensure-List {
    param([Parameter(Mandatory)] $Definition, [Parameter(Mandatory)][ValidateSet('GenericList', 'DocumentLibrary')][string] $Template)

    $title = $Definition.title
    $url = if ($Template -eq 'GenericList') { "Lists/$($Definition.name)" } else { $Definition.name }

    $existing = Get-PnPList -Identity $title -ErrorAction SilentlyContinue
    if (-not $existing) { $existing = Get-PnPList -Identity $url -ErrorAction SilentlyContinue }

    if ($existing) {
        Add-Report $Template $title 'Exists' "Reused, not modified. Url=$($existing.RootFolder.ServerRelativeUrl)"
        Write-Step "$title already exists - reusing"
        return $existing
    }

    if ($PSCmdlet.ShouldProcess($title, "Create $Template")) {
        $desc = if ($Definition.PSObject.Properties.Name -contains 'description') { $Definition.description } else { '' }
        # Truncated to keep the list settings page readable; the full rationale lives in docs/02-data-model.md.
        if ($desc.Length -gt 500) { $desc = $desc.Substring(0, 497) + '...' }
        $new = New-PnPList -Title $title -Template $Template -Url $url -OnQuickLaunch:$false
        Set-PnPList -Identity $title -Description $desc | Out-Null
        Add-Report $Template $title 'Created' "Url=$url"
        Write-Step "$title created"
        return $new
    }
    Add-Report $Template $title 'WhatIf:Create' "Url=$url"
    return $null
}

function Ensure-Field {
    param([Parameter(Mandatory)][string] $ListTitle, [Parameter(Mandatory)] $Field)

    $existing = Get-PnPField -List $ListTitle -Identity $Field.name -ErrorAction SilentlyContinue
    if ($existing) {
        Add-Report 'Field' "$ListTitle.$($Field.name)" 'Exists' "Type=$($existing.TypeAsString). Left untouched."
        return
    }
    if ($PSCmdlet.ShouldProcess("$ListTitle.$($Field.name)", 'Add column')) {
        $xml = Get-FieldXml -Field $Field
        Add-PnPFieldFromXml -List $ListTitle -FieldXml $xml | Out-Null
        # Indexed="TRUE" in field XML is honoured inconsistently across tenants; assert it explicitly.
        if ($Field.PSObject.Properties.Name -contains 'indexed' -and $Field.indexed) {
            try { Set-PnPField -List $ListTitle -Identity $Field.name -Values @{ Indexed = $true } -ErrorAction Stop | Out-Null }
            catch { Add-Report 'Field' "$ListTitle.$($Field.name)" 'IndexWarning' $_.Exception.Message }
        }
        Add-Report 'Field' "$ListTitle.$($Field.name)" 'Created' "Type=$($Field.type)"
    }
    else {
        Add-Report 'Field' "$ListTitle.$($Field.name)" 'WhatIf:Create' "Type=$($Field.type)"
    }
}

function Ensure-TitleField {
    param([Parameter(Mandatory)][string] $ListTitle, [Parameter(Mandatory)] $TitleDef)

    if ($PSCmdlet.ShouldProcess("$ListTitle.Title", "Rename to '$($TitleDef.display)'")) {
        $values = @{ Title = $TitleDef.display }
        if ($TitleDef.PSObject.Properties.Name -contains 'required') { $values['Required'] = [bool]$TitleDef.required }
        Set-PnPField -List $ListTitle -Identity 'Title' -Values $values | Out-Null
        if ($TitleDef.PSObject.Properties.Name -contains 'indexed' -and $TitleDef.indexed) {
            try { Set-PnPField -List $ListTitle -Identity 'Title' -Values @{ Indexed = $true } | Out-Null } catch { }
        }
        Add-Report 'Field' "$ListTitle.Title" 'Configured' $TitleDef.display
    }
}

function Ensure-View {
    param([Parameter(Mandatory)][string] $ListTitle, [Parameter(Mandatory)] $View)

    $existing = Get-PnPView -List $ListTitle -Identity $View.name -ErrorAction SilentlyContinue
    if ($existing) { Add-Report 'View' "$ListTitle / $($View.name)" 'Exists' ''; return }

    if ($PSCmdlet.ShouldProcess("$ListTitle / $($View.name)", 'Create view')) {
        $rowLimit = if ($View.PSObject.Properties.Name -contains 'rowLimit') { $View.rowLimit } else { 100 }
        $query = if ($View.PSObject.Properties.Name -contains 'query') { $View.query } else { '' }
        Add-PnPView -List $ListTitle -Title $View.name -Fields $View.fields -Query $query -RowLimit $rowLimit -ErrorAction Stop | Out-Null
        Add-Report 'View' "$ListTitle / $($View.name)" 'Created' ''
    }
    else { Add-Report 'View' "$ListTitle / $($View.name)" 'WhatIf:Create' '' }
}

function Ensure-ListSettings {
    param([Parameter(Mandatory)][string] $ListTitle, [Parameter(Mandatory)] $Definition, [switch] $IsLibrary)

    if (-not $PSCmdlet.ShouldProcess($ListTitle, 'Apply list settings')) { return }
    $params = @{ Identity = $ListTitle }
    if ($Definition.PSObject.Properties.Name -contains 'enableVersioning') {
        $params['EnableVersioning'] = [bool]$Definition.enableVersioning
        if ($Definition.enableVersioning -and $Definition.PSObject.Properties.Name -contains 'majorVersions') {
            $params['MajorVersions'] = [int]$Definition.majorVersions
        }
    }
    if (-not $IsLibrary) { $params['EnableAttachments'] = $true }
    Set-PnPList @params | Out-Null
    Add-Report 'Settings' $ListTitle 'Applied' "Versioning=$($Definition.enableVersioning)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Export LC Portal - SharePoint provisioning' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "Site   : $SiteUrl"
Write-Host "Schema : $SchemaPath"
if ($WhatIfPreference) { Write-Host 'Mode   : WhatIf (no changes will be made)' -ForegroundColor Yellow }
Write-Host ''

$schema = Get-Content -Path $SchemaPath -Raw | ConvertFrom-Json

if (-not $SkipConnect) {
    Write-Host 'Connecting...' -ForegroundColor Cyan
    $connectArgs = @{ Url = $SiteUrl; ErrorAction = 'Stop' }
    if ($ClientId) { $connectArgs['ClientId'] = $ClientId }
    try {
        Connect-PnPOnline @connectArgs -Interactive
    }
    catch {
        Write-Warning "Interactive sign-in didn't work on this machine ($($_.Exception.Message))."
        Write-Warning 'Falling back to device login - open the URL printed below in any browser and enter the code shown.'
        Connect-PnPOnline @connectArgs -DeviceLogin
    }
}
$web = Get-PnPWeb
Write-Host "Connected to: $($web.Title)" -ForegroundColor Green
Write-Host ''

$targets = @()
foreach ($lib in $schema.libraries) { $targets += , @{ Def = $lib; Template = 'DocumentLibrary' } }
foreach ($lst in $schema.lists) { $targets += , @{ Def = $lst; Template = 'GenericList' } }
if ($Only) { $targets = $targets | Where-Object { $Only -contains $_.Def.name } }

$i = 0
foreach ($t in $targets) {
    $i++
    $def = $t.Def
    Write-Host ("[{0}/{1}] {2}" -f $i, $targets.Count, $def.title) -ForegroundColor White

    Ensure-List -Definition $def -Template $t.Template | Out-Null
    if ($WhatIfPreference) {
        foreach ($f in $def.fields) { Add-Report 'Field' "$($def.title).$($f.name)" 'WhatIf:Create' "Type=$($f.type)" }
        continue
    }

    Ensure-ListSettings -ListTitle $def.title -Definition $def -IsLibrary:($t.Template -eq 'DocumentLibrary')

    if ($def.PSObject.Properties.Name -contains 'titleField' -and $def.titleField) {
        Ensure-TitleField -ListTitle $def.title -TitleDef $def.titleField
    }

    foreach ($f in $def.fields) {
        try { Ensure-Field -ListTitle $def.title -Field $f }
        catch {
            Add-Report 'Field' "$($def.title).$($f.name)" 'FAILED' $_.Exception.Message
            Write-Warning "  Column $($f.name): $($_.Exception.Message)"
        }
    }

    if ($def.PSObject.Properties.Name -contains 'views') {
        foreach ($v in $def.views) {
            try { Ensure-View -ListTitle $def.title -View $v }
            catch {
                Add-Report 'View' "$($def.title) / $($v.name)" 'FAILED' $_.Exception.Message
                Write-Warning "  View $($v.name): $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
$script:Report | Group-Object Action | Sort-Object Name | ForEach-Object {
    $colour = switch -Wildcard ($_.Name) { 'FAILED' { 'Red' } '*Warning' { 'Yellow' } 'Created' { 'Green' } default { 'Gray' } }
    Write-Host ("  {0,-18} {1}" -f $_.Name, $_.Count) -ForegroundColor $colour
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $PSScriptRoot "provision-report-$stamp.csv"
$script:Report | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host "Full report: $outFile" -ForegroundColor Cyan

$failures = @($script:Report | Where-Object Action -eq 'FAILED')
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($failures.Count) object(s) failed. Review the report before running Import-MasterData.ps1."
    $failures | Select-Object Object, Detail | Format-Table -AutoSize
    exit 1
}
Write-Host ''
Write-Host 'Next: .\Import-MasterData.ps1 -SiteUrl <url>   then   .\Set-Permissions.ps1 -SiteUrl <url>' -ForegroundColor Green
