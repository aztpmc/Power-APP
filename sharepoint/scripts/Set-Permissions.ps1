<#
.SYNOPSIS
    Applies the Export LC Portal security model: SharePoint groups, a custom permission level,
    and per-list permissions.

.DESCRIPTION
    Creates five SharePoint groups mapped to the five application roles, plus a custom
    "Contribute No Delete" permission level used for operational lists, and an
    "Append Only" level used for 10_AuditLog so that the audit trail cannot be edited or
    deleted by the people it records.

    Safety:
      * Existing groups are reused, never recreated, and existing members are never removed.
      * Inheritance is only broken on lists this solution owns.
      * -WhatIf prints the whole plan without changing anything.

    SharePoint groups control what a user can physically reach through any client - the app,
    the browser, Excel, the REST API. 17_Users controls what the portal offers them. Both are
    needed: the app-side role alone is a UI convenience, not a security boundary.

.EXAMPLE
    .\Set-Permissions.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string] $SiteUrl,
    [string] $SchemaPath,
    [switch] $SkipConnect,
    [string] $ClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schema/site-schema.json' }
$schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json

$GROUPS = @(
    @{ Name = 'Export LC Administrators'; Role = 'ADMIN';    Base = 'Full Control'; Description = 'Full control of the portal, its lists, master data and configuration.' }
    @{ Name = 'Export LC Managers';       Role = 'MANAGER';  Base = 'Edit';         Description = 'Full operational access plus approvals, closures, write-offs and all reports.' }
    @{ Name = 'Export LC Officers';       Role = 'OFFICER';  Base = 'LC Contribute No Delete'; Description = 'Create and maintain operational records. Cannot delete records or edit master data.' }
    @{ Name = 'Export LC Reviewers';      Role = 'REVIEWER'; Base = 'LC Contribute No Delete'; Description = 'Review records and documents, record examination outcomes and discrepancies.' }
    @{ Name = 'Export LC Readers';        Role = 'READONLY'; Base = 'Read';         Description = 'Read-only access to the portal and its reports.' }
)

# Lists holding master data and configuration: only administrators may change them.
$ADMIN_ONLY_LISTS = @(
    '11_Customers', '12_Banks', '13_Countries', '14_Currencies', '15_DocumentTypes',
    '16_StatusMaster', '17_Users', '18_WorkflowConfig', '19_DocChecklistTemplates',
    '21_Incoterms', '22_Ports', '23_LCTypes', '24_DiscrepancyCategories', '25_PaymentTerms',
    '27_ImportBatches', '28_ImportStaging'
)
# Written by everyone, editable by nobody.
$APPEND_ONLY_LISTS = @('10_AuditLog', '26_NotificationLog')

function Ensure-Group {
    param([hashtable] $Spec)
    $existing = Get-PnPGroup -Identity $Spec.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  group '$($Spec.Name)' exists - reused" -ForegroundColor DarkGray
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Spec.Name, 'Create SharePoint group')) {
        $g = New-PnPGroup -Title $Spec.Name -Description $Spec.Description
        Write-Host "  group '$($Spec.Name)' created" -ForegroundColor Green
        return $g
    }
    return $null
}

Write-Host ''
Write-Host 'Export LC Portal - security model' -ForegroundColor Cyan
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

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '1. Custom permission levels' -ForegroundColor Yellow

# Contribute minus delete: an officer can correct a record but cannot make one disappear.
if (-not (Get-PnPRoleDefinition -Identity 'LC Contribute No Delete' -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess('LC Contribute No Delete', 'Create permission level')) {
        Add-PnPRoleDefinition -RoleName 'LC Contribute No Delete' -Clone 'Contribute' `
            -Exclude DeleteListItems, DeleteVersions `
            -Description 'Contribute without the ability to delete items or versions.' | Out-Null
        Write-Host '  created: LC Contribute No Delete' -ForegroundColor Green
    }
}
else { Write-Host '  exists: LC Contribute No Delete' -ForegroundColor DarkGray }

