<#
.SYNOPSIS
    PHASE 1 - Read-only inspection of the target SharePoint environment.

.DESCRIPTION
    Makes no changes of any kind. Reports what already exists so you can decide whether to
    provision into a new site or reuse an existing one, and so nothing gets overwritten:

      * Site, web template, storage and sharing settings
      * Every list and library with item count, created date and last item modified date
      * Anything that looks like an existing Export LC tracker
      * Which of the 33 objects this solution wants already exist, and whether an existing
        object of the same name has a conflicting schema
      * SharePoint groups and their membership
      * Any list already carrying more than 5,000 items (list view threshold exposure)

    Run this before Provision-ExportLCPortal.ps1 and keep the CSV it produces.

.EXAMPLE
    .\Inspect-Environment.ps1 -SiteUrl https://contoso.sharepoint.com/sites/Treasury
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [string] $SchemaPath,
    [switch] $SkipConnect,
    [string] $ClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schema/site-schema.json' }

Write-Host ''
Write-Host 'Export LC Portal - environment inspection (READ ONLY)' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan

if (-not $SkipConnect) {
    $connectArgs = @{ Url = $SiteUrl; ErrorAction = 'Stop' }
    if ($ClientId) { $connectArgs['ClientId'] = $ClientId }
    try {
        Connect-PnPOnline @connectArgs -Interactive
    }
    catch {
        # "Specified method is not supported" and similar show up when the local machine
        # can't use the WAM browser broker (missing/disabled Web Account Manager component).
        # Device login has no such dependency - it works from any machine with a browser.
        # "Please specify a valid client id" means this tenant has no PnP Entra ID app
        # registered yet - run Register-PnPEntraIDAppForInteractiveLogin once (see
        # docs/11-quickstart-at-home.md) and pass its ClientId here with -ClientId.
        Write-Warning "Interactive sign-in didn't work on this machine ($($_.Exception.Message))."
        Write-Warning 'Falling back to device login - open the URL printed below in any browser and enter the code shown.'
        Connect-PnPOnline @connectArgs -DeviceLogin
    }
}

$web = Get-PnPWeb -Includes Created, WebTemplate, Language, Description
Write-Host ''
Write-Host 'SITE' -ForegroundColor Yellow
Write-Host "  Title      : $($web.Title)"
Write-Host "  Url        : $($web.Url)"
Write-Host "  Template   : $($web.WebTemplate)"
Write-Host "  Created    : $($web.Created)"

try {
    $site = Get-PnPSite -Includes Usage
    Write-Host "  Storage    : $([math]::Round($site.Usage.Storage / 1MB, 1)) MB used"
}
catch { Write-Host '  Storage    : (not readable with current permissions)' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'LISTS AND LIBRARIES' -ForegroundColor Yellow
$all = Get-PnPList -Includes ItemCount, Created, LastItemModifiedDate, Hidden, BaseTemplate, DefaultViewUrl
$visible = $all | Where-Object { -not $_.Hidden } | Sort-Object Title

$inventory = foreach ($l in $visible) {
    [pscustomobject]@{
        Title            = $l.Title
        Type             = if ($l.BaseTemplate -eq 101) { 'Library' } else { 'List' }
        Items            = $l.ItemCount
        Created          = $l.Created
        LastItemModified = $l.LastItemModifiedDate
        Url              = $l.DefaultViewUrl
    }
}
$inventory | Format-Table -AutoSize

Write-Host "  $($visible.Count) visible list(s)/library(ies); $(($all | Where-Object Hidden).Count) hidden." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'POSSIBLE EXISTING EXPORT LC DATA' -ForegroundColor Yellow
$patterns = 'LC', 'Letter of Credit', 'Export', 'Trade', 'Treasury', 'Invoice', 'Shipment', 'Presentation', 'Discrepanc', 'Proceed', 'Amendment'
$suspects = $visible | Where-Object { $t = $_.Title; $patterns | Where-Object { $t -like "*$_*" } }
if ($suspects) {
    $suspects | Select-Object Title, ItemCount, LastItemModifiedDate | Format-Table -AutoSize
    Write-Host '  Review these before provisioning. If any is a live tracker, decide whether to reuse it' -ForegroundColor Yellow
    Write-Host '  or provision this solution into a separate site. Nothing here is modified by this script.' -ForegroundColor Yellow
}
else { Write-Host '  None found.' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'LISTS OVER THE 5,000 ITEM VIEW THRESHOLD' -ForegroundColor Yellow
$big = $visible | Where-Object { $_.Items -gt 5000 }
if ($big) { $big | Select-Object Title, Items | Format-Table -AutoSize }
else { Write-Host '  None.' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'SOLUTION OBJECTS ALREADY PRESENT' -ForegroundColor Yellow
$conflicts = @()
if (Test-Path $SchemaPath) {
    $schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json
    $wanted = @()
    foreach ($x in $schema.libraries) { $wanted += , @{ Title = $x.title; Kind = 'Library'; Def = $x } }
    foreach ($x in $schema.lists) { $wanted += , @{ Title = $x.title; Kind = 'List'; Def = $x } }

    $present = @()
    foreach ($w in $wanted) {
        $hit = $all | Where-Object { $_.Title -eq $w.Title }
        if (-not $hit) { continue }
        $present += $w.Title

        # Compare columns so a name collision with a different schema is caught before provisioning.
        $existingFields = (Get-PnPField -List $w.Title | Select-Object -ExpandProperty InternalName)
        $missing = @($w.Def.fields | Where-Object { $existingFields -notcontains $_.name } | Select-Object -ExpandProperty name)
        $conflicts += [pscustomobject]@{
            Object         = $w.Title
            ExistingItems  = $hit.ItemCount
            ColumnsWanted  = $w.Def.fields.Count
            ColumnsMissing = $missing.Count
            MissingSample  = ($missing | Select-Object -First 6) -join ', '
        }
    }
    if ($present.Count -eq 0) {
        Write-Host "  None of the $($wanted.Count) solution objects exist yet - this is a clean target." -ForegroundColor Green
    }
    else {
        Write-Host "  $($present.Count) of $($wanted.Count) solution objects already exist:" -ForegroundColor Yellow
        $conflicts | Format-Table -AutoSize
        Write-Host '  Provisioning will REUSE these and add only the missing columns. It will not change' -ForegroundColor Yellow
        Write-Host '  or delete any column that already exists.' -ForegroundColor Yellow
    }
}
else { Write-Host "  Schema not found at $SchemaPath - skipped." -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'SECURITY GROUPS' -ForegroundColor Yellow
try {
    Get-PnPGroup | ForEach-Object {
        $members = @(Get-PnPGroupMember -Group $_.Title -ErrorAction SilentlyContinue)
        [pscustomobject]@{ Group = $_.Title; Members = $members.Count; Owner = $_.OwnerTitle }
    } | Format-Table -AutoSize
}
catch { Write-Host "  Could not enumerate groups: $($_.Exception.Message)" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "environment-inventory-$stamp.csv"
$inventory | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host "Inventory written to: $out" -ForegroundColor Cyan
if ($conflicts.Count -gt 0) {
    $out2 = Join-Path $PSScriptRoot "existing-object-conflicts-$stamp.csv"
    $conflicts | Export-Csv -Path $out2 -NoTypeInformation -Encoding UTF8
    Write-Host "Conflicts written to: $out2" -ForegroundColor Cyan
}
Write-Host ''
Write-Host 'Nothing was modified.' -ForegroundColor Green
