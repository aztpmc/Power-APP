# ExportLC-05-PresentationDeadlineReminder

The presentation deadline is the earlier of transport document date plus the presentation period and LC expiry. Missing it turns a clean set of documents into a discrepant one.

## Trigger
Daily at 07:00 Arabian Standard Time. Change the schedule on the trigger, not in code.

## Configuration it reads
| Key in 18_WorkflowConfig | Effect |
|---|---|
| `PresentationDeadlineReminderDays` | Semicolon-separated day offsets, e.g. `30;14;7;3;1`. |
| `NotificationSuppressWeekends` | When true the flow exits on Saturday and Sunday. |
| `EscalationManagerEmail` | Recipient when the record has no responsible officer. |

## What it does
1. Reads the offsets from configuration (falls back to `30;14;7` if the row is missing).
2. For each offset, queries `05_Presentations` for records whose `PresentationDeadline` is exactly that many days away.
3. Builds an idempotency key `ExportLC-05-PresentationDeadlineReminder:<record>:<offset>`.
4. Checks `26_NotificationLog` for that key and does nothing if it is already there.
5. Otherwise sends the email, raises a task in `09_Tasks`, and writes the log row.

## Why the notification log matters
Without step 4 this flow would re-send the same 30-day warning every single day for
the whole month. Users stop reading reminders that arrive daily, and once they stop
reading them the flow is worse than nothing. The log row is written last, so a failure
mid-send retries next run rather than silently swallowing the reminder.

## How to verify after deployment
1. Set `SiteUrl` on the flow's parameters to the portal site.
2. Put a test LC's `PresentationDeadline` exactly N days out, where N is one of the configured offsets.
3. Run the flow manually. Expect one email, one task, one row in `26_NotificationLog`.
4. Run it again immediately. Expect no email and no new rows - that is step 4 working.

## Known limits
- The date window is a whole UTC day. A tenant far from UTC may see a reminder land a
  day early or late at the edges; set the trigger time zone to match the operating hours.
- The SharePoint `GetItems` pagination is set to 5,000. Above that, split the flow by
  responsible officer or add a second query page.
