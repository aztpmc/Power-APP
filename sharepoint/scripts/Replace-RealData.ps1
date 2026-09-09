<#
.SYNOPSIS
    Replaces whatever is currently in 01_ExportLCs / 03_Invoices with the real legacy
    data extracted from the user's own Excel trackers, and links each invoice to its LC.

.DESCRIPTION
    Safety, in order:
      1. Backs up every existing item in both lists to timestamped CSV files next to this
         script, before touching anything.
      2. Deletes all existing items in both lists (SharePoint's Recycle Bin still holds
         them for the tenant's normal retention window even after this).
      3. Loads every row from -LCWorkbook into 01_ExportLCs.
      4. Loads every row from -InvoiceWorkbook into 03_Invoices, resolving LCItemId /
         InternalLCID by matching each invoice's LCNumber against the LCs just loaded.
         An invoice whose LCNumber doesn't match any loaded LC is still added (as an
         "orphan" - matches migration/out/summary.md's known 6 unregistered LCs) but
         reported separately so nothing is silently dropped.

    Needs the ImportExcel module to read the .xlsx workbooks; installs it automatically
    (-Scope CurrentUser) if missing.

    Assumes you are already connected (Connect-PnPOnline) - does not connect on its own.

.PARAMETER LCWorkbook
    Path to the LC workbook (columns matching 01_ExportLCs' schema, header row = internal
    names). Matches the "01_ExportLCs-realdata.xlsx" file from this project's manual data
    kit.

.PARAMETER InvoiceWorkbook
    Path to the invoice workbook (same idea, for 03_Invoices).

.EXAMPLE
    Connect-PnPOnline -Url https://contoso.sharepoint.com/sites/ExportLCPortal -Interactive
    .\Repair-RealDataSchema.ps1
    .\Replace-RealData.ps1 -LCWorkbook .\01_ExportLCs-realdata.xlsx -InvoiceWorkbook .\03_Invoices-realdata.xlsx
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $LCWorkbook,
    [Parameter(Mandatory = $true)][string] $InvoiceWorkbook,
    [string] $SchemaPath,
    [string] $LCList = '01_ExportLCs',
    [string] $InvoiceList = '03_Invoices'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-PnPConnection -ErrorAction SilentlyContinue)) {
    throw "Not connected to SharePoint. Run Connect-PnPOnline first, then re-run this script in the same session."
}
if (-not (Test-Path $LCWorkbook)) { throw "LC workbook not found: $LCWorkbook" }
if (-not (Test-Path $InvoiceWorkbook)) { throw "Invoice workbook not found: $InvoiceWorkbook" }

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host 'Installing the ImportExcel module (one-time, reads .xlsx without needing Excel installed)...' -ForegroundColor Cyan
    Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber
}
Import-Module ImportExcel -ErrorAction Stop

if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schema/site-schema.json' }
if (-not (Test-Path $SchemaPath)) { throw "Schema not found: $SchemaPath" }
$schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json

function Get-FieldTypeMap {
    param([string] $ListTitle)
    $map = @{}
    foreach ($f in Get-PnPField -List $ListTitle) { $map[$f.InternalName] = $f.TypeAsString }
    $map
}

function ConvertTo-FieldValue {
    param($Raw, [string] $FieldType)
    if ($null -eq $Raw) { return $null }
    $s = [string]$Raw
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    switch ($FieldType) {
        'Boolean' { return ($s -match '^(?i:true|yes|1|y)$') }
        { $_ -in 'Number', 'Currency' } {
            $parsed = 0.0
            if ([double]::TryParse($s, [ref]$parsed)) { return $parsed }
            return $null
        }
        'DateTime' {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse($s, [ref]$d)) { return $d }
            return $null
        }
        default { return $s }
    }
}

