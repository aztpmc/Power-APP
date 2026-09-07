# Workflow rules and business logic

## Lifecycle

```
Draft → Received → Under Review → Active → Shipment Pending → Presented
      → Under Examination → Clean | Discrepancy → Accepted
      → Partially Drawn | Fully Drawn → Paid → Closed
```

Sixteen LC statuses mapped onto nine lifecycle stages, all defined in `16_StatusMaster`
along with the legal transitions out of each. 83 status rows across 9 entities; no
dangling transitions (verified — every value in `AllowedNextStatuses` exists as a status
of the same entity).

Terminal states (`Closed`, `Cancelled`) have an empty `AllowedNextStatuses`, so nothing
can move out of them.

## Validation rules

Enforced in the app before save, in the importer before staging, and — for the ones that
can be — by SharePoint required-column settings.

### LC (`scrLCForm`)

| Rule | Configurable |
|---|---|
| LC number, customer, currency, amount, expiry are required | — |
| LC amount cannot be negative | — |
| Expiry cannot precede issuance or receipt | — |
| Latest shipment date cannot be after expiry | `AllowShipmentDateAfterExpiry` |
| Latest shipment date cannot precede issuance | — |
| Tolerance 0–100% | — |
| Presentation period 1–60 days | — |
| Duplicate LC number blocked | `DuplicateLCNumberCheck` |
| Amount cannot be reduced below what is already drawn — record an amendment instead | — |
| Issuing bank required once past Draft | — |
| Goods description required past Draft | `RequireGoodsDescription` |
| Status transition must be legal | `16_StatusMaster` |

### Invoice

Duplicate invoice number within the LC blocked (`DuplicateInvoiceScope`); paid cannot
exceed invoiced; due date cannot precede invoice date; presenting an invoice that would
draw more than the LC maximum is blocked with a prompt to check for a missing amendment
(`AllowNegativeOutstanding`).

### Shipment

Actual shipment date after the LC's latest shipment date is **blocked with an explanation**
— that is an incurable discrepancy, not a warning. Transport document date cannot precede
shipment. A shipment marked shipped needs an actual date. Where the LC says partial
shipment is not allowed, a second shipment is blocked.

### Presentation

Presentation after LC expiry blocked. Amount accepted cannot exceed amount presented.
Payment date cannot precede acceptance. A presentation cannot be marked Clean while it has
open discrepancies. Duplicate presentation number within the LC blocked.

### Discrepancy

Description mandatory. Resolved or closed needs a resolution type and date. Waiver received
requires a waiver request date. "Waived" requires the waiver actually received. Resolution
date cannot precede detection. Only a manager can close one as Rejected — Unresolved.

### Proceeds

Amount accepted required; amounts and charges non-negative; paid cannot exceed accepted;
charges cannot exceed gross proceeds; "Received" needs a payment date; write-off above the
threshold needs a manager.

### Amendment

Amendment number unique within the LC. Must change something. New amount cannot be below
what is already drawn. New latest shipment date cannot be after the expiry the amendment
leaves in force. Amount increases above `AmendmentApprovalThreshold` need a manager.

## Calculations

| Value | Formula | Written by |
|---|---|---|
| `MaximumAmount` | `LCAmount × (1 + TolerancePlus/100)` | app on save |
| `UtilizedAmount` | sum of non-cancelled invoices under the LC | invoice form, `ExportLC-11` |
| `OutstandingAmount` (LC) | `MaximumAmount − UtilizedAmount` | app on save, `ExportLC-11` |
| `OutstandingAmount` (invoice) | `InvoiceAmount − PaidAmount` | invoice form |
| `OutstandingProceeds` | `AmountAccepted − AmountPaid` | proceeds form |
| `GrossProceeds` | `AmountPaid`, or `AmountAccepted` if unpaid | proceeds form |
| `NetProceeds` | gross − (bank + correspondent + discount + other charges) | proceeds form |
| `PresentationDeadline` | earlier of (dispatch date + presentation period) and LC expiry | presentation form |
| `ExaminationDueDate` | bank receipt + `DefaultBankExaminationDays` (UCP 600 art. 14b) | presentation form |
| `MissingDocumentCount` | required checklist lines not received | workspace, upload flow |
| `OpenDiscrepancyCount` | open discrepancies on the LC | discrepancy form, `ExportLC-11` |
| `AmountUSD` | `LCAmount × RateToUSD` from `14_Currencies` | app on save |

## Document checklist

`19_DocChecklistTemplates` holds rules matched on any combination of country, LC type,
customer code and Incoterm. `Specificity` counts the non-blank criteria; the most specific
matching set wins.

Seeded with a base set (invoice, packing list, B/L, certificate of origin, beneficiary
certificate, cover letter, certificate of analysis), plus insurance for CIF/CIP, plus
country rules drawn from this portfolio's actual destinations — Libya (legalised invoice
and certificate of origin, health certificate, free sale certificate), Iraq (certificate of
analysis, GMP, inspection), Ethiopia, Morocco and Oman.

When an LC is registered the matching rules are materialised into
`20_LCDocumentChecklist`, editable per LC without touching the template.

## Notification rules

| Rule | Config key | Default |
|---|---|---|
| LC expiry | `LCExpiryReminderDays` | 30;14;7;3;1 |
| Shipment deadline | `ShipmentDeadlineReminderDays` | 21;14;7;3;1 |
| Presentation deadline | `PresentationDeadlineReminderDays` | 10;5;2;1 |
| Proceeds maturity | `ProceedsMaturityReminderDays` | 14;7;1 |
| Task due | `TaskDueReminderDays` | 3;1;0 |
| Missing documents | `MissingDocumentReminderDays` | every 7 days |
| Amendment pending | `AmendmentActionReminderDays` | every 3 days |
| Discrepancy escalation | category `EscalateAfterDays`, then `DiscrepancyEscalationDays` | 5, then 10 to the treasury manager |
| Overdue task escalation | `OverdueTaskEscalationDays` | 3 |
| Weekend suppression | `NotificationSuppressWeekends` | true |
| Daily digest | `NotificationDigestEnabled`, `NotificationDigestHourUTC` | true, 05:00 UTC |

Every reminder is idempotent through `26_NotificationLog`, keyed
`RuleCode:RecordReference:Offset`. Without that, a 30-day warning would re-send daily for
thirty days.

## Trade finance behaviour the system encodes

- **An amendment never overwrites the LC.** It is recorded with before/after values, then
  explicitly applied — and only when accepted. Until applied, the register is showing
  pre-amendment terms, which is why `ExportLC-04` chases it and the workspace warns.
- **Late shipment and late presentation are not curable.** The app blocks them at entry
  rather than accepting them and generating a discrepancy later.
- **Discrepancies have categories with their own severity and escalation windows.** A late
  presentation escalates in two days; a typo in five.
- **A presentation cannot be Clean with open discrepancies.**
- **Payment is not settlement.** `AmountAccepted`, `AmountPaid`, charges and `NetProceeds`
  are tracked separately, because a deferred-payment credit accepted today pays in 180 days
  and the exposure exists throughout.
- **Tolerance is real.** Drawings are checked against `MaximumAmount`, not `LCAmount`.
