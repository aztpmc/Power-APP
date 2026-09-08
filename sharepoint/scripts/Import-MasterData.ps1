<#
.SYNOPSIS
    Loads the master data CSVs in sharepoint/masterdata into their SharePoint lists.

.DESCRIPTION
    Idempotent: each row is matched on the list's natural key and updated in place if it exists,
    added if it does not. Nothing is ever deleted, so a row an admin has customised in SharePoint
    is updated field-by-field rather than replaced, and a row an admin has added by hand is left
    alone entirely.

    -WhatIf reports exactly what would be added or changed without writing anything.

.PARAMETER Only
    Optional list titles to load, e.g. -Only 16_StatusMaster,18_WorkflowConfig

.EXAMPLE
    .\Import-MasterData.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal -WhatIf
.EXAMPLE
    .\Import-MasterData.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [string] $DataPath,
    [string[]] $Only,
    [switch] $SkipConnect,
    [string] $ClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $DataPath) { $DataPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'masterdata' }
if (-not (Test-Path $DataPath)) { throw "Master data folder not found: $DataPath" }

# File -> list title, natural key columns, and the boolean columns needing TRUE/FALSE conversion.
$loadPlan = @(
    @{ File = '11_Customers.csv';             List = '11_Customers';             Key = @('CustomerCode') }
    @{ File = '12_Banks.csv';                 List = '12_Banks';                 Key = @('Title') }
    @{ File = '13_Countries.csv';             List = '13_Countries';             Key = @('Title') }
    @{ File = '14_Currencies.csv';            List = '14_Currencies';            Key = @('Title') }
    @{ File = '15_DocumentTypes.csv';         List = '15_DocumentTypes';         Key = @('DocumentTypeCode') }
    @{ File = '16_StatusMaster.csv';          List = '16_StatusMaster';          Key = @('EntityName', 'StatusCode') }
    @{ File = '18_WorkflowConfig.csv';        List = '18_WorkflowConfig';        Key = @('Title') }
    @{ File = '19_DocChecklistTemplates.csv'; List = '19_DocChecklistTemplates'; Key = @('Title') }
    @{ File = '21_Incoterms.csv';             List = '21_Incoterms';             Key = @('Title') }
    @{ File = '22_Ports.csv';                 List = '22_Ports';                 Key = @('Title') }
    @{ File = '23_LCTypes.csv';               List = '23_LCTypes';               Key = @('LCTypeCode') }
    @{ File = '24_DiscrepancyCategories.csv'; List = '24_DiscrepancyCategories'; Key = @('CategoryCode') }
    @{ File = '25_PaymentTerms.csv';          List = '25_PaymentTerms';          Key = @('PaymentTermCode') }
    @{ File = '29_DashboardMetrics.csv';      List = '29_DashboardMetrics';      Key = @('Title', 'MetricScope') }
)

$script:Stats = [ordered]@{ Added = 0; Updated = 0; Unchanged = 0; Skipped = 0; Failed = 0 }
$script:Log = [System.Collections.Generic.List[object]]::new()

function ConvertTo-FieldValue {
    param($Raw, [string] $FieldType)
    if ($null -eq $Raw) { return $null }
    $s = [string]$Raw
    switch ($FieldType) {
        'Boolean' {
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            return ($s -match '^(?i:true|yes|1|y)$')
        }
        { $_ -in 'Number', 'Currency' } {
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            $parsed = 0.0
            if ([double]::TryParse($s, [ref]$parsed)) { return $parsed }
            return $null
        }
        'DateTime' {
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            $d = [datetime]::MinValue
            if ([datetime]::TryParse($s, [ref]$d)) { return $d }
            return $null
        }
        default { return $s }
    }
}

Write-Host ''
Write-Host 'Export LC Portal - master data load' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
if ($WhatIfPreference) { Write-Host 'Mode: WhatIf (no changes will be made)' -ForegroundColor Yellow }

if (-not $SkipConnect) {
    # Falls back to Microsoft's own pre-consented "SharePoint Online Management Shell" app
    # when -ClientId isn't passed - without a client id, -DeviceLogin throws a confusing
    # cross-thread error instead of a clear "specify a client id" message.
    $DefaultClientId = '9bc3ab49-b65d-410a-85ad-de819febfddc'
    if (-not $ClientId) { $ClientId = $DefaultClientId }
    $connectArgs = @{ Url = $SiteUrl; ErrorAction = 'Stop'; ClientId = $ClientId }
    try {
        Connect-PnPOnline @connectArgs -Interactive
    }
    catch {
        Write-Warning "Interactive sign-in didn't work on this machine ($($_.Exception.Message))."
        Write-Warning 'Falling back to device login - open the URL printed below in any browser and enter the code shown.'
        Connect-PnPOnline @connectArgs -DeviceLogin
    }
}