# Add-only: the audit trail accepts new rows and refuses edits and deletes, from everyone.
if (-not (Get-PnPRoleDefinition -Identity 'LC Append Only' -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess('LC Append Only', 'Create permission level')) {
        Add-PnPRoleDefinition -RoleName 'LC Append Only' -Clone 'Contribute' `
            -Exclude DeleteListItems, DeleteVersions, EditListItems `
            -Description 'Add items only. Cannot edit or delete existing items or versions.' | Out-Null
        Write-Host '  created: LC Append Only' -ForegroundColor Green
    }
}
else { Write-Host '  exists: LC Append Only' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. Groups' -ForegroundColor Yellow
foreach ($g in $GROUPS) { Ensure-Group -Spec $g | Out-Null }

Write-Host ''
Write-Host '3. Site-level permissions' -ForegroundColor Yellow
foreach ($g in $GROUPS) {
    if ($PSCmdlet.ShouldProcess("$($g.Name) -> $($g.Base)", 'Grant site permission')) {
        try {
            Set-PnPGroupPermissions -Identity $g.Name -AddRole $g.Base -ErrorAction Stop
            Write-Host "  $($g.Name): $($g.Base)" -ForegroundColor Green
        }
        catch { Write-Warning "  $($g.Name): $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. Master data and configuration lists (admin write, everyone read)' -ForegroundColor Yellow
foreach ($listTitle in $ADMIN_ONLY_LISTS) {
    if (-not (Get-PnPList -Identity $listTitle -ErrorAction SilentlyContinue)) {
        Write-Warning "  $listTitle not found - skipped"
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($listTitle, 'Break inheritance and apply admin-write permissions')) { continue }
    Set-PnPList -Identity $listTitle -BreakRoleInheritance -CopyRoleAssignments -ErrorAction Stop
    foreach ($g in $GROUPS) {
        $role = if ($g.Role -eq 'ADMIN') { 'Full Control' } else { 'Read' }
        try {
            Set-PnPListPermission -Identity $listTitle -Group $g.Name -RemoveRole $g.Base -ErrorAction SilentlyContinue
            Set-PnPListPermission -Identity $listTitle -Group $g.Name -AddRole $role -ErrorAction Stop
        }
        catch { Write-Warning "  $listTitle / $($g.Name): $($_.Exception.Message)" }
    }
    Write-Host "  $listTitle secured" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. Audit and notification logs (append only)' -ForegroundColor Yellow
foreach ($listTitle in $APPEND_ONLY_LISTS) {
    if (-not (Get-PnPList -Identity $listTitle -ErrorAction SilentlyContinue)) {
        Write-Warning "  $listTitle not found - skipped"
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($listTitle, 'Break inheritance and apply append-only permissions')) { continue }
    Set-PnPList -Identity $listTitle -BreakRoleInheritance -CopyRoleAssignments -ErrorAction Stop
    foreach ($g in $GROUPS) {
        # Administrators keep Full Control so history can still be archived; everyone else can only add.
        $role = if ($g.Role -eq 'ADMIN') { 'Full Control' } elseif ($g.Role -eq 'READONLY') { 'Read' } else { 'LC Append Only' }
        try {
            Set-PnPListPermission -Identity $listTitle -Group $g.Name -RemoveRole $g.Base -ErrorAction SilentlyContinue
            Set-PnPListPermission -Identity $listTitle -Group $g.Name -AddRole $role -ErrorAction Stop
        }
        catch { Write-Warning "  $listTitle / $($g.Name): $($_.Exception.Message)" }
    }
    Write-Host "  $listTitle secured (append only)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. Verification' -ForegroundColor Yellow
$report = foreach ($l in ($schema.lists + $schema.libraries)) {
    $list = Get-PnPList -Identity $l.title -ErrorAction SilentlyContinue
    if (-not $list) { continue }
    $list.Context.Load($list.HasUniqueRoleAssignments)
    $list.Context.ExecuteQuery()
    [pscustomobject]@{
        List             = $l.title
        UniquePermissions = $list.HasUniqueRoleAssignments
        Expected         = ($ADMIN_ONLY_LISTS + $APPEND_ONLY_LISTS) -contains $l.title
    }
}
$mismatch = @($report | Where-Object { $_.UniquePermissions -ne $_.Expected })
$report | Format-Table -AutoSize
if ($mismatch.Count -gt 0) {
    Write-Warning "$($mismatch.Count) list(s) do not have the expected inheritance state - review above."
}

Write-Host ''
Write-Host 'Next steps (manual - these cannot be scripted safely without knowing your users):' -ForegroundColor Cyan
Write-Host '  1. Add users to the five groups.'
Write-Host '  2. Add a matching row per user in 17_Users with their RoleCode and ManagerEmail.'
Write-Host '  3. Set EscalationManagerEmail and PortalSupportEmail in 18_WorkflowConfig.'
Write-Host '  4. Share the Power App with the same five groups.'
