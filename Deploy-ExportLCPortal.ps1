<#
.SYNOPSIS
    Orchestrates the SharePoint-side deployment of the Export LC Portal end to end:
    inspect, provision, load master data, set permissions, package flows.

.DESCRIPTION
    This is the "run one script" version of docs/07-deployment-runbook.md phases 1-5 and 7.
    It does NOT touch Power Apps Studio - that part is manual (see docs/11-quickstart-at-home.md)
    because there is no supported way to script screen creation in Studio itself.

    Every step it calls is independently idempotent and non-destructive - see the individual
    scripts in sharepoint/scripts/ for what each one actually does. This wrapper adds:
      - a single confirmation prompt per phase (skip with -Unattended)
      - a hard stop if a phase fails, so you are never left half-provisioned without knowing it
      - a running summary at the end

.PARAMETER SiteUrl
    The target SharePoint site collection, e.g. https://contoso.sharepoint.com/sites/ExportLCPortal

.PARAMETER SkipInspect
    Skip Phase 1 (read-only survey). Only skip this if you already ran it separately and
    reviewed the output - it is what tells you whether you are provisioning into a clean site.

.PARAMETER SkipFlows
    Skip building the Power Automate flow packages (Phase 7). You will still need to import
    them manually later via Build-FlowPackages.ps1.

.PARAMETER Unattended
    Do not prompt for confirmation between phases. Use for a re-run you already trust.

.PARAMETER ClientId
    Entra ID App Registration client id for PnP to sign in with. Needed on PnP.PowerShell
    2.x/3.x if your tenant has never used PnP before - sign-in fails with "Please specify
    a valid client id for an Entra ID App Registration" until one exists. Create one once,
    as an admin:

        Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "Export LC Portal" -Tenant yourtenant.onmicrosoft.com

    then pass the ClientId it prints here. Not needed if your tenant already has a PnP
    app registered and it's set as the tenant default.

.EXAMPLE
    .\Deploy-ExportLCPortal.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal

.EXAMPLE
    .\Deploy-ExportLCPortal.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal -Unattended
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [switch] $SkipInspect,
    [switch] $SkipFlows,
    [switch] $Unattended,
    [string] $ClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$Scripts = Join-Path $Root 'sharepoint/scripts'

