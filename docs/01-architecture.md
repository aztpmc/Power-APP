# Architecture

## What this is

A Power Apps canvas portal over SharePoint Online lists and libraries, with Power Automate
for scheduling, notification, approval, import and document filing. No Dataverse, no
premium data connector, no custom code component — everything here runs on a standard
Microsoft 365 licence plus the seeded connectors.

```
                        ┌──────────────────────────────────────┐
                        │   Power Apps canvas app              │
                        │   26 screens · 9 components          │
                        │   Dashboard · Register · Workspace   │
                        └──────┬───────────────────────┬───────┘
                               │ read/write            │ .Run()
                               ▼                       ▼
        ┌──────────────────────────────┐   ┌─────────────────────────────┐
        │  SharePoint Online           │   │  Power Automate             │
        │  29 lists · 5 libraries      │◄──┤  14 flows                   │
        │  Indexed, delegable          │   │  reminders · escalation     │
        │                              │   │  approvals · import · docs  │
        └──────────────────────────────┘   └─────────────────────────────┘
                       ▲                                  │
                       │                                  ▼
        ┌──────────────┴───────────────┐   ┌─────────────────────────────┐
        │  PnP PowerShell provisioning │   │  Office 365 · Approvals     │
        │  schema · master data · ACLs │   │  Excel Online (import)      │
        └──────────────────────────────┘   └─────────────────────────────┘
```

## The four decisions that shape everything else

### 1. Denormalised keys and stored derived values

SharePoint lookup columns are not delegable in Power Apps, and SharePoint calculated
columns cannot be indexed. Both facts matter enormously at the volumes in the brief
(5,000 LCs, 20,000 invoices).

So every child list carries `LCItemId` (indexed number), `LCNumber` and `InternalLCID`
as plain columns, and every derived amount — `OutstandingAmount`, `NetProceeds`,
`MissingDocumentCount`, `UtilizedAmount` — is a **stored** column maintained by the app on
save and by flows on a schedule.

The cost is that a value can drift if a write fails halfway. The mitigation is that
`ExportLC-11` recomputes the counters hourly, so drift self-corrects within an hour
rather than persisting silently.

The benefit is that every register query, every dashboard filter and every report is one
indexed server-side call. That is the difference between a portal that stays usable at
5,000 records and one that quietly starts lying at 2,000.

### 2. Configuration lives in lists, not in formulas

Reminder offsets, escalation windows, approval thresholds, ID patterns, dashboard
windows, the critical-field list for auditing, validation switches — all of it is rows in
`18_WorkflowConfig`, read through four user-defined functions (`CfgT`, `CfgN`, `CfgB`,
`CfgList`). Statuses and their legal transitions are rows in `16_StatusMaster`. Document
requirements are rows in `19_DocChecklistTemplates`.

Nothing in the app or the flows contains a literal business threshold. Changing when a
reminder fires, which statuses may follow which, or which documents an Ethiopian LC
requires is a list edit by an administrator, not a redeployment.

### 3. The audit trail is append-only at the permission layer

`10_AuditLog` and `26_NotificationLog` have inheritance broken and a custom **LC Append
Only** permission level applied: Contribute minus `EditListItems`, `DeleteListItems` and
`DeleteVersions`. Officers, reviewers and managers can add rows and read them, and cannot
change or remove one. Only administrators keep Full Control, so history can be archived.

An audit trail the audited party can edit is not an audit trail.

### 4. Aggregates are computed server-side

`CountRows()` and `Sum()` are not delegable against SharePoint. An in-app dashboard count
over 5,000 LCs returns a number capped at the row limit — and gives no warning that it
did. `ExportLC-11-RecomputeDashboardMetrics` computes every KPI in a flow and writes
sixteen small rows to `29_DashboardMetrics`; the dashboard reads those. The screen shows
the computation timestamp and marks itself stale after 90 minutes, because a figure with
no timestamp is a figure nobody trusts.

## Layers

| Layer | Holds | Changed by |
|---|---|---|
| Transactional | `01`–`09` — LCs, amendments, invoices, shipments, presentations, discrepancies, proceeds, correspondence, tasks | Officers, through the app |
| Evidence | `10_AuditLog`, `26_NotificationLog`, the five libraries | Append-only, by the app and flows |
| Configuration | `16`, `18`, `19` — statuses, workflow config, checklist templates | Administrators, in the Admin screen |
| Master data | `11`–`15`, `21`–`25` — customers, banks, countries, currencies, document types, Incoterms, ports, LC types, discrepancy categories, payment terms | Administrators |
| Derived | `20_LCDocumentChecklist`, `29_DashboardMetrics` | Materialised from configuration and recomputed by flows |
| Staging | `27_ImportBatches`, `28_ImportStaging` | The import pipeline; never written directly |

## Repository layout

```
sharepoint/
  schema/site-schema.json          single source of truth: 29 lists, 5 libraries, 549 columns
  scripts/Inspect-Environment.ps1  PHASE 1 - read-only survey of the target site
  scripts/Provision-ExportLCPortal.ps1
  scripts/Import-MasterData.ps1
  scripts/Set-Permissions.ps1
  masterdata/*.csv                 seed data, part extracted from the legacy workbooks
powerapps/ExportLCPortal/Src/
  App.fx.yaml                      theme tokens, config accessors, delegable queries
  Components/Components.fx.yaml    9 reusable components
  Screens/*.fx.yaml                26 screens
powerautomate/
  flows/<name>/definition.json     14 flow definitions
  Build-FlowPackages.ps1           builds importable zips
migration/
  extract_legacy.py                reads the legacy workbooks, validates, stages
  out/                             staging CSVs, validation report, reconciliation summary
portal-reference/index.html        runnable UX reference for the portal design
legacy/                            the two original Excel trackers, untouched
docs/                              this documentation
```

## What is deliberately not here

- **Dataverse.** The brief specifies SharePoint. Dataverse would give real relationships,
  server-side calculated columns and proper row-level security, and would remove most of
  decision 1 above. If the licensing is available it is the better platform for this, and
  the data model here ports to it cleanly. See `09-limitations-and-roadmap.md`.
- **A model-driven app.** The portal experience the brief asks for — a dashboard whose
  tiles drill through into a filtered register, a workspace with a lifecycle rail — is a
  canvas app's strength and a model-driven app's weakness.
- **Custom connectors or PCF components.** Both would need a premium licence and a
  developer to maintain them.