function Backup-List {
    param([string] $ListTitle)
    $items = Get-PnPListItem -List $ListTitle -PageSize 2000
    if ($items.Count -eq 0) { Write-Host "  $ListTitle - nothing to back up (already empty)" -ForegroundColor DarkGray; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $PSScriptRoot "backup-$ListTitle-$stamp.csv"
    $rows = foreach ($i in $items) {
        $row = [ordered]@{ Id = $i.Id }
        foreach ($k in $i.FieldValues.Keys) { $row[$k] = $i.FieldValues[$k] }
        [pscustomobject]$row
    }
    $rows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
    Write-Host "  $ListTitle - backed up $($items.Count) item(s) to $out" -ForegroundColor Green
}

function Clear-List {
    param([string] $ListTitle)
    $items = @(Get-PnPListItem -List $ListTitle -PageSize 2000 -Fields 'ID')
    if ($items.Count -eq 0) { return }
    if ($PSCmdlet.ShouldProcess("$ListTitle ($($items.Count) item(s))", 'Delete all items')) {
        foreach ($i in $items) { Remove-PnPListItem -List $ListTitle -Identity $i.Id -Force }
        Write-Host "  $ListTitle - deleted $($items.Count) item(s)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Replace real data (01_ExportLCs / 03_Invoices)' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan

Write-Host ''
Write-Host '1. Backup' -ForegroundColor White
Backup-List -ListTitle $LCList
Backup-List -ListTitle $InvoiceList

Write-Host ''
Write-Host '2. Clear existing items' -ForegroundColor White
Clear-List -ListTitle $LCList
Clear-List -ListTitle $InvoiceList

Write-Host ''
Write-Host '3. Load LCs' -ForegroundColor White
$lcFieldTypes = Get-FieldTypeMap -ListTitle $LCList
$lcRows = Import-Excel -Path $LCWorkbook
$lcNumberToItemId = @{}
$lcAdded = 0
foreach ($row in $lcRows) {
    $props = $row.PSObject.Properties | Where-Object { $_.Name -and $lcFieldTypes.ContainsKey($_.Name) }
    $values = @{}
    foreach ($p in $props) {
        $converted = ConvertTo-FieldValue -Raw $p.Value -FieldType $lcFieldTypes[$p.Name]
        if ($null -ne $converted) { $values[$p.Name] = $converted }
    }
    if (-not $values.ContainsKey('LCNumber') -or [string]::IsNullOrWhiteSpace([string]$values['LCNumber'])) { continue }
    if ($PSCmdlet.ShouldProcess("$LCList [$($values['LCNumber'])]", 'Add item')) {
        $new = Add-PnPListItem -List $LCList -Values $values
        $lcNumberToItemId[[string]$values['LCNumber']] = $new.Id
        $lcAdded++
    }
}
Write-Host "  $lcAdded LC(s) loaded" -ForegroundColor Green

Write-Host ''
Write-Host '4. Load invoices, linking to LCs by LCNumber' -ForegroundColor White
$invFieldTypes = Get-FieldTypeMap -ListTitle $InvoiceList
$invRows = Import-Excel -Path $InvoiceWorkbook
$invAdded = 0
$orphans = [System.Collections.Generic.List[string]]::new()
foreach ($row in $invRows) {
    $props = $row.PSObject.Properties | Where-Object { $_.Name -and $invFieldTypes.ContainsKey($_.Name) }
    $values = @{}
    foreach ($p in $props) {
        $converted = ConvertTo-FieldValue -Raw $p.Value -FieldType $invFieldTypes[$p.Name]
        if ($null -ne $converted) { $values[$p.Name] = $converted }
    }
    $lcNumber = if ($values.ContainsKey('LCNumber')) { [string]$values['LCNumber'] } else { '' }
    if ($lcNumberToItemId.ContainsKey($lcNumber)) {
        $lcItemId = $lcNumberToItemId[$lcNumber]
        $values['LCItemId'] = $lcItemId
        $values['InternalLCID'] = [string]$lcItemId
    }
    elseif ($lcNumber) {
        $orphans.Add($lcNumber) | Out-Null
    }
    if ($PSCmdlet.ShouldProcess("$InvoiceList [$($row.Title)]", 'Add item')) {
        Add-PnPListItem -List $InvoiceList -Values $values | Out-Null
        $invAdded++
    }
}
Write-Host "  $invAdded invoice(s) loaded" -ForegroundColor Green

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "  LCs loaded       : $lcAdded"
Write-Host "  Invoices loaded  : $invAdded"
Write-Host "  Orphan invoices  : $($orphans.Count) (LCNumber not found among the LCs just loaded)"
if ($orphans.Count -gt 0) {
    Write-Host "    $($orphans -join ', ')" -ForegroundColor Yellow
    Write-Host '  These invoices were still added, just without an LCItemId link. Register the' -ForegroundColor Yellow
    Write-Host '  matching LC and re-link manually, or re-run after adding it to the workbook.' -ForegroundColor Yellow
}
