<#
.SYNOPSIS
    Packages each flow definition into a legacy import zip for Power Automate.

.DESCRIPTION
    Power Automate's "Import Package (Legacy)" accepts a zip containing manifest.json and
    Microsoft.Flow/flows/<name>/definition.json. This script builds one zip per flow from
    the sources in powerautomate/flows.

    It also stamps the SiteUrl parameter default with the site you pass, so the imported
    flow points at the right site collection instead of the CONTOSO placeholder. Nothing
    else in the definition is modified.

.PARAMETER SiteUrl
    Portal site collection URL to stamp into each definition's SiteUrl parameter.

.PARAMETER OutputPath
    Where to write the zips. Defaults to powerautomate/packages.

.EXAMPLE
    .\Build-FlowPackages.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [string] $OutputPath,
    [string[]] $Only
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$flowRoot = Join-Path $PSScriptRoot 'flows'
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'packages' }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$built = @()
foreach ($dir in Get-ChildItem -Path $flowRoot -Directory | Sort-Object Name) {
    if ($Only -and $Only -notcontains $dir.Name) { continue }

    $defPath = Join-Path $dir.FullName 'definition.json'
    $manPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path $defPath) -or -not (Test-Path $manPath)) {
        Write-Warning "$($dir.Name): missing definition.json or manifest.json - skipped"
        continue
    }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("flowpkg-" + [guid]::NewGuid().ToString('N'))
    $flowDir = Join-Path $staging "Microsoft.Flow/flows/$($dir.Name)"
    New-Item -ItemType Directory -Force -Path $flowDir | Out-Null

    # Stamp the site URL into the definition's parameter default.
    $definition = Get-Content $defPath -Raw | ConvertFrom-Json
    if ($definition.parameters.PSObject.Properties.Name -contains 'SiteUrl') {
        $definition.parameters.SiteUrl.defaultValue = $SiteUrl
    }
    $definition | ConvertTo-Json -Depth 100 | Set-Content -Path (Join-Path $flowDir 'definition.json') -Encoding UTF8
    Copy-Item $manPath -Destination (Join-Path $staging 'manifest.json')

    $zip = Join-Path $OutputPath "$($dir.Name).zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item $staging -Recurse -Force

    $built += $dir.Name
    Write-Host "packaged $($dir.Name)" -ForegroundColor Green
}

Write-Host ''
Write-Host "$($built.Count) package(s) written to $OutputPath" -ForegroundColor Cyan
Write-Host ''
Write-Host 'To import each one:' -ForegroundColor Cyan
Write-Host '  1. make.powerautomate.com -> My flows -> Import -> Import Package (Legacy)'
Write-Host '  2. Upload the zip.'
Write-Host '  3. Set each connection to an existing SharePoint / Outlook / Approvals connection.'
Write-Host '  4. Import, then open the flow and turn it on.'
Write-Host ''
Write-Host 'Import order matters only for the two import flows: 12 before 13.' -ForegroundColor DarkGray
