# Quickstart — building this at home

Action-first version of `07-deployment-runbook.md`. Read that one for the reasoning; use
this one to actually type commands in order.

Total time: **roughly 2–3 hours**, most of it either waiting on a script or pasting YAML
into Studio. Nothing here needs a premium licence — SharePoint Online + Power Apps/Power
Automate on a standard Microsoft 365 plan is enough.

## 0. Install, once

| Tool | Command |
|---|---|
| PowerShell 7 | https://aka.ms/powershell — installer, not the command line |
| PnP.PowerShell | `Install-Module PnP.PowerShell -Scope CurrentUser` |
| Git | https://git-scm.com (if you don't already have it) |
| VS Code (optional but nice) | https://code.visualstudio.com |

Then get the code:

```powershell
git clone https://github.com/aztpmc/Power-APP.git
cd Power-APP
git checkout claude/export-lc-portal-3set8f
```

That branch is what's in [PR #1](https://github.com/aztpmc/Power-APP/pull/1) — everything
described below is already on it.

### First-time sign-in setup

You normally don't need to do anything here — every script falls back to Microsoft's own
pre-consented **"SharePoint Online Management Shell"** app id automatically if you don't
pass `-ClientId`, so sign-in just works out of the box on most tenants.

If your tenant admin would rather you use a tenant-owned app instead of that shared
Microsoft one, run this once, as an admin:

```powershell
Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "Export LC Portal" -Tenant yourtenant.onmicrosoft.com
```

(`yourtenant.onmicrosoft.com` is your default tenant domain — the part before
`.sharepoint.com` in your site URL, with `.onmicrosoft.com` instead.) It signs you in,
creates the app, and prints a `ClientId` GUID. Pass it once and reuse it every time:

```powershell
.\Deploy-ExportLCPortal.ps1 -SiteUrl <url> -ClientId <guid-from-above>
```

Also worth knowing: `Connect-PnPOnline -Interactive` depends on a Windows component (WAM)
that isn't always available. If you see **"Specified method is not supported"**, that's
this — every script here catches it automatically and falls back to device login (it'll
print a URL and a short code; open the URL in any browser and type the code). Nothing to
do differently, it just takes one extra click. (If you ever see a confusing error about
`WriteObject`/`WriteError` methods and threads during that fallback, it means device login
ran with no client id at all — this no longer happens now that a default is always set, but
if you see it anyway, re-run and it will pick up the default.)

## 1. Pick or create the SharePoint site

New site collection recommended (Team site, no Microsoft 365 group needed). You need to be
a Site Collection Administrator on it.

```
https://YOURTENANT.sharepoint.com/sites/ExportLCPortal
```

## 2. Run the guided deployment script

This is new — I added it after the last message, specifically so tonight is "run one
script and answer a few Y/n prompts" instead of running four scripts by hand.

```powershell
.\Deploy-ExportLCPortal.ps1 -SiteUrl https://YOURTENANT.sharepoint.com/sites/ExportLCPortal
```

It will, in order, with a confirmation before anything is written and a `-WhatIf` dry run
before the real provisioning step:

1. **Inspect** the site — read only, shows what's already there.
2. **Provision** — 29 lists, 5 libraries, 550 columns, indexes, views.
3. **Load master data** — 127 customers, 28 banks, 83 statuses with their legal
   transitions, 49 config rows, etc. (471 rows total).
4. **Set permissions** — 5 SharePoint groups, 2 custom permission levels, audit lists
   locked to append-only.
5. **Package the 14 flows** into zips ready to import.

You'll sign in once (interactive, browser popup) — every phase reuses that connection.

If you'd rather run the four underlying scripts yourself one at a time (more control, more
typing), they're in `sharepoint/scripts/` and each is independently safe to re-run:
`Inspect-Environment.ps1`, `Provision-ExportLCPortal.ps1`, `Import-MasterData.ps1`,
`Set-Permissions.ps1`.

**Expect 20–30 minutes**, mostly SharePoint column creation (one API call each — there's
no bulk endpoint for this).

## 3. Build the canvas app

