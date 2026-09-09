<#
.SYNOPSIS
    Ensures 01_ExportLCs and 03_Invoices have every column from the schema, with the
    correct internal name - fixing the "ghost field" problem this project hit repeatedly
    before loading the real legacy LC/invoice data.

.DESCRIPTION
    Background: earlier manual "Create list from Excel" attempts on this site left some
    lists with generic columns named field_1, field_2, ... whose DISPLAY name (Title)
    happens to equal a wanted column's internal name (e.g. a ghost column titled
    "CustomerCode" but internally still called "field_3"). SharePoint's field lookup
    (GetByInternalNameOrTitle, which Get-PnPField -Identity uses) matches on EITHER the
    internal name OR the title, so a ghost field silently satisfies the "does this column
    already exist" check and the real, correctly-named column never gets created.

    This script, run against 01_ExportLCs and 03_Invoices specifically:
      1. Finds any ghost field (internal name matching field_<n>, display title matching
         a wanted schema column name) and renames its Title out of the way.
      2. Creates every schema column that's still missing, using the same field-XML
         generation as Provision-ExportLCPortal.ps1.

    Idempotent and non-destructive: existing correctly-named columns are left untouched,
    nothing is deleted, no list data is touched (this script only ever adds/renames
    COLUMNS, never rows - see Replace-RealData.ps1 for loading the actual data).

    Assumes you are already connected (Connect-PnPOnline) - this script does not connect
    on its own, so it can be chained after an existing session in the same PowerShell
    window.

.EXAMPLE
    Connect-PnPOnline -Url https://contoso.sharepoint.com/sites/ExportLCPortal -Interactive
    .\Repair-RealDataSchema.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SchemaPath,
    [string[]] $Lists = @('01_ExportLCs', '03_Invoices')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-PnPConnection -ErrorAction SilentlyContinue)) {
    throw "Not connected to SharePoint. Run Connect-PnPOnline first, then re-run this script in the same session."
}

if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schema/site-schema.json' }
if (-not (Test-Path $SchemaPath)) { throw "Schema not found: $SchemaPath" }
$schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json

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

Write-Host ''
Write-Host 'Repair real-data schema (01_ExportLCs / 03_Invoices)' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan

$totalCreated = 0
$totalRenamed = 0

foreach ($listTitle in $Lists) {
    Write-Host ''
    Write-Host $listTitle -ForegroundColor White

    $listDef = $schema.lists | Where-Object { $_.title -eq $listTitle }
    if (-not $listDef) { Write-Warning "  no schema definition for $listTitle - skipped"; continue }

    $list = Get-PnPList -Identity $listTitle -ErrorAction SilentlyContinue
    if (-not $list) { Write-Warning "  list not found on the site - run Provision-ExportLCPortal.ps1 first"; continue }

    $wantedNames = @($listDef.fields | ForEach-Object { $_.name })
    $liveFields = Get-PnPField -List $listTitle

    # Step 1: rename any ghost field out of the way.
    foreach ($f in $liveFields) {
        $looksGhost = $f.InternalName -match '^field_\d+$'
        $titleCollides = $f.Title -in $wantedNames
        if ($looksGhost -and $titleCollides) {
            $newTitle = "$($f.InternalName)_legacy"
            Write-Host "  ghost field: $($f.InternalName) titled '$($f.Title)' -> renaming to '$newTitle'" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess("$listTitle.$($f.InternalName)", 'Rename ghost field title')) {
                Set-PnPField -List $listTitle -Identity $f.InternalName -Values @{ Title = $newTitle } | Out-Null
                $totalRenamed++
            }
        }
    }

    # Re-fetch after any renames so the "already exists" check below is accurate.
    $existingNames = @((Get-PnPField -List $listTitle) | ForEach-Object { $_.InternalName })

    # Step 2: create every schema column that's still missing.
    foreach ($field in $listDef.fields) {
        if ($existingNames -contains $field.name) {
            Write-Host "  $($field.name) - exists" -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess("$listTitle.$($field.name)", 'Create column')) {
            $xml = Get-FieldXml -Field $field
            Add-PnPFieldFromXml -List $listTitle -FieldXml $xml | Out-Null
            Write-Host "  $($field.name) - created (Type=$($field.type))" -ForegroundColor Green
            $totalCreated++
        }
    }
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "  Ghost fields renamed : $totalRenamed"
Write-Host "  Columns created      : $totalCreated"
Write-Host ''
Write-Host 'Next: .\Replace-RealData.ps1 -LCWorkbook <path> -InvoiceWorkbook <path>' -ForegroundColor Green
