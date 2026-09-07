# Known limitations and roadmap

## What I could not do in this session, and why

**I have no access to your Microsoft 365 tenant.** No SharePoint site, no Power Apps
Studio, no Power Automate, no connectors. Requirement 36 asks for the actual application to
be built if the environment is available — it is not, so what exists instead is the
complete solution *as deployable source*: a schema that provisions itself, master data
extracted from your own workbooks, 15,000 lines of canvas app source, 14 flow definitions,
and scripts that create all of it. `docs/07-deployment-runbook.md` is the path from this
repository to a running portal, and it is about two hours of mostly waiting.

**I do not have the Policy Portal screenshots.** They were provided in an earlier
conversation which is not in this session, and there are no image files in the repository.
I have not guessed at them. What I built is the standard internal-portal pattern, with
every colour, size and spacing value isolated in one theme block so that matching your
actual Policy Portal is a ~40-value edit rather than a re-layout. See
`docs/03-ux-spec.md`.

**Nothing has been run against a live environment.** Everything verifiable offline was
verified mechanically — 28 automated checks, all passing, plus the migration extractor run
against your real workbooks. Everything else needs the manual test plan in
`docs/08-testing.md`.

## Platform limitations you will hit

### SharePoint

| Limit | Effect | Mitigation here |
|---|---|---|
| 5,000 item list view threshold | Unindexed queries fail above it | Every query filters on an indexed column first; folders per LC in libraries |
| 20 indexed columns per list | `01_ExportLCs` uses all 20 | Documented; adding one means removing one |
| Lookup columns are not delegable | Would break the register at scale | Denormalised indexed text/number keys instead |
| Calculated columns cannot be indexed | Derived amounts could not be sorted or filtered | Stored columns, maintained by app and flow |
| `CountRows`/`Sum` are not delegable | Dashboard counts would silently cap | Pre-aggregated in `29_DashboardMetrics` by `ExportLC-11` |
| No transactions | A multi-list write can half-fail | Correlation ids in the audit trail; `ExportLC-11` re-derives counters hourly |
| No cascade delete | Deleting an LC orphans its children | Deletion is admin-only; closure is the normal path |
| 30M items per list ceiling | Not a practical concern at these volumes | Audit partitioned by `yyyy-mm` regardless |

### Power Apps

- **Prefix search only.** `StartsWith` is delegable; general "contains" is not. Searching
  for a fragment from the middle of an LC number will not find it. The search screen says
  so rather than returning a quietly incomplete answer.
- **User columns are not delegable**, so every person column has a denormalised email twin
  (`ResponsibleOfficerEmail`, `AssignedToEmail`) for filtering.
- **User-defined functions** must be enabled in app settings. If your tenant does not have
  them, `docs/04-powerfx-patterns.md` gives the inline `LookUp` substitution.
- **Canvas component custom properties** may need creating by hand in Studio if your `pac`
  CLI version rejects the `CustomProperties` YAML block — the property names and types are
  listed at the top of each component.
- **Offline use is not supported.** The portal needs a connection.

### Power Automate

- **Reminder timing is whole-UTC-day.** Set each trigger's time zone to your operating
  hours so a reminder does not land a day early at the edges.
- **`GetItems` pagination is capped at 5,000** per query in these flows. Beyond that, split
  by responsible officer or page explicitly.
- **The import flow needs a named table `LCImport`** in the workbook. The supplied template
  has one; an arbitrary legacy tracker needs one added.
- **The Approvals connector** needs approvers licensed for it. Where that is not available,
  replace the approval action in `ExportLC-09` with an email and a manual status change.

## Functional gaps

Things a mature trade finance system would have that this does not:

| Gap | Impact | Effort to add |
|---|---|---|
| **Customer scope is not a security boundary** | `CustomerScope` filters the UI but does not stop a user reaching other customers' data through SharePoint directly | High on SharePoint (item-level permissions do not scale); trivial on Dataverse |
| **No SWIFT message parsing** | MT700/707/750 details are keyed by hand | Medium — an Azure Function or a parsing flow |
| **No bank system integration** | No automatic status or payment feed | High, and depends entirely on what the banks offer |
| **No multi-currency revaluation** | Exposure uses a static rate from `14_Currencies` | Low — a flow calling an FX API on a schedule |
| **No document OCR or content checking** | Discrepancy detection is entirely human | High |
| **No sub-limits or revolving reinstatement logic** | Revolving LCs are flagged but not automatically reinstated | Medium |
| **No back-to-back linkage** | The LC type exists; the link between master and back-to-back credit does not | Low — one lookup column and a workspace panel |
| **No charge recovery workflow** | Charges are recorded, not chased | Low |
| **Reports do not chart** | Twelve tabular reports with CSV export; no visuals | Low — Power BI over the same lists |
| **No mobile-optimised presentation flow** | Presentations are desktop-shaped | Medium |

## Where the data model could drift

Denormalisation is a deliberate trade, and it has a cost worth naming:

- `CustomerName` is stored on the LC and on every child. Renaming a customer in
  `11_Customers` does **not** rewrite history. That is arguably correct — the LC was
  advised to the name as it stood — but it is a decision, not an accident. If a rename
  should cascade, add a flow to do it.
- `UtilizedAmount`, `OutstandingAmount`, `MissingDocumentCount` and `OpenDiscrepancyCount`
  are maintained on write and re-derived hourly. Between a failed write and the next
  `ExportLC-11` run, a counter can be stale for up to an hour.
- `16_StatusMaster` transitions are enforced by the app, not the database. Someone editing
  a list item directly in SharePoint can set any status. The SharePoint permission model
  limits who can, but it does not enforce the workflow. This is a genuine hole; on
  Dataverse a business rule would close it.

## Roadmap

### Before go-live

1. Resolve the migration findings in `docs/10-source-data-analysis.md` — six unregistered
   LCs, four invoices with no value, one amount conflict, four customer code conflicts.
2. Set `EscalationManagerEmail` and `PortalSupportEmail`.
3. Load-test at 5,000 LCs and verify test X4 in `docs/08-testing.md` — that the register
   count is right, not capped.
4. Send me the Policy Portal screenshots and re-skin the theme block.
5. Walk the manual test plan with one treasury officer, not just an administrator.

### Next quarter

1. **Power BI over the same lists** — the reports here are tabular by design; charting
   belongs in Power BI, not in painted Power Apps rectangles.
2. **FX rate refresh flow** — a scheduled call to an FX API into `14_Currencies`.
3. **Cover letter and certificate generation** — the legacy workbook already has the
   templates; a flow can populate and file them from the presentation record.
4. **Bank-specific checklist templates** — the template layer already supports customer and
   country; adding bank is one column and one match criterion.
5. **Back-to-back LC linkage.**

### The bigger decision

**Move to Dataverse if the licensing allows it.** It removes most of the compromises in
this build: real relationships instead of denormalised keys, server-side calculated and
rollup columns instead of app-maintained counters, row-level security instead of
UI-only customer scope, business rules that hold regardless of the client, and no 5,000
item threshold or 20-index limit.

The data model here ports cleanly — the entities, fields, statuses and transitions are all
platform-neutral, and `sharepoint/schema/site-schema.json` is a machine-readable starting
point for the Dataverse tables. The app screens need rebinding but not redesigning.

This is worth costing properly rather than treating as a nice-to-have. The single strongest
argument is the customer-scope hole: on SharePoint it cannot be closed at acceptable
performance, and on Dataverse it is a configuration setting.
