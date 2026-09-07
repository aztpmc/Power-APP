# Data model

29 lists, 5 document libraries, 550 columns. Everything below is generated from
`sharepoint/schema/site-schema.json`, which the provisioning script reads directly — the
schema file and the deployed site cannot drift apart.


## Relationships

```
11_Customers ──┐
               │  CustomerCode / CustomerName (denormalised text, indexed)
               ▼
        01_ExportLCs ◄──── 12_Banks (IssuingBankName, AdvisingBankName)
               │  ◄──── 23_LCTypes, 25_PaymentTerms, 21_Incoterms, 13_Countries, 14_Currencies
               │
               │  every child carries LCItemId (indexed), LCNumber, InternalLCID
               ├──► 02_LCAmendments        (amendment history; never overwrites the LC)
               ├──► 03_Invoices ───────────► 04_Shipments (InvoiceNumber)
               ├──► 04_Shipments
               ├──► 05_Presentations ──┬──► 06_Discrepancies (PresentationId)
               │                       └──► 07_Proceeds      (PresentationId)
               ├──► 08_Correspondence  (LinkedEntity + LinkedEntityId: polymorphic)
               ├──► 09_Tasks           (RelatedEntity + RelatedEntityId: polymorphic)
               ├──► 20_LCDocumentChecklist ◄── materialised from 19_DocChecklistTemplates
               └──► ExportLCDocuments / ExportLCInvoices /
                    ExportLCShippingDocuments / ExportLCBankCorrespondence

        10_AuditLog     ◄── every write from the app and from flows (append only)
        26_NotificationLog ◄── every reminder, before it is sent (idempotency)
        29_DashboardMetrics ◄── recomputed by ExportLC-11
```


### Why there are no SharePoint lookup columns

A SharePoint lookup column cannot be filtered delegably from Power Apps. `Filter(list,
Customer.Value = "X")` runs client-side against the first 500 or 2,000 rows and then
stops — without an error, and without a visibly wrong result until the register grows.

So relationships are carried as **indexed plain columns**: `LCItemId` (number) for the
join, plus `LCNumber` and `CustomerName` (text) for filtering and display. Referential
integrity is enforced in the app — a child record cannot be saved without a parent LC
selected — and by `ExportLC-11`, which recomputes the parent counters.

This is the standard SharePoint-at-scale trade: correctness of the write path in exchange
for delegability of the read path. On Dataverse none of it would be necessary.

### Why derived amounts are stored, not calculated

SharePoint calculated columns cannot be indexed and cannot reference another list.
`OutstandingAmount = MaximumAmount − UtilizedAmount` as a calculated column could not be
sorted on, filtered on server-side, or used in a view — which are exactly the three things
the register needs it for.

So it is a stored `Currency` column, written by `scrLCForm` and `scrInvoiceForm` on save
and re-derived hourly by `ExportLC-11`.


## Lists

| List | Entity | Columns | Indexed | Purpose |
|---|---|---:|---:|---|
| `01_ExportLCs` | ExportLCs | 77 | 20 | Master register of Export Letters of Credit. |
| `02_LCAmendments` | LCAmendments | 27 | 10 | Immutable amendment history. |
| `03_Invoices` | Invoices | 25 | 16 | Commercial invoices drawn under an LC. |
| `04_Shipments` | Shipments | 24 | 11 | Shipments made under an LC. |
| `05_Presentations` | Presentations | 30 | 16 | Document presentations made to the bank under an LC. |
| `06_Discrepancies` | Discrepancies | 32 | 16 | Individual discrepancies raised by the examining bank against a presentation. |
| `07_Proceeds` | Proceeds | 28 | 17 | Settlement and proceeds received against presentations. |
| `08_Correspondence` | Correspondence | 22 | 15 | Bank correspondence log. |
| `09_Tasks` | LCTasks | 23 | 15 | Operational task centre. |
| `10_AuditLog` | AuditLog | 17 | 13 | Append-only audit trail. |
| `11_Customers` | Customers | 15 | 4 | Customer master. |
| `12_Banks` | Banks | 16 | 7 | Bank master. |
| `13_Countries` | Countries | 7 | 5 | Country master with trade-risk attributes used by the exposure-by-country report. |
| `14_Currencies` | Currencies | 7 | 1 | Currency master with the reporting FX rate used to normalise mixed-currency exposure to USD. |
| `15_DocumentTypes` | DocumentTypes | 9 | 3 | Document type master. |
| `16_StatusMaster` | StatusMaster | 14 | 4 | Status master AND workflow transition table. |
| `17_Users` | UserRoles | 10 | 4 | Application role assignment. |
| `18_WorkflowConfig` | WorkflowConfig | 7 | 2 | Central configuration store. |
| `19_DocChecklistTemplates` | DocChecklistTemplates | 14 | 7 | ADDED to the requested architecture. |
| `20_LCDocumentChecklist` | LCDocumentChecklist | 21 | 9 | ADDED. |
| `21_Incoterms` | Incoterms | 6 | 1 | ADDED. |
| `22_Ports` | Ports | 5 | 4 | ADDED. |
| `23_LCTypes` | LCTypes | 8 | 2 | ADDED. |
| `24_DiscrepancyCategories` | DiscrepancyCategories | 9 | 3 | ADDED. |
| `25_PaymentTerms` | PaymentTerms | 6 | 3 | ADDED. |
| `26_NotificationLog` | NotificationLog | 10 | 7 | ADDED. |
| `27_ImportBatches` | ImportBatches | 14 | 4 | ADDED. |
| `28_ImportStaging` | ImportStaging | 11 | 5 | ADDED. |
| `29_DashboardMetrics` | DashboardMetrics | 12 | 3 | ADDED. |