foreach ($plan in $loadPlan) {
    if ($Only -and $Only -notcontains $plan.List) { continue }

    $csvPath = Join-Path $DataPath $plan.File
    if (-not (Test-Path $csvPath)) {
        Write-Warning "$($plan.File) not found - skipped. Run migration/extract_legacy.py to generate the derived files."
        continue
    }
    $list = Get-PnPList -Identity $plan.List -ErrorAction SilentlyContinue
    if (-not $list) {
        Write-Warning "List '$($plan.List)' does not exist. Run Provision-ExportLCPortal.ps1 first."
        continue
    }

    Write-Host ''
    Write-Host "$($plan.List)" -ForegroundColor White

    # Field types drive value conversion; anything in the CSV but not on the list is ignored
    # rather than failing the load, so a schema change never breaks the seed.
    $fields = @{}
    foreach ($f in Get-PnPField -List $plan.List) { $fields[$f.InternalName] = $f.TypeAsString }

    $rows = @(Import-Csv -Path $csvPath)
    $csvColumns = @($rows[0].PSObject.Properties.Name)
    $usable = @($csvColumns | Where-Object { $fields.ContainsKey($_) })
    $ignored = @($csvColumns | Where-Object { -not $fields.ContainsKey($_) })
    if ($ignored.Count -gt 0) {
        Write-Host "  ignoring columns not on the list: $($ignored -join ', ')" -ForegroundColor DarkGray
    }

    # The natural-key columns are read below to match existing rows, so they must be fetched
    # even if they were "ignored" above (e.g. missing from the list entirely) - otherwise
    # $item[$k] throws a lazy-load CSOM error instead of a clear, catchable message.
    $missingKeyFields = @($plan.Key | Where-Object { -not $fields.ContainsKey($_) })
    if ($missingKeyFields.Count -gt 0) {
        Write-Warning "  cannot match existing rows: key column(s) missing from the list: $($missingKeyFields -join ', ') - list skipped"
        continue
    }

    # One read of the whole list, then match in memory. Master lists are small by design.
    $existing = Get-PnPListItem -List $plan.List -PageSize 2000 -Fields (@('ID') + $usable + $plan.Key | Select-Object -Unique)
    $index = @{}
    foreach ($item in $existing) {
        $keyParts = foreach ($k in $plan.Key) { [string]$item[$k] }
        $index[($keyParts -join '||').ToUpperInvariant()] = $item
    }

    foreach ($row in $rows) {
        $keyParts = foreach ($k in $plan.Key) { [string]$row.$k }
        $key = ($keyParts -join '||').ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace(($keyParts -join ''))) {
            $script:Stats.Skipped++
            continue
        }

        $values = @{}
        foreach ($col in $usable) {
            $converted = ConvertTo-FieldValue -Raw $row.$col -FieldType $fields[$col]
            if ($null -ne $converted) { $values[$col] = $converted }
        }

        $hit = $index[$key]
        try {
            if ($hit) {
                # Only send fields whose value actually differs - keeps version history meaningful.
                $changes = @{}
                foreach ($col in $values.Keys) {
                    $current = $hit[$col]
                    $new = $values[$col]
                    $same = if ($null -eq $current) { $false }
                    elseif ($fields[$col] -in 'Number', 'Currency') { [math]::Abs([double]$current - [double]$new) -lt 0.000001 }
                    elseif ($fields[$col] -eq 'Boolean') { [bool]$current -eq [bool]$new }
                    else { [string]$current -eq [string]$new }
                    if (-not $same) { $changes[$col] = $new }
                }
                if ($changes.Count -eq 0) {
                    $script:Stats.Unchanged++
                    continue
                }
                if ($PSCmdlet.ShouldProcess("$($plan.List) [$key]", "Update $($changes.Count) field(s)")) {
                    Set-PnPListItem -List $plan.List -Identity $hit.Id -Values $changes -UpdateType SystemUpdate | Out-Null
                }
                $script:Stats.Updated++
                $script:Log.Add([pscustomobject]@{ List = $plan.List; Key = $key; Action = 'Update'; Detail = ($changes.Keys -join ',') })
            }
            else {
                if ($PSCmdlet.ShouldProcess("$($plan.List) [$key]", 'Add item')) {
                    Add-PnPListItem -List $plan.List -Values $values | Out-Null
                }
                $script:Stats.Added++
                $script:Log.Add([pscustomobject]@{ List = $plan.List; Key = $key; Action = 'Add'; Detail = '' })
            }
        }
        catch {
            $script:Stats.Failed++
            $script:Log.Add([pscustomobject]@{ List = $plan.List; Key = $key; Action = 'FAILED'; Detail = $_.Exception.Message })
            Write-Warning "  $key : $($_.Exception.Message)"
        }
    }
    Write-Host ("  {0} row(s) processed" -f $rows.Count) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
$script:Stats.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Key, $_.Value) }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "masterdata-load-$stamp.csv"
$script:Log | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host "Log: $out" -ForegroundColor Cyan
if ($script:Stats.Failed -gt 0) { exit 1 }
exit 0
