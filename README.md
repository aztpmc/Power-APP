# Export LC Portal

A production-grade Export Letter of Credit portal for Treasury / Trade Finance, built on
Power Apps, SharePoint Online and Power Automate. No premium connectors, no Dataverse, no
custom code components.

Everything here is deployable source: a SharePoint schema that provisions itself, master
data extracted from the existing Excel trackers, the full canvas app, fourteen flows, and
the scripts that create all of it.

## What is in the box

| | |
|---|---:|
| SharePoint lists | 29 |
| Document libraries | 5 |
| Columns | 550 |
| Power Apps screens | 26 |
| Reusable components | 9 |
| Lines of Power Fx source | 15,503 |
| Power Automate flows | 14 |
| Master data rows seeded | 471 |
| Automated validation checks | 28, all passing |

## Start here

| If you want to | Read |
|---|---|
| **Build this tonight, step by step** | [`docs/11-quickstart-at-home.md`](docs/11-quickstart-at-home.md) |
| Understand the shape of the thing | [`docs/01-architecture.md`](docs/01-architecture.md) |
| Deploy it (the longer, fuller version) | [`docs/07-deployment-runbook.md`](docs/07-deployment-runbook.md) |
| See the design before building it | open [`portal-reference/index.html`](portal-reference/index.html) in a browser |
| Know what the legacy data needs fixing | [`docs/10-source-data-analysis.md`](docs/10-source-data-analysis.md) |
| Know what was and was not tested | [`docs/08-testing.md`](docs/08-testing.md) |
| Know what this cannot do | [`docs/09-limitations-and-roadmap.md`](docs/09-limitations-and-roadmap.md) |

## Two things to know up front

**Nothing has been deployed.** I had no access to a Microsoft 365 tenant in this session —
no SharePoint site, no Power Apps Studio, no Power Automate. So no list was created and no
flow was run. What exists is the complete solution as source, plus scripts that build it.
The runbook is about two hours, most of it waiting. Everything verifiable offline was
verified mechanically: `python3 tools/validate_solution.py` runs 28 checks and they all
pass.

**I do not have the Policy Portal screenshots.** They were provided in an earlier
conversation that is not in this session, and there are no images in the repository. Rather
than guess, I built the standard internal-portal pattern and isolated every colour, size
and spacing value in one theme block at the top of `App.fx.yaml`. Matching your actual
Policy Portal is then an edit to ~40 values, not a re-layout of 26 screens.

## Layout

```
sharepoint/
  schema/site-schema.json          single source of truth for every list, library and column
  scripts/Inspect-Environment.ps1  read-only survey — run this first
  scripts/Provision-ExportLCPortal.ps1
  scripts/Import-MasterData.ps1
  scripts/Set-Permissions.ps1
  masterdata/*.csv                 14 seed files, part extracted from your own workbooks
powerapps/ExportLCPortal/Src/
  App.fx.yaml                      theme, config accessors, delegable query layer
  Components/Components.fx.yaml    9 components
  Screens/*.fx.yaml                26 screens
powerautomate/
  flows/<name>/definition.json     14 flows
  Build-FlowPackages.ps1
migration/
  extract_legacy.py                reads the legacy workbooks, validates, stages
  out/                             staging CSVs, validation report, reconciliation
tools/validate_solution.py         28 offline checks over the whole solution
portal-reference/index.html        runnable UX reference
legacy/                            the two original trackers, untouched
docs/                              ten documents
```

## Quick start

```bash
# 1. See what the legacy data holds and what needs fixing (offline, changes nothing)
python3 migration/extract_legacy.py
cat migration/out/summary.md

# 2. Check the solution is internally consistent
python3 tools/validate_solution.py
```

```powershell
# 3. Guided SharePoint-side deployment: inspect, provision, master data,
#    permissions, flow packages — one script, a few Y/n prompts.
.\Deploy-ExportLCPortal.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
```

Then [`docs/11-quickstart-at-home.md`](docs/11-quickstart-at-home.md) for building the
canvas app in Studio and wiring up the flows — the one part that can't be scripted.

## What the legacy data turned up

Running the extractor against `LC Master Export 2026.xlsx` and `LC Export.xlsx` produced 20
LCs, 60 invoices, 127 customers and 28 banks — and found real problems that need a decision
before migration:

- **Six LCs are drawn against but not registered.** Twelve invoices worth $2.67M reference
  credits that exist in the invoice tracker and not in the LC tracker.
- **Four invoices have a number but no value.**
- **One invoice has two different amounts** in the two workbooks, differing by $32,690.
- **One LC is overdrawn** by $28,900 — probably a missing amendment.
- **Four customers appear twice with different codes.**
- **The `Summary` sheet is broken** — `#REF!` errors, and it claims 14 LCs where the tracker
  has 20.

Details and a recommended sequence: [`docs/10-source-data-analysis.md`](docs/10-source-data-analysis.md).

## Three design decisions worth knowing

**Nothing important is hard-coded.** Reminder offsets, escalation windows, approval
thresholds, ID patterns, dashboard windows, which fields are audited as critical, which
documents each market requires, and every status with its legal transitions — all rows in
SharePoint lists, edited by an administrator in the portal. There is no business threshold
written as a literal anywhere in the app or the flows.

**Every query runs on the server.** SharePoint stops filtering at 500–2,000 rows and
returns a smaller answer with no error. Every register, dashboard and report query here is
written to fold into an OData query against indexed columns — which is why relationships
are denormalised keys rather than lookup columns, why derived amounts are stored rather
than calculated, and why dashboard counts come from a flow rather than `CountRows()`. The
reasoning is in [`docs/04-powerfx-patterns.md`](docs/04-powerfx-patterns.md).

**Reminders do not repeat themselves.** Every flow writes an idempotency key to
`26_NotificationLog` before sending. Without it a "30 days to expiry" warning re-sends every
day for thirty days, people stop reading them, and the notification system becomes worse
than nothing.