This is the one step that cannot be scripted end to end — Power Apps Studio has no
supported "import this folder of YAML" command. Two real paths; pick one.

### Path A — paste into Studio (reliable, works today, ~90 min)

1. **New app → Canvas → Blank → Tablet format.**
2. **Add data.** Add all 29 lists and 5 libraries from your site as data sources —
   `Insert → Data`, search each by name. Tedious but one-time; there's no way around it in
   Studio's UI (this is exactly what Path B automates).
3. **Turn on user-defined functions.** `Settings → Upcoming features → Experimental` (name
   varies by tenant release) → enable **User-defined functions**. Without this, the four
   config-reading functions in `App.fx.yaml` (`CfgN`, `CfgT`, `CfgB`, `CfgList`) won't
   compile — `docs/04-powerfx-patterns.md` has the inline fallback if your tenant genuinely
   doesn't have the feature yet.
4. **App formulas.** Open `powerapps/ExportLCPortal/Src/App.fx.yaml` in a text editor.
   Copy everything under `Formulas:` into **App → Advanced → App.Formulas** in Studio.
   Copy the `OnStart:` block into **App.OnStart**. Copy `OnError:` into **App.OnError**.
5. **Components, in this order** (later ones don't depend on earlier ones, but building
   `cmpStatusBadge` and `cmpKPICard` first lets you sanity-check the paste-and-property
   workflow on something simple): open `Components/Components.fx.yaml`, and for each of the
   9 components —
   - Create a new component, name it exactly as in the file (e.g. `cmpStatusBadge`).
   - Add its custom properties — the `CustomProperties:` block for each one lists the
     name, type and default; add them via the component's **Properties** pane.
   - Select the component canvas, and paste the child control block from the YAML
     (everything under the component name, indented). Studio accepts control YAML on the
     clipboard when a screen or component canvas has focus — select the canvas, Ctrl+V.
6. **Screens, in this order** (workspace and forms reference the register and dashboard's
   globals, so build in roughly this sequence): `scrDashboard` → `scrLCRegister` →
   `scrLCWorkspace` → `scrLCForm` → the eight `scr*Form` screens → the eight module
   register screens (`scrInvoices`, `scrShipments`, ... `scrAmendments`) → `scrDocuments` →
   `scrDocumentUpload` → `scrReports` → `scrAdmin` → `scrImport` → `scrSearch`.
   For each: **New screen → blank**, name it exactly as the file (e.g. `scrDashboard`),
   click the blank canvas, paste the whole file's content.
7. **Wire the four flows into the app** (Path A step, needed either way) — see step 5
   below, after you've built the flows.

If a paste throws an error on a specific control, it's almost always one of: a control
type not yet turned on for your tenant (rare — checkboxes, toggles, comboboxes, dropdowns,
attachments, galleries are all standard), or a component referenced before it exists (build
components before screens, screens roughly in the order above).

### Path B — `pac` CLI, if you want Studio to do less typing

This gets you a real `.msapp` you can just open, but it needs one extra step I want to be
honest about: `pac canvas pack` needs a `CanvasManifest.json` plus `DataSources/` and
`Connections/` folders that vary by tenant and by which lists you've connected — I didn't
fabricate those in the repo because a wrong one produces a `.msapp` that fails to open, and
that's a worse evening than just pasting.

The safe way to get a *real* one, then swap in this repo's formulas:

```powershell
# Install once
winget install Microsoft.PowerAppsCLI
pac auth create --url https://YOURTENANT.crm.dynamics.com   # or your env URL from make.powerapps.com

# 1. In Studio: make a throwaway blank canvas app, add all 29 lists + 5 libraries as
#    data sources (same tedious step as Path A #2 - no way around it either path),
#    save, publish, close Studio.
# 2. Unpack it - this generates a REAL CanvasManifest.json/DataSources/Connections
#    matching your tenant and your actual data source GUIDs.
pac canvas unpack --msapp ThrowawayApp.msapp --sources .\Unpacked

# 3. Replace the formula source with this repo's, keep the manifest/datasources/connections
Remove-Item .\Unpacked\Src -Recurse -Force
Copy-Item .\powerapps\ExportLCPortal\Src .\Unpacked\Src -Recurse

# 4. Pack it back into a real, valid .msapp
pac canvas pack --sources .\Unpacked --msapp ExportLCPortal.msapp

# 5. Open ExportLCPortal.msapp - double-click, or File > Open > Browse in Studio
```

