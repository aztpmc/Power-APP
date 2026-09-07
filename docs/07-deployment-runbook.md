# Deployment runbook

Roughly two hours end to end on a clean site, most of it waiting for scripts.

## Prerequisites

| Need | Notes |
|---|---|
| SharePoint Online site collection | New site recommended. Team site (no group) or communication site both work |
| Site Collection Administrator | Required for `Set-Permissions.ps1` |
| PnP.PowerShell 2.x | `Install-Module PnP.PowerShell -Scope CurrentUser` |
| Python 3.8+ | Only for the legacy extraction; standard library only |
| Power Apps and Power Automate | Seeded connectors only — no premium licence needed |

First run in a tenant may need an app registration for interactive PnP login:

```powershell
Register-PnPEntraIDAppForInteractiveLogin `
  -ApplicationName "Export LC Portal Provisioning" `
  -Tenant contoso.onmicrosoft.com
```

## Phase 1 — inspect (read only)

```powershell
cd sharepoint\scripts
.\Inspect-Environment.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
```

Reports the site, every list and library with item counts, anything that looks like an
existing LC tracker, any list already over 5,000 items, which of the 34 solution objects
already exist and whether their columns conflict, and the SharePoint groups.

**Changes nothing.** Read the `environment-inventory-*.csv` it writes before continuing. If
it reports existing objects with the same names, decide whether to reuse them or provision
into a separate site — provisioning will reuse them and add only missing columns, and will
never alter or delete a column that already exists.

## Phase 2 — extract the legacy data (offline)

```bash
python3 migration/extract_legacy.py
```

Reads the workbooks in `legacy/`, writes master data seeds to `sharepoint/masterdata/`
and staging plus reports to `migration/out/`. Touches nothing online.

Read `migration/out/summary.md` and `migration/out/validation_report.csv` before
importing anything. On the supplied data this surfaces 4 rejects and 19 warnings that
need a human decision — see `docs/10-source-data-analysis.md`.

## Phase 3 — provision

Dry run first:

```powershell
.\Provision-ExportLCPortal.ps1 -SiteUrl <url> -WhatIf
```

Then for real:

```powershell
.\Provision-ExportLCPortal.ps1 -SiteUrl <url>
```

Creates 29 lists, 5 libraries, 550 columns, indexes and views. Idempotent: existing objects
are reused and reported, never recreated or deleted. Writes `provision-report-*.csv`. Exits
non-zero if anything failed.

Expect 10–20 minutes. Column creation is one call each; there is no bulk API for this.

## Phase 4 — master data

```powershell
.\Import-MasterData.ps1 -SiteUrl <url> -WhatIf
.\Import-MasterData.ps1 -SiteUrl <url>
```

Loads 14 CSVs: 127 customers, 28 banks, 24 countries, 14 currencies, 29 document types,
83 statuses with their transitions, 49 configuration rows, 26 checklist template rules, 11
Incoterms, 23 ports, 10 LC types, 25 discrepancy categories, 6 payment terms and 16
dashboard metric rows.

Idempotent and non-destructive: rows are matched on a natural key and updated field by
field, never replaced, and rows an admin added by hand are left alone.

## Phase 5 — permissions

```powershell
.\Set-Permissions.ps1 -SiteUrl <url> -WhatIf
.\Set-Permissions.ps1 -SiteUrl <url>
```

Creates two custom permission levels and five groups, then locks master data to admins and
makes the audit and notification logs append-only.

Then, manually:

1. Add users to the five groups.
2. Add a row per user in `17_Users` with `RoleCode` and `ManagerEmail`.
3. Set `EscalationManagerEmail` and `PortalSupportEmail` in `18_WorkflowConfig`.

Step 3 matters more than it looks: several flows fall back to the escalation mailbox when a
record has no responsible officer, and with it blank they log the notification as
`Suppressed` and send nothing.

## Phase 6 — the canvas app

Either pack the source:

```bash
pac canvas pack --sources powerapps/ExportLCPortal/Src --msapp ExportLCPortal.msapp
```

