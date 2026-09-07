# UX specification

## An honest note about the Policy Portal reference

The brief says screenshots of an internal Policy Portal were provided previously and
should be the primary visual benchmark. **Those screenshots are not in this session** — I
have no access to conversation history from earlier chats, and there are no image files
in the repository. I cannot see them, so I have not guessed at them.

What I built instead is the standard internal-portal pattern that a Policy Portal almost
certainly follows, and — more usefully — I made it **cheap to re-skin**. Every colour,
radius, type size and spacing value in the app is a named formula in one block at the top
of `App.fx.yaml`:

```
ThemeRailBg, ThemeAccent, ThemeSurface, ThemeBorder, ThemeText,
ThemeSuccess/Warning/Danger/Info/Progress/Muted (+ their Soft variants),
ThemeFont, ThemeSize{Display,Title,Heading,Body,Small,Micro},
ThemeSpace1-6, ThemeRadius, ThemeRailWidth, ThemeTopBarHeight, ThemeRowHeight
```

Nothing else in 15,000 lines of app source contains a literal colour or font size. Send
me the Policy Portal screenshots and matching its look is an edit to roughly forty values
in one place, not a re-layout of 26 screens.

`portal-reference/index.html` is a runnable rendering of the design in a browser, so the
look can be reviewed and corrected before anything is built in Studio.

## The philosophy this portal is built on

**A portal answers a question before it offers a function.** The dashboard's job is not to
be a menu; it is to answer "what is happening with my Export LCs?" in one screen. Every
tile is therefore a finding, not a category, and every tile is clickable — a KPI that
cannot be drilled into is decoration.

**One place to work, not a trail of forms.** Opening an LC lands in a workspace, not an
edit form. Twelve tabs, a header that never scrolls away, a lifecycle rail, and warnings
generated from the record. A treasury officer should be able to spend a morning inside one
LC without navigating back to a list.

**Density is a feature.** This is an operational tool used all day by people who know the
domain. Rows are 44px, not 72px. Type is 13px, not 16px. Whitespace is used to group, not
to impress. Eleven columns of an LC register on screen at once beats five columns and a
lot of air.

**State is always visible.** Where you are (rail highlight + breadcrumb), what you are
looking at (workspace header), what needs attention (badges, left flags, warning banners),
and when the figures were computed (dashboard freshness stamp).

**Nothing important is red without being actionable.** A left flag on a register row means
something specific: expired, expiring within 7 days, shipment deadline within 7 days, open
discrepancy, or missing documents. The row itself stays readable.

## Layout system

```
┌─────────────┬────────────────────────────────────────────────────────────┐
│             │  Top bar: title · breadcrumb · search · primary action     │
│  Nav rail   ├────────────────────────────────────────────────────────────┤
│  232px      │                                                            │
│  (60px      │  Content: max width = App.Width − rail − 48                │
│   below     │                                                            │
│   900px)    │                                                            │
│             │                                                            │
│  ─────────  │                                                            │
│  User+role  │                                                            │
└─────────────┴────────────────────────────────────────────────────────────┘
```

- **Rail**: 12 sections, data-driven (adding one is a row in a table), active item marked
  by a 3px accent bar and a lighter background, count badges on Export LCs, Discrepancies
  and Tasks. Collapses to icons under 900px.
- **Top bar**: page title, breadcrumb showing the full path, global search, and at most
  one primary action. More than one primary action per screen means the screen has no
  primary purpose.
- **Content**: 4px spacing scale, 6px radius, one surface colour, one border colour.

## Screens

| Screen | Purpose |
|---|---|
| `scrDashboard` | 16 drill-through KPI tiles, "needs attention" list, recent activity from the audit trail |
| `scrLCRegister` | The LC register: 8 preset chips, 6 filters, sortable columns, paging |
| `scrLCWorkspace` | The LC workspace: header, lifecycle rail, 12 tabs |
| `scrLCForm` | Register/edit an LC — validation, transition gate, audit, checklist materialisation |
| `scrAmendments`, `scrInvoices`, `scrShipments`, `scrPresentations`, `scrDiscrepancies`, `scrProceeds`, `scrCorrespondence`, `scrTasks` | Module registers, each with its own presets and columns |
| `scrDocuments` | Document Centre across the four libraries, filtered by type |
| `scrDocumentUpload` | Attach a file to a record — LC and type required before the picker enables |
| `scr*Form` (8) | Record forms with per-entity validation and audit |
| `scrReports` | 12 reports, CSV export |
| `scrAdmin` | 16 master/config editors plus the audit viewer |
| `scrImport` | The four-step import pipeline |
| `scrSearch` | Global search across six entities |

## Components

| Component | Why it exists |
|---|---|
| `cmpNavRail` | The rail, identical on all 26 screens |
| `cmpTopBar` | Title, breadcrumb, search, primary action |
| `cmpKPICard` | Dashboard tile. Always clickable, always drills somewhere |
| `cmpStatusBadge` | Every status pill in the portal. Colour comes from `16_StatusMaster`, so a new status needs no code |
| `cmpStageTracker` | The nine-stage lifecycle rail |
| `cmpAlertBanner` | Workspace warnings |
| `cmpSectionCard` | The panel every content block sits in |
| `cmpEmptyState` | What a filtered gallery shows when it returns nothing, with a way out |
| `cmpFieldRow` | Label/value pair. The LC Details tab is 60 of these instead of 120 hand-placed controls |

## The LC workspace in detail

**Header (188px, does not scroll).** Customer name as the headline; LC number in the top
bar; internal ID, our reference and country on one line; issuing and advising bank on the
next. Then five facts in a fixed order — LC amount, utilised, outstanding, latest shipment
date, expiry — each with a caption, a value and a one-line context ("62% drawn", "in 12
days"). Status badge top right.

The order is deliberate: money, then deadlines. Those are the two things that decide what
an officer does next.

**Lifecycle rail.** Received → Reviewed → Active → Shipment → Presentation → Examination →
Acceptance → Payment → Closed. Reached stages solid, current stage ringed, future stages
hollow. Greyed entirely when the LC is cancelled or expired, because a cancelled credit
has no meaningful progress.

**Warnings.** Generated from the record, never static:

- LC expires in N days / expired N days ago
- Shipment deadline in N days / passed N days ago
- N required documents missing → opens the checklist
- N discrepancies open → opens the tab
- Proceeds outstanding
- An amendment is accepted but not yet applied

A rule that finds nothing produces no banner. A workspace with six permanent warnings
teaches people to ignore warnings.

**Tabs.** Overview, LC Details, Amendments, Invoices, Shipments, Documents, Presentations,
Discrepancies, Proceeds, Correspondence, Tasks, Audit. Counts on the tab labels come from
stored counters on the LC record, not from counting child rows — a tab strip that fires
eleven queries on every visit is how a workspace ends up taking four seconds to open.

## Responsive behaviour

Desktop is the operational environment. Below 1280px the register drops its advanced
filter row and the workspace goes to one column. Below 900px the rail collapses to icons,
the KPI grid goes to two columns and forms go single-column.

The screens that must work on a phone — dashboard, search, LC details, tasks, approvals,
documents, notifications — all do. Bulk editing and the import pipeline are desktop-only
by design; nobody reconciles a 500-row import on a phone.

## Accessibility

- Every interactive control has an `AccessibleLabel` and a tab index.
- Status is never conveyed by colour alone — every badge carries its text, every flagged
  row carries a text reason.
- Text colours meet 4.5:1 against their backgrounds; the muted grey is reserved for
  supporting text at 11.5px and above.
- Clickable cards are real buttons, so keyboard focus and hover states come for free.