If `pac canvas pack` complains about a control or component reference it doesn't
recognise, that's the pac CLI's schema version being behind Studio's — update pac
(`pac install latest`) or fall back to Path A for the screens it rejects.

**My honest recommendation:** Path A. It's slower to type but it's guaranteed to work,
you'll understand the app as you build it (useful for the manual test pass later), and you
won't lose an evening to a `.msapp` that won't open with no useful error message. Path B is
worth it once you're comfortable and want to iterate faster on v2.

## 4. Import the flows

```powershell
cd powerautomate
.\Build-FlowPackages.ps1 -SiteUrl https://YOURTENANT.sharepoint.com/sites/ExportLCPortal
```

(Already done if you ran `Deploy-ExportLCPortal.ps1` in step 2.)

Then, for each of the 14 zips in `powerautomate/packages/`:
**make.powerautomate.com → My flows → Import → Import Package (Legacy)** → upload the zip
→ map each connection reference to your existing SharePoint / Outlook / Approvals
connection → Import → open the flow → **Turn on**.

Import `ExportLC-12-ImportValidate` before `ExportLC-13-ImportCommit`. Order doesn't matter
for the other twelve.

## 5. Wire the four app-called flows into the app

Back in Studio: **Power Automate pane → Add flow** → add
`ExportLC-11-RecomputeDashboardMetrics`, `ExportLC-12-ImportValidate`,
`ExportLC-13-ImportCommit`, `ExportLC-14-UploadDocument`. The screens already call them by
name (`'ExportLC-11-RecomputeDashboardMetrics'.Run(...)` etc.), so once added they just
work.

## 6. Run ExportLC-11 once

Manually trigger it from Power Automate (or just open the dashboard in the app and hit
**Refresh** once it's built) so `29_DashboardMetrics` has real numbers instead of zeros.

## 7. Bring in the real data

```bash
python3 migration/extract_legacy.py
```

Read `migration/out/summary.md` first — it lists six unregistered LCs, four invoices with
no value, one amount conflict and four customer code conflicts that need a decision (see
`docs/10-source-data-analysis.md`). Fix what you can at source, then re-run.

Upload the corrected workbook via the app's **Import** screen (Administration →
Excel import), review the preview — nothing is written to the live register until you
press **Commit** — set a duplicate action on any duplicates, commit.

## 8. Test it

Walk `docs/08-testing.md`. The one test to be strict about: seed a few thousand LCs (or
however many you can) and check the register's row count is actually right, not silently
capped — that's the whole reason the delegation work in `docs/04-powerfx-patterns.md`
exists.

## If something breaks

- **A formula won't paste / shows red squiggles** — almost always a missing data source
  (step 3.2) or user-defined functions not enabled (step 3.3). Check those two first.
- **A screen references a global that's blank** — globals like `gblCurrentLC`,
  `gblChildContext` are set by the screen that navigates *to* the one you're testing (e.g.
  clicking a register row sets `gblCurrentLC` before opening the workspace). Testing a
  screen in isolation in Studio without navigating to it the normal way will show blanks —
  that's expected, not a bug.
- **A flow fails on first run** — check the `SiteUrl` parameter on that flow got set
  correctly (`Build-FlowPackages.ps1` stamps it, but Power Automate's import screen
  sometimes resets custom parameter defaults — check after import).
- **Anything else** — `docs/09-limitations-and-roadmap.md` lists the known platform
  limitations; check there before assuming it's a bug in this build.

## When you're back at a session with me

Tell me what broke and where (which screen, which step above) and I'll fix the source in
the repo — push the fix to this branch and it lands in
[PR #1](https://github.com/aztpmc/Power-APP/pull/1) automatically.
