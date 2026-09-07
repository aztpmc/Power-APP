# Power Automate flows

Fourteen flows. Four are called by the app; ten run on a schedule.

| Flow | Trigger | What it does |
|---|---|---|
| `ExportLC-01-LCExpiryReminder` | Daily 07:00 | Warns before an LC expires, at the offsets in `LCExpiryReminderDays`. |
| `ExportLC-02-ShipmentDeadlineReminder` | Daily 07:00 | Warns before the latest shipment date. |
| `ExportLC-03-MissingDocuments` | Daily 08:00 | Chases required documents still missing on an active LC. |
| `ExportLC-04-AmendmentAction` | Daily 08:00 | Chases amendments awaiting acceptance or not yet applied. |
| `ExportLC-05-PresentationDeadlineReminder` | Daily 07:00 | Warns before the presentation deadline. |
| `ExportLC-06-DiscrepancyEscalation` | Daily 08:00 | Escalates unresolved discrepancies to manager, then treasury manager. |
| `ExportLC-07-ProceedsMaturityReminder` | Daily 07:00 | Warns before proceeds mature. |
| `ExportLC-08-TaskReminders` | Daily 07:00 | Task reminders, plus the overdue sweep for invoices and proceeds. |
| `ExportLC-09-ApprovalRequest` | Called by the app | Routes an approval by amount and records the decision. |
| `ExportLC-10-DailyDigest` | Daily 08:30 | One summary email per officer. |
| `ExportLC-11-RecomputeDashboardMetrics` | Hourly + app | Recomputes every dashboard KPI server-side. |
| `ExportLC-12-ImportValidate` | Called by the app | Parses and validates an uploaded workbook into staging. |
| `ExportLC-13-ImportCommit` | Called by the app | Commits only the valid staged rows. |
| `ExportLC-14-UploadDocument` | Called by the app | Writes a file and its metadata together. |

## Three design decisions worth knowing about

**Every reminder is idempotent.** Before sending anything, a flow builds a key of
`RuleCode:RecordReference:Offset` and checks `26_NotificationLog` for it. Without this,
a "30 days to expiry" warning would re-send every day for thirty days. Reminders that
arrive daily stop being read, and a notification nobody reads is worse than none.

**Nothing is hard-coded.** Offsets, escalation windows, approval thresholds, the
weekend rule and the escalation mailbox all come from `18_WorkflowConfig`. Changing when
alerts fire is a list edit.

**The dashboard does not count rows in the app.** `CountRows()` is not delegable against
SharePoint, so at 5,000+ LCs an in-app count would silently cap at the row limit and be
wrong without saying so. `ExportLC-11` computes every figure server-side into
`29_DashboardMetrics`, and the dashboard reads those rows.

## Deploying

```powershell
.\Build-FlowPackages.ps1 -SiteUrl https://contoso.sharepoint.com/sites/ExportLCPortal
```

Then for each zip: **make.powerautomate.com → My flows → Import → Import Package
(Legacy)**, map the connections to existing ones, import, and turn the flow on.

Import `ExportLC-12-ImportValidate` before `ExportLC-13-ImportCommit`; order does not
matter for the rest.

## Connections needed

| Connection | Used by |
|---|---|
| SharePoint | all fourteen |
| Office 365 Outlook | 01-08, 10 |
| Approvals | 09 |
| Excel Online (Business) | 12 |

## Before turning anything on

1. Set `SiteUrl` on each flow (the build script stamps it, but check after import).
2. Set `EscalationManagerEmail` and `PortalSupportEmail` in `18_WorkflowConfig` — several
   flows fall back to the escalation mailbox when a record has no responsible officer,
   and with it blank they log the notification as `Suppressed` instead of sending it.
3. Run `ExportLC-11` manually once so the dashboard has figures.
4. Test each reminder flow twice in a row. The second run should send nothing — that is
   the idempotency check working.

## Known limits

- `GetItems` pagination is set to 5,000 per query. Beyond that, split a flow by
  responsible officer or add a second page.
- Date windows are whole UTC days. Set each trigger's time zone to match operating hours
  so a reminder does not land a day early at the edges.
- `ExportLC-12` requires the workbook to contain a named table `LCImport`. The supplied
  import template has one; an arbitrary legacy tracker needs one added first.
- The Approvals connector needs each approver to have a Power Automate licence that
  covers approvals; where that is not available, replace the approval action in
  `ExportLC-09` with an email and a manual status change.