## Document libraries

| Library | Columns | Indexed | Purpose |
|---|---:|---:|---|
| `ExportLCDocuments` | 16 | 6 | Master LC documents: original LC advice, amendments, bank instruments, presentation cover letters, payment advices. |
| `ExportLCInvoices` | 7 | 5 | Commercial invoices, packing lists and invoice-level supporting documents. |
| `ExportLCShippingDocuments` | 9 | 6 | Transport and shipment documents: B/L, AWB, certificates of origin, insurance, inspection, beneficiary certificates. |
| `ExportLCBankCorrespondence` | 9 | 5 | Incoming and outgoing bank correspondence: SWIFT copies, discrepancy notices, waiver requests, acceptance advices, payment advices. |
| `ExportLCTemplates` | 3 | 1 | Not in the original brief - added. |

## Naming: why the display titles keep the `NN_` prefix but the URLs do not

The brief asks for `01_ExportLCs`, `02_LCAmendments` and so on. Numbered prefixes are
genuinely useful in the site contents list — they keep related lists together and make the
lifecycle order obvious to someone browsing SharePoint directly.

They are less useful in URLs and in code, where `Lists/01_ExportLCs` reads badly and,
worse, breaks every reference if anyone ever renumbers.

So each list is created with the requested **title** and a clean **URL**:
`Lists/ExportLCs`, `Lists/LCAmendments`. Power Apps and the flows bind to the title, which
is stable; the URL stays readable for REST and for anyone linking to a view.

## Changes made to the architecture in the brief

The brief listed 18 lists and invited a better design with an explanation. Eleven lists
were added. Every one exists because a requirement elsewhere in the brief had nowhere to
live:

| Added | Because |
|---|---|
| `19_DocChecklistTemplates` | Requirement 14 says the document checklist must be configurable and not hard-coded. A configurable checklist needs a rule layer: which documents are required for which country, LC type, customer and Incoterm. |
| `20_LCDocumentChecklist` | The per-LC instance of those rules, editable per LC without touching the template, and the source of `MissingDocumentCount`. |
| `21_Incoterms`, `22_Ports`, `23_LCTypes`, `24_DiscrepancyCategories`, `25_PaymentTerms` | Requirement 20 lists all five as admin-managed master data; requirement 28 forbids hard-coding them. The original 18 lists had no home for any of them. |
| `26_NotificationLog` | Without it, the 30/14/7-day reminders re-fire every day. This list is the only thing making the flows idempotent. |
| `27_ImportBatches`, `28_ImportStaging` | Requirement 29 asks for preview, an error report, and a record of what succeeded and what failed. That needs staging separate from the live lists. |
| `29_DashboardMetrics` | `CountRows()` is not delegable. Without pre-aggregation the dashboard silently under-reports above the row limit — the exact failure requirement 30 is trying to prevent. |

Two lists were reinterpreted rather than added:

- **`17_Users`** is an application-role list, not a user directory. Microsoft 365 already
  holds the users; duplicating them would create a second source of truth that goes stale.
  What this list holds is the portal role, the manager for escalation, an approval limit
  and an optional customer scope.
- **`12_Banks`** merges the four disconnected columns in the legacy `Banks Data` sheet
  (`SA Banks`, `Global Banks`, and two unlabelled lists headed `our` and `there`) into one
  list with `CanAdvise` / `CanIssue` / `CanConfirm` / `CanReimburse` role flags. The legacy
  layout could not express that one bank both advises and issues.

One library was added: **`ExportLCTemplates`**, holding the Excel import template and the
presentation cover-letter and certificate templates found in the legacy workbook. Those
are operational output; version-controlling them beats leaving them on desktops.

## Indexing budget

SharePoint permits 20 indexed columns per list. `01_ExportLCs` uses all 20. Adding another
index there requires removing one; the schema file records which columns were deliberately
left unindexed and why.

The single most valuable index in the solution is `IsClosed` on `01_ExportLCs`. Every
register query, every dashboard tile and every report filters on it first, and it is the
most selective predicate available on a book where most historical LCs are closed.

