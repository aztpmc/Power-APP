# Security and roles

## Two layers, and why both are needed

**SharePoint groups are the boundary.** They control what a user can reach through any
client at all — the app, the browser, Excel, the mobile app, the REST API, a Power Automate
flow they build themselves. Anything enforced only in the app is enforced only for people
who use the app.

**`17_Users` is the experience.** It controls what the portal offers: which buttons appear,
which screens open, whether Save is enabled, who an approval routes to.

Both are applied. `Set-Permissions.ps1` does the first; the role formulas in `App.fx.yaml`
do the second.

## Roles

| Role | SharePoint group | Site permission | Can |
|---|---|---|---|
| `ADMIN` | Export LC Administrators | Full Control | Everything, including master data, configuration, import commit and audit archival |
| `MANAGER` | Export LC Managers | Edit | All operational work, plus approvals, LC closure, proceeds write-off, all reports |
| `OFFICER` | Export LC Officers | LC Contribute No Delete | Create and maintain operational records. Cannot delete anything or edit master data |
| `REVIEWER` | Export LC Reviewers | LC Contribute No Delete | Review documents, record examination outcomes and discrepancies |
| `READONLY` | Export LC Readers | Read | View and report only |

## Two custom permission levels

**LC Contribute No Delete** — Contribute minus `DeleteListItems` and `DeleteVersions`.

An officer can correct a record but cannot make one disappear. In trade finance the record
of what a credit said last week matters as much as what it says today; deletion is an
administrator action, taken deliberately, not something available on every row.

**LC Append Only** — Contribute minus `DeleteListItems`, `DeleteVersions` and
`EditListItems`.

Applied to `10_AuditLog` and `26_NotificationLog`. Everyone can add rows and read them;
nobody except an administrator can change or remove one. An audit trail the audited party
can edit is not an audit trail — this is the difference between a log and a record.

## Per-list permissions

| Lists | Inheritance | Admin | Everyone else |
|---|---|---|---|
| `01`–`09`, `20` (operational) | Inherited from the site | Full Control | Per group: Edit / Contribute-no-delete / Read |
| `10_AuditLog`, `26_NotificationLog` | Broken | Full Control | LC Append Only (Read for `READONLY`) |
| `11`–`19`, `21`–`25`, `27`, `28` (master, config, staging) | Broken | Full Control | Read |

Master data and configuration are readable by everyone — the app needs them to render
every dropdown and badge — and writable only by administrators. That is what makes
"nothing important is hard-coded" safe rather than dangerous: the values are configurable,
but not by everybody.

## Role formulas in the app

```
IsAdmin      = gblRole = "ADMIN";
IsManager    = gblRole in ["ADMIN", "MANAGER"];
IsOfficer    = gblRole in ["ADMIN", "MANAGER", "OFFICER"];
IsReviewer   = gblRole in ["ADMIN", "MANAGER", "OFFICER", "REVIEWER"];

CanCreateLC       = IsOfficer;
CanApprove        = IsManager;
CanEditMasterData = IsAdmin;
CanCommitImport   = If(CfgB("ImportRequireAdminCommit", true), IsAdmin, IsManager);
CanCloseLC        = If(CfgB("LCClosureRequiresApproval", true), IsManager, IsOfficer);
```

A user with no row in `17_Users` gets `READONLY` rather than an error or a blank screen.
Failing closed is the right default, and failing *visibly* closed is better than failing
with a stack trace.

## Optional customer scoping

`17_Users.CustomerScope` takes a semicolon-separated list of customer codes. Empty means
the whole book. Where set, the app adds it as an extra filter — useful where officers own
a portfolio.

**This is a UI convenience, not a security control.** SharePoint item-level permissions
would be needed to make it a boundary, and per-item permissions at 5,000+ items cause well
documented performance problems. If customer-level confidentiality is a real requirement,
that is a reason to move to Dataverse, which has row-level security designed for it. It is
recorded as a limitation rather than presented as protection.

## Approvals

`ExportLC-09-ApprovalRequest` picks the approver by amount: the smallest `ApprovalLimit` in
`17_Users` among active managers that still covers the request, falling back to
`EscalationManagerEmail`. A routine request does not go straight to the top, and no
approver is hard-coded.

Approval-requiring actions are configuration, not code:

| Action | Config key | Default |
|---|---|---|
| Close or cancel an LC | `LCClosureRequiresApproval` | true |
| Amendment increasing the amount | `AmendmentApprovalThreshold` | 100,000 |
| Write off outstanding proceeds | `DiscrepancyWriteOffThreshold` | 10,000 |
| Any status marked `RequiresApproval` in `16_StatusMaster` | per-status | see the list |

Every decision is written to `10_AuditLog` as `Approval Decision`, with the approver, the
outcome and their comment.

## Sharing the app

Share the canvas app with the same five SharePoint groups, as **User** (not Co-owner) for
everyone except administrators. Power Apps sharing controls who can open the app; the
SharePoint groups control what they see once inside.

## Audit coverage

Every write from the app and from every flow lands in `10_AuditLog` with: entity, record
id and reference, internal LC ID, LC number, action type, field name, old value, new value,
critical-field flag, who, when, source (Power App / Power Automate / Excel Import /
Migration / Admin Script), a free-text comment, a correlation id, and a `yyyy-mm` partition
key.

Critical fields are configurable in `18_WorkflowConfig` under `CriticalAuditFields`, seeded
with amounts, dates, currency, status, customer, issuing bank, beneficiary, payment terms
and settlement figures.

## What is not covered

- **SharePoint's own version history** is enabled on every list (100–500 versions) and is a
  second, independent record. It survives even if a flow fails to write an audit row.
- **Data loss prevention policies** are a tenant concern and are not configured here.
- **Sensitivity labels** on the document libraries are not applied; if the tenant uses
  them, apply them to the four libraries before go-live.
- **The `IsSanctioned` flag on `13_Countries`** raises an advisory banner. It is not
  compliance screening and must not be relied on as such.
