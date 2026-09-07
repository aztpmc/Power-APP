# Legacy extraction summary

Generated 2026-09-07 14:03 from: LC Export.xlsx, LC Master Export 2026.xlsx

## Records extracted

| Output | Rows |
|---|---:|
| lcs | 20 |
| invoices | 60 |
| customers | 127 |
| banks | 28 |
| countries | 24 |
| currencies | 14 |
| paymentterms | 6 |

## Validation findings

| Severity | Count |
|---|---:|
| REJECT | 4 |
| WARNING | 19 |
| INFO | 3 |

4 record(s) carry at least one REJECT and will not be committed until corrected.

## Reconciliation

- LCs extracted: **20**, total LC value **10,931,242.80**
- Invoices extracted: **60**, total value **11,219,391.75**
- Invoices matched to an LC: **48**, value **8,546,154.14**
- Utilisation against extracted LCs: **2,385,088.66** outstanding
- Orphan invoices (no matching LC): **12**, value **2,673,237.61**

The orphan invoices reference these LCs, which appear in the Invoice Process Tracker but not in the LC Tracker sheet. Either the LC Tracker is behind, or these LCs were registered somewhere else. They must be registered in the portal before their invoices can be committed:

- `AB1000ILC0193026`
- `ELC/2026/00832QA`
- `ELCCB26001530POD001`
- `EXWC021649`
- `EXWC021916-ADV001`
- `LCI202600286`

Do not reconcile against the legacy Summary sheet: it contains `#REF!` errors and its own stated LC count (14) disagrees with the 20 rows actually present in the LC Tracker. Reconcile against the LC Tracker rows instead.

## Exposure by customer

| Customer | LCs | LC Value | Outstanding |
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

## Top validation rules triggered

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