function Write-Phase {
    param([string]$Number, [string]$Title)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host "PHASE $Number - $Title" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Confirm-Phase {
    param([string]$Prompt)
    if ($Unattended) { return $true }
    $resp = Read-Host "$Prompt [Y/n]"
    return ($resp -eq '' -or $resp -match '^[Yy]')
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Export LC Portal - guided deployment' -ForegroundColor Green
Write-Host "Site: $SiteUrl"
Write-Host "Repo: $Root"
Write-Host ''

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Warning 'PnP.PowerShell is not installed.'
    if (Confirm-Phase 'Install it now (Install-Module PnP.PowerShell -Scope CurrentUser)?') {
        Install-Module PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
    }
    else {
        throw 'PnP.PowerShell is required. Install it and re-run.'
    }
}
Import-Module PnP.PowerShell -ErrorAction Stop

Write-Host 'Signing in once - every phase below reuses this connection.' -ForegroundColor Cyan
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
Write-Host "Connected: $((Get-PnPWeb).Title)" -ForegroundColor Green

$summary = [ordered]@{}

# ---------------------------------------------------------------------------
# Phase 1 - Inspect (read only)
# ---------------------------------------------------------------------------
if (-not $SkipInspect) {
    Write-Phase '1' 'Inspect the target environment (read only)'
    if (Confirm-Phase 'Run the read-only environment survey now?') {
        & (Join-Path $Scripts 'Inspect-Environment.ps1') -SiteUrl $SiteUrl -SkipConnect
        Write-Host ''
        Write-Host 'Review the inventory above. If it lists an existing LC tracker or lists' -ForegroundColor Yellow
        Write-Host 'with the same names as this solution, decide now whether to continue into' -ForegroundColor Yellow
        Write-Host 'this site or point SiteUrl at a fresh one instead.' -ForegroundColor Yellow
        if (-not (Confirm-Phase 'Continue with provisioning into this site?')) {
            Write-Host 'Stopped after inspection, as requested.' -ForegroundColor Yellow
            return
        }
        $summary['Inspect'] = 'Done'
    }
    else { $summary['Inspect'] = 'Skipped by user' }
}
else { $summary['Inspect'] = 'Skipped (-SkipInspect)' }

# ---------------------------------------------------------------------------
# Phase 2 - Provision schema
# ---------------------------------------------------------------------------
Write-Phase '2' 'Provision SharePoint lists, libraries and columns'
Write-Host 'Dry run first (-WhatIf), so you see the full plan before anything is created.'
& (Join-Path $Scripts 'Provision-ExportLCPortal.ps1') -SiteUrl $SiteUrl -WhatIf -SkipConnect
if (-not (Confirm-Phase 'Plan looks right - provision for real now?')) {
    Write-Host 'Stopped before provisioning. Nothing was created.' -ForegroundColor Yellow
    return
}
& (Join-Path $Scripts 'Provision-ExportLCPortal.ps1') -SiteUrl $SiteUrl -SkipConnect
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Provisioning reported failures - see the report CSV before continuing.' }
$summary['Provision'] = 'Done'

# ---------------------------------------------------------------------------
# Phase 3 - Master data
# ---------------------------------------------------------------------------
Write-Phase '3' 'Load master data (customers, banks, statuses, config, ...)'
if (Confirm-Phase 'Load the 14 master data CSVs now?') {
    & (Join-Path $Scripts 'Import-MasterData.ps1') -SiteUrl $SiteUrl -SkipConnect
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Master data load reported failures.' }
    $summary['MasterData'] = 'Done'
}
else { $summary['MasterData'] = 'Skipped by user' }

# ---------------------------------------------------------------------------
# Phase 4 - Permissions
# ---------------------------------------------------------------------------
Write-Phase '4' 'Create security groups and lock down master data / audit lists'
if (Confirm-Phase 'Apply the security model now?') {
    & (Join-Path $Scripts 'Set-Permissions.ps1') -SiteUrl $SiteUrl -SkipConnect
    $summary['Permissions'] = 'Done'
    Write-Host ''
    Write-Host 'Manual follow-up still needed:' -ForegroundColor Yellow
    Write-Host '  1. Add real users to the five SharePoint groups.'
    Write-Host '  2. Add one row per user in 17_Users with RoleCode and ManagerEmail.'
    Write-Host '  3. Set EscalationManagerEmail and PortalSupportEmail in 18_WorkflowConfig.'
}
else { $summary['Permissions'] = 'Skipped by user' }

Disconnect-PnPOnline -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Phase 5 - Flow packages
# ---------------------------------------------------------------------------
if (-not $SkipFlows) {
    Write-Phase '5' 'Build Power Automate flow packages'
    if (Confirm-Phase 'Build the 14 flow zips now?') {
        & (Join-Path $Root 'powerautomate/Build-FlowPackages.ps1') -SiteUrl $SiteUrl
        $summary['Flows'] = 'Packaged - import manually, see output above'
    }
    else { $summary['Flows'] = 'Skipped by user' }
}
else { $summary['Flows'] = 'Skipped (-SkipFlows)' }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host 'SUMMARY' -ForegroundColor Green
Write-Host ('=' * 70) -ForegroundColor Green
foreach ($k in $summary.Keys) { Write-Host ("  {0,-14} {1}" -f $k, $summary[$k]) }
Write-Host ''
Write-Host 'What is NOT scripted, and still needs you:' -ForegroundColor Yellow
Write-Host '  - Building the canvas app in Power Apps Studio (docs/11-quickstart-at-home.md)'
Write-Host '  - Importing the flow zips (make.powerautomate.com -> Import -> Import Package (Legacy))'
Write-Host '  - Uploading the Excel import template to ExportLCTemplates'
Write-Host '  - Sharing the app with the five SharePoint groups'
Write-Host '  - Running the manual test plan in docs/08-testing.md'
Write-Host ''
Write-Host 'Next: python3 migration/extract_legacy.py, then walk through the Import screen' -ForegroundColor Cyan
Write-Host 'once the app is built, to bring in the real LC data.' -ForegroundColor Cyan
