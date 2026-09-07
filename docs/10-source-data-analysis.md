# Source data analysis

What the two legacy workbooks in `legacy/` actually contain, what the extractor found, and
what needs a decision before migration. Produced by running
`python3 migration/extract_legacy.py` against the real files — none of this is assumed.

## The workbooks

**`LC Master Export 2026.xlsx`** — 11 sheets. `LC Tracker` is the operational register: 20
LCs across 101 columns, of which columns 15 onward are **twelve repeating seven-column
invoice blocks** (`Inv Number`, `Value`, `Pres. Date`, `Status`, `Coll. Date`, `Due Date`,
`Tracking #`). That layout caps an LC at twelve invoices, makes "show me every overdue
invoice" impossible without reading all 101 columns of every row, and is the single
strongest argument for this rebuild.

Also holds `Cust Data` (130 customers), `Banks Data`, `Payment Term`, a `Summary` sheet, a
`Certificate of Analysis` template, three `cover Letter print` sheets, and a hidden
`Invoice Detail` sheet.

**`LC Export.xlsx`** — 6 sheets. `LC Export Breakdown` is a card-per-LC layout with
exposure pivots by customer and country. `Invoice Process Tracker` is a flat register of
60 invoices with status, collection dates and next actions — **richer than the LC Tracker's
invoice blocks**, and keyed on our reference rather than the LC number.

## What was extracted

| Output | Rows |
|---|---:|
| Export LCs | 20 |
| Invoices (both sources merged) | 60 |
| Customers | 127 |
| Banks | 28 |
| Countries | 24 |
| Payment terms | 6 |

Total LC value **10,931,242.80**. Invoice value **11,219,391.75**, of which **8,546,154.14** matches an extracted LC.

## Findings

| Severity | Count |
|---|---:|
| INFO | 3 |
| REJECT | 4 |
| WARNING | 19 |

| Rule | Count |
|---|---:|
| ORPHAN_INVOICE | 12 |
| DUP_CODE_CONFLICT | 4 |
| INVOICE_AMOUNT_REQUIRED | 4 |
| MERGE | 2 |
| ISSUING_BANK_MISSING | 1 |
| SKIP_TOTAL_ROW | 1 |
| AMOUNT_CONFLICT | 1 |
| OVERDRAWN | 1 |

## The four that block migration

All four are the same problem: an invoice number recorded with **no value at all**.

| Source row | LC | Invoice |
|---|---|---|
| 13 | `26/BMLCU/41157` | 91205473 |
| 14 | `26/BMLCU/41321` | 91213468 |
| 15 | `26/BMLCU/41031` | 91202373 |
| 15 | `26/BMLCU/41031` | 91202528 |

Verified against the raw cells: the invoice number is present and every other field in the
block is empty. Someone recorded the number intending to fill in the rest.

**Decision needed:** supply the values, or drop these four invoices. The importer will not
commit them either way.

## The twelve orphan invoices

Twelve invoices in `Invoice Process Tracker`, worth **2,673,237.61**, reference six LCs that do not
exist in `LC Tracker`:

- `AB1000ILC0193026`
- `ELC/2026/00832QA`
- `ELCCB26001530POD001`
- `EXWC021649`
- `EXWC021916-ADV001`
- `LCI202600286`

**This is the finding that matters most.** Either the LC Tracker is behind — LCs advised
and drawn but never registered in the master sheet — or these credits are being tracked
somewhere else entirely. Both mean the register a treasury officer looks at today is not
the whole book.

**Decision needed:** register these six LCs before migrating, so their invoices can be
linked.

## The amount conflict

Invoice `91226392` is **341,377.25** in the LC Tracker and **308,687.25** in the Invoice
Process Tracker — a difference of 32,690.00. Two spreadsheets, two answers, no way to tell
which is right from the files alone. The extractor keeps the LC Tracker value and flags it.

**Decision needed:** confirm the correct figure against the actual invoice.