then import the `.msapp` in Power Apps Studio.

Or build in Studio directly:

1. New canvas app, tablet layout.
2. Add the SharePoint data sources — all 29 lists and 5 libraries.
3. Enable **Settings → Updates → User-defined functions**.
4. Paste the `Formulas` block from `App.fx.yaml` into **App → Formulas**, and the `OnStart`
   block into **App → OnStart**.
5. Create the 9 components with the input properties listed at the top of each in
   `Components.fx.yaml`, then paste the child controls.
6. Create each screen and paste its control tree from `Screens/*.fx.yaml`.
7. Add the four app-called flows to the app (`ExportLC-11`, `-12`, `-13`, `-14`).

Screen YAML pastes directly onto a blank screen in Studio — Studio accepts control YAML on
the clipboard.

## Phase 7 — flows

```powershell
cd powerautomate
.\Build-FlowPackages.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
```

Then per zip: **make.powerautomate.com → My flows → Import → Import Package (Legacy)**, map
connections to existing ones, import, open the flow, turn it on.

Import `ExportLC-12` before `ExportLC-13`. Order does not matter for the rest.

Run `ExportLC-11-RecomputeDashboardMetrics` manually once so the dashboard has figures.

## Phase 8 — the import template

Upload the Excel import template to `ExportLCTemplates` with `TemplateCode = IMPORT_LC`.
The workbook must contain a named table called **`LCImport`** with these columns:

```
LCNumber, OurReference, CustomerName, CountryName, IssuingBankName,
AdvisingBankName, CurrencyCode, LCAmount, ReceivedDate, IssuanceDate,
ExpiryDate, LatestShipmentDate, PaymentTermText
```

`ExportLC-12` reads that table by name; without it the flow cannot parse the file.

## Phase 9 — migrate the legacy data

1. Re-read `migration/out/validation_report.csv` and fix what it flags at source.
2. Re-run the extractor.
3. Create an import batch through the portal's Import screen and upload the corrected
   workbook.
4. Review the preview. Nothing has been written to the live register at this point.
5. Set a duplicate action on any duplicate rows.
6. Commit. Only valid rows are written; rejected rows stay staged with their reasons.
7. Reconcile the committed totals against `migration/out/summary.md`.

## Phase 10 — verify

Work through `docs/08-testing.md`. The short version:

- Register an LC. Check the internal ID pattern, the checklist materialising, and the
  audit row.
- Try to save an LC whose latest shipment date is after expiry. It must refuse and say why.
- Try an illegal status transition. It must not even be offered.
- Add an invoice; check the LC's utilised and outstanding amounts update.
- Record an amendment, accept it, apply it; check the before/after trail and the audit rows.
- Upload a document; check it lands in the right library with metadata and ticks the
  checklist.
- Run each reminder flow twice; the second run must send nothing.
- Sign in as each role and confirm what is and is not offered.

## Rollback

| Step | How |
|---|---|
| Bad import | Every row carries `ImportBatchId`. Filter `01_ExportLCs` on it and delete; staging rows keep the evidence |
| Bad master data load | Lists have versioning; restore the previous version, or re-run the loader from a corrected CSV |
| Bad provisioning | Nothing is deleted, so a re-run is safe. Remove an unwanted list manually |
| Bad flow | Turn it off. Reminders are idempotent, so nothing double-sends when you turn it back on |
| Bad app version | Power Apps keeps version history; restore the previous published version |

## Ongoing operations

| Task | Frequency | How |
|---|---|---|
| Check flow run history | Weekly | Power Automate → the fourteen flows |
| Review `26_NotificationLog` for `Failed` / `Suppressed` | Weekly | Usually a missing responsible officer |
| Update FX rates in `14_Currencies` | Monthly, or when they move | Admin screen |
| Archive audit partitions older than `AuditRetentionMonths` | Yearly | Export by `PartitionKey`, then delete |
| Review `16_StatusMaster` transitions | On process change | Admin screen |
| Review checklist templates | On new market or new bank requirement | Admin screen |
