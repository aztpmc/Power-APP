# Export LC Portal — handoff brief

Give this whole file to Codex (or paste its content) as the starting context. It explains
what exists, what's done, what's blocked, and what to do next.

## 1. What this project is

An "Export Letter of Credit Portal" for Astra Industrial Group, built on:
- **SharePoint Online** (data layer — 34 lists/libraries, 550 columns)
- **Power Apps canvas app** (front end)
- **Power Automate** (14 flows — import validation, notifications, dashboard refresh)

No Dataverse, no premium connectors — everything runs on the company's existing
Microsoft 365 / SharePoint subscription.

**Live SharePoint site (already provisioned and populated):**
```
https://astraindustrial.sharepoint.com/sites/TreasuryManagementSystemTMS
```

**Source code (GitHub):**
```
https://github.com/aztpmc/Power-APP
Branch: claude/export-lc-portal-3set8f
PR #1: https://github.com/aztpmc/Power-APP/pull/1
```
Zip download (no git needed):
```
https://github.com/aztpmc/Power-APP/archive/refs/heads/claude/export-lc-portal-3set8f.zip
```

## 2. What is DONE and working, right now, on the live site

- **All 34 SharePoint lists/libraries exist** with all 550 columns, correct types,
  choices, indexing (respecting SharePoint's 20-indexed-column-per-list cap).
  Schema source of truth: `sharepoint/schema/site-schema.json`.
- **All master/reference data loaded**: customers, banks, countries, currencies,
  statuses, workflow config, etc. (156 rows added, 66 updated on the last successful
  run of `sharepoint/scripts/Import-MasterData.ps1`).
- **Security model applied**: 5 SharePoint groups (Administrators, Managers, Officers,
  Reviewers, Readers), 2 custom permission levels, admin-only master data lists,
  append-only audit/notification logs. Script: `sharepoint/scripts/Set-Permissions.ps1`.
- **Real legacy LC data extracted and ready**: `migration/out/staging_01_ExportLCs.csv`
  (20 real LCs) and `migration/out/staging_03_Invoices.csv` (56 of 60 real invoices,
  4 excluded for missing values — see `migration/out/summary.md`), extracted from the
  user's actual `LC Export.xlsx` / `LC Master Export 2026.xlsx` via
  `migration/extract_legacy.py`. Not yet loaded into the live lists.
- **14 Power Automate flow definitions** ready to package: `powerautomate/`. Not yet
  imported into make.powerautomate.com.

All of the above is idempotent and safe to re-run:
```powershell
.\Deploy-ExportLCPortal.ps1 -SiteUrl https://astraindustrial.sharepoint.com/sites/TreasuryManagementSystemTMS
```
(orchestrates Inspect → Provision → Import-MasterData → Set-Permissions → package flows)

## 3. What is BLOCKED / being abandoned

The original plan was a fully custom canvas app: 26 hand-designed screens, 9 reusable
components, named formulas / user-defined functions, all authored as Power Fx source in
`powerapps/ExportLCPortal/Src/*.fx.yaml`, meant to be copy-pasted into Power Apps Studio
screen by screen (there is no supported "import this YAML folder" command in Studio).

This hit a wall: pasting `App.fx.yaml`'s `Formulas`/`OnStart` blocks into Studio's
formula editor kept producing dozens of parse errors. Root causes found and fixed in the
source file (already pushed to the branch):
- 12 user-defined functions had invalid `: Table` / `: Record` return-type annotations
  (Power Fx doesn't accept those as generic type names) — fixed, type annotations
  removed, inference used instead.
- The `.fx.yaml` file format prefixes formula bodies with `=` as a **file-format
  convention** (to distinguish formula from literal string in YAML). That leading `=`
  must NOT be pasted into Studio's `OnStart`/`OnError` property boxes — Studio expects
  the raw expression with no leading `=`. This was undocumented and cost a lot of time.
  **If anyone resumes the custom-build path, strip the leading `=` from OnStart/OnError
  before pasting; Formulas doesn't have this problem since each named formula's own `=`
  is the real assignment operator.**

Even after those fixes, the user (on a locked-down corporate laptop, no admin rights,
copy-pasting a ~350-line formula block by hand) hit diminishing returns and decided to
**abandon the full custom-build approach for now**.

The full custom source is still in the repo and still valid — it's just not what's being
built right now. Revisit it later if/when there's appetite for the complete design
(dashboard, KPI cards, per-module registers, document checklist workflow, etc.).

## 4. What we're doing INSTEAD (current direction, in progress)

Building a **simple, Power-Apps-auto-generated app** directly against the live
SharePoint lists — zero formula pasting, using Studio's built-in "Start with data"
generator (Browse/Detail/Edit screens per list, wired automatically).

Steps so far:
1. Created blank app "Export LC Portal", connected all 34 data sources manually (tedious
   but done).
2. Abandoned that app in favor of **Start with data** on `01_ExportLCs` directly — this
   auto-generates working screens with zero manual formula work.
3. In progress: renaming the generated app, publishing it, and testing it opens with
   real data.

Note: two OTHER auto-generated apps already exist in this Power Apps environment from
earlier attempts — **"Export LC Management"** and **"Export LC APP"** — both built off
`01_ExportLCs` with basic auto-generated forms. These are candidates to just reuse/rename
rather than creating yet another one, if their state turns out to be usable.

### Next steps for Codex to pick up

1. Confirm/finish: rename+publish the current auto-generated app as "Export LC Portal".
2. Test it opens and shows real LC data.
3. Add more entities the same low-effort way: for each of the other important lists
   (`03_Invoices`, `04_Shipments`, `05_Presentations`, `06_Discrepancies`, `07_Proceeds`,
   `09_Tasks`), add a new screen (**+ New screen → List layout**) bound to that list via
   the Data pane — this is drag/drop, no formulas needed.
4. Import the 14 Power Automate flows from `powerautomate/packages/` (run
   `powerautomate/Build-FlowPackages.ps1 -SiteUrl <site>` first if the zips don't exist
   yet) via make.powerautomate.com → My flows → Import → Import Package (Legacy).
5. Load the real legacy LC/invoice data (`migration/out/staging_*.csv`) into
   `01_ExportLCs` / `03_Invoices` via SharePoint's Quick Edit grid view (paste rows
   directly — column order must match the live list's column order).
6. Add real users to the 5 SharePoint groups, add matching rows in `17_Users`
   (RoleCode, ManagerEmail), set `EscalationManagerEmail`/`PortalSupportEmail` in
   `18_WorkflowConfig`, and share the Power App with the 5 groups.

## 5. Known environment gotchas (don't rediscover these)

- **PnP.PowerShell needs PowerShell 7**, not Windows PowerShell 5.1.
- **No default sign-in app on newer tenants** — all scripts here default `-ClientId` to
  Microsoft's own pre-consented "SharePoint Online Management Shell" app
  (`9bc3ab49-b65d-410a-85ad-de819febfddc`) automatically now, so this should just work.
- **`Connect-PnPOnline -Interactive` can fail with "Specified method is not supported"**
  on machines without the WAM browser broker — every script auto-falls-back to
  `-DeviceLogin` (prints a URL + code to enter in any browser).
- **Execution policy**: unsigned local scripts may be blocked. Fix per-window (no admin
  needed): `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`.
- **SharePoint's hard cap: 20 indexed columns per list.** Already respected in the
  schema; don't add another indexed column to a list already at 20.
- **`Get-PnPField -Identity X` matches by internal name OR display Title**
  (SharePoint's `GetByInternalNameOrTitle`). If a "ghost" field exists whose *display
  name* happens to equal a wanted internal name, the provisioning script will think that
  field already exists and skip creating the real one. Symptom: a field silently missing
  its real internal name even though provisioning reports no failures. Fix: rename the
  ghost field's display Title (`Set-PnPField -List X -Identity <ghost internal name>
  -Values @{ Title = "something else" }`), then re-run provisioning.
- **No `git` on the locked-down laptop** — use the zip download link above, extract,
  replace the folder each time there's a code update (no git pull available).
- This is a **corporate laptop with SOC monitoring** — the user is understandably
  cautious about what runs on it. They have verbal approval for this project. Don't push
  toward anything that needs new software installs beyond what's already been approved
  (PowerShell 7 + PnP.PowerShell were approved and installed).

## 6. Files worth knowing about

- `sharepoint/schema/site-schema.json` — full 34-list/library schema, single source of
  truth.
- `sharepoint/scripts/*.ps1` — provisioning, master data load, permissions.
- `Deploy-ExportLCPortal.ps1` — orchestrator, chains the above.
- `powerapps/ExportLCPortal/Src/*.fx.yaml` — the full custom app source (parked, see
  §3).
- `migration/extract_legacy.py`, `migration/out/*` — real legacy data extraction +
  output, ready to load.
- `powerautomate/*` — the 14 flow definitions + packaging script.
- `docs/*.md` — detailed docs for every phase (data model, Power Fx patterns, testing
  plan, deployment runbook, quickstart).
- `tools/validate_solution.py` — structural validator for the schema/app/flows (30
  checks, all passing). Run with `python3 tools/validate_solution.py`.