## The overdrawn LC

`OLCD001260151` (Al Hikma Fzco Iraq): invoices total **799,388.43** against an LC of
**770,487.61** — over by **28,900.82**.

That is either an unrecorded amendment increasing the credit, a drawing genuinely outside
the tolerance, or the amount conflict above feeding through. In the new system this cannot
happen silently: `scrInvoiceForm` blocks a drawing that exceeds `MaximumAmount` and says to
check for a missing amendment.

## The four customer code conflicts

Four customers appear twice with different codes:

| Customer | Codes |
|---|---|
| Elkendi Pharmaceutical Mfg Co. | 2000024, 3555558 |
| Sas Company | 2000036, 3555559 |
| Injaz Scientific Bureau | 2001349, 3000170 |
| Munir Sukhtian Co. Ltd | 3555557, 2000007 |

The extractor keeps the first and flags the conflict. Note the `35555xx` codes look like a
different numbering scheme — possibly a second ERP or a legacy range.

**Decision needed:** which code is current for each.

## Other data quality notes

- **The `Summary` sheet is broken.** Row 12 is `#REF!` across every column, and its stated
  LC count (14) disagrees with the 20 rows actually in `LC Tracker`. Do not reconcile
  against it — reconcile against the tracker rows. This is exactly what a formula-linked
  workbook does to itself over time.
- **`Kare` vs `Kare Pharmaceutical Plc`** — the same customer under two names across
  sheets. The extractor normalises names for duplicate detection (upper-cased,
  punctuation stripped, legal suffixes removed) which is how it caught this.
- **One LC has no issuing bank**: `AWAELCU260068` (Unicare Medical). Advising bank ENBD is
  recorded, issuing bank blank.
- **Country names carry trailing spaces** (`"Oman "`, `"Iraq "`) inconsistently. Normalised
  on extraction.
- **Two reference systems throughout.** `Advising Bank #` is our own reference
  (`2026/ILC/3378`); `Issuing Bank #2` is the bank's LC number (`26/BMLCU/40464`). The cover
  letters print both, as `LC No.` and `Our Ref.`. The new model keeps both:
  `LCNumber` and `OurReference`, both indexed, both searchable.
- **Only one currency in use** (USD) across all 20 LCs, but the model supports mixed
  currencies with FX normalisation for exposure reporting.
- **All 20 LCs are deferred payment** except one at sight — consistent with `180 Days From
  TCN` and `180 Days From Shipment` terms. `MaturityBasis` on `25_PaymentTerms` captures
  the distinction so due dates become calculable rather than typed.

## Exposure by customer, as extracted

| Customer | LCs | LC value | Outstanding |
|---|---:|---:|---:|
| Al Hashar Pharmacy Llc | 9 | 3,495,538.02 | 2,147,545.26 |
| Zenith Pharma | 1 | 2,881,945.35 | 3.16 |
| Al Hikma Fzco Iraq | 3 | 2,268,644.79 | 17,958.78 |
| Samt For Medical Supplies | 2 | 953,947.15 | 0.13 |
| Tracon Trading Plc | 1 | 563,636.54 | 123,035.97 |
| Kare Pharmaceutical Plc | 1 | 475,381.73 | -0.01 |
| El Hakeem For Importing Pharmaceutical | 1 | 148,875.10 | 0.25 |
| Unicare Medical | 1 | 90,596.00 | 90,596.00 |
| Lanamed Pharmaceuticals Import | 1 | 52,678.12 | 5,949.12 |

## Recommended sequence

1. Resolve the four missing invoice values.
2. Register the six missing LCs, then re-run the extractor so their twelve invoices link.
3. Confirm invoice `91226392`.
4. Decide the four customer codes.
5. Investigate the overdrawn LC — most likely a missing amendment.
6. Re-run the extractor. Aim for zero rejects.
7. Import through the portal, review the preview, commit.
8. Reconcile committed totals against `migration/out/summary.md`.
