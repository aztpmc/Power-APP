#!/usr/bin/env python3
"""
Export LC Portal - legacy Excel extraction and validation.

Reads the legacy trackers in legacy/ and produces:

  sharepoint/masterdata/*.csv   master data seeds (customers, banks, countries,
                                currencies, payment terms) ready for Import-MasterData.ps1
  migration/out/staging_*.csv   normalised transactional rows for 28_ImportStaging
  migration/out/validation_report.csv   one row per finding, per source row
  migration/out/summary.md      human-readable reconciliation summary

Nothing is written to SharePoint. This step is deliberately offline so the data can be
reviewed and corrected before a single row reaches the live lists.

Pure standard library - no openpyxl, no pandas, no network. Python 3.8+.

Usage:
    python3 migration/extract_legacy.py
    python3 migration/extract_legacy.py --legacy-dir legacy --out-dir migration/out
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import re
import sys
import zipfile
from collections import defaultdict
from xml.etree import ElementTree as ET

MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS = {"m": MAIN_NS, "r": REL_NS}

BUILTIN_DATE_FORMATS = {"14", "15", "16", "17", "18", "19", "20", "21", "22", "45", "46", "47"}


# ---------------------------------------------------------------------------
# Minimal XLSX reader
# ---------------------------------------------------------------------------
def _col_index(ref: str) -> int:
    letters = re.match(r"([A-Z]+)", ref).group(1)
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def read_workbook(path: str) -> "dict[str, dict[int, dict[int, str]]]":
    """Return {sheet_name: {row_number: {col_index: value}}}. Dates come back as ISO strings."""
    zf = zipfile.ZipFile(path)
    names = zf.namelist()

    shared: "list[str]" = []
    if "xl/sharedStrings.xml" in names:
        for si in ET.fromstring(zf.read("xl/sharedStrings.xml")).findall("m:si", NS):
            shared.append("".join(t.text or "" for t in si.iter(f"{{{MAIN_NS}}}t")))

    styles = ET.fromstring(zf.read("xl/styles.xml"))
    num_fmts = {n.get("numFmtId"): (n.get("formatCode") or "") for n in styles.iter(f"{{{MAIN_NS}}}numFmt")}
    cell_xfs = styles.find("m:cellXfs", NS)
    xf_fmt_ids = [x.get("numFmtId") for x in cell_xfs] if cell_xfs is not None else []

    def is_date_style(style_index) -> bool:
        if style_index is None:
            return False
        try:
            fmt_id = xf_fmt_ids[int(style_index)]
        except (ValueError, IndexError):
            return False
        code = num_fmts.get(fmt_id, "")
        if code and re.search(r"(?<!\\)[dmyh]", code):
            return True
        return fmt_id in BUILTIN_DATE_FORMATS

    wb = ET.fromstring(zf.read("xl/workbook.xml"))
    rels = {r.get("Id"): r.get("Target") for r in ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))}

    out = {}
    for sheet in wb.find("m:sheets", NS):
        target = rels[sheet.get(f"{{{REL_NS}}}id")]
        if not target.startswith("xl/"):
            target = "xl/" + target.lstrip("/")
        if target not in names:
            continue
        rows: "dict[int, dict[int, str]]" = {}
        for row in ET.fromstring(zf.read(target)).iter(f"{{{MAIN_NS}}}row"):
            cells: "dict[int, str]" = {}
            for c in row:
                ref, ctype, style = c.get("r"), c.get("t"), c.get("s")
                v_el = c.find("m:v", NS)
                is_el = c.find("m:is", NS)
                if ctype == "inlineStr" and is_el is not None:
                    value = "".join(t.text or "" for t in is_el.iter(f"{{{MAIN_NS}}}t"))
                elif v_el is None:
                    continue
                elif ctype == "s":
                    value = shared[int(v_el.text)]
                elif ctype == "b":
                    value = "TRUE" if v_el.text == "1" else "FALSE"
                elif ctype == "e":
                    value = f"#ERR:{v_el.text}"
                else:
                    value = v_el.text or ""
                    if is_date_style(style) and re.match(r"^-?\d+(\.\d+)?$", value):
                        value = serial_to_iso(float(value)) or value
                if value not in (None, ""):
                    cells[_col_index(ref)] = value
            if cells:
                rows[int(row.get("r"))] = cells
        out[sheet.get("name")] = rows
    return out


def serial_to_iso(serial: float):
    """Excel serial -> ISO date. Values below 1 are times or the 1899 epoch artefact, not dates."""
    if serial < 1:
        return None
    try:
        return (dt.date(1899, 12, 30) + dt.timedelta(days=int(serial))).isoformat()
    except (OverflowError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Normalisation helpers
# ---------------------------------------------------------------------------
DATE_TEXT = re.compile(r"^(\d{1,2})-([A-Za-z]{3})-(\d{4})$")
MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}


def norm_text(value) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value)).strip()


def norm_key(value) -> str:
    """Aggressive normalisation for duplicate detection: upper, no punctuation, no legal suffixes."""
    s = norm_text(value).upper()
    s = re.sub(r"[^A-Z0-9 ]", " ", s)
    s = re.sub(r"\b(LLC|L L C|PLC|LTD|LIMITED|CO|COMPANY|INC|FZCO|FZE|EST|TRADING|GROUP)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def norm_date(value):
    """Accept ISO, dd-Mmm-yyyy, or an Excel serial that slipped through unstyled."""
    s = norm_text(value)
    if not s or s.startswith("#ERR"):
        return ""
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    m = DATE_TEXT.match(s)
    if m:
        day, mon, year = int(m.group(1)), MONTHS.get(m.group(2).lower()), int(m.group(3))
        if mon:
            try:
                return dt.date(year, mon, day).isoformat()
            except ValueError:
                return ""
    if re.match(r"^\d+(\.\d+)?$", s):
        return serial_to_iso(float(s)) or ""
    return ""


def norm_money(value):
    s = norm_text(value).replace(",", "").replace("$", "")
    if not s or s.startswith("#ERR"):
        return None
    try:
        return round(float(s), 2)
    except ValueError:
        return None


def norm_int(value):
    s = norm_text(value).replace(",", "")
    if not s or s.startswith("#ERR"):
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------
class Findings:
    """Collects validation findings. Severity REJECT blocks a row; WARNING lets it through flagged."""

    def __init__(self):
        self.rows = []
        self._seen = set()

    def add(self, severity, source, row_num, target, key, rule, message):
        # The same sheet exists in both workbooks, so identical findings are collapsed rather
        # than reported twice - a noisy report is a report nobody reads.
        signature = (severity, target, key, rule, message)
        if signature in self._seen:
            return
        self._seen.add(signature)
        self.rows.append({
            "Severity": severity, "SourceFile": os.path.basename(str(source)), "SourceRow": row_num,
            "TargetList": target, "RecordKey": key, "Rule": rule, "Message": message,
        })

    def reject(self, *a):
        self.add("REJECT", *a)

    def warn(self, *a):
        self.add("WARNING", *a)

    def info(self, *a):
        self.add("INFO", *a)

    def counts(self):
        c = defaultdict(int)
        for r in self.rows:
            c[r["Severity"]] += 1
        return dict(c)


# ---------------------------------------------------------------------------
# Master data extraction
# ---------------------------------------------------------------------------
def extract_customers(books, findings):
    """Customer master. Both workbooks carry a 'Cust Data' sheet with the code/name columns
    in a different order, so the header row is read rather than assumed."""
    by_key = {}
    for src, book in books.items():
        rows = book.get("Cust Data")
        if not rows:
            continue
        header_row = next((r for r in sorted(rows) if "Customer Name" in
                           [norm_text(v) for v in rows[r].values()]), None)
        if header_row is None:
            findings.warn(src, "", "11_Customers", "", "SHEET_LAYOUT",
                          "'Cust Data' sheet found but no header row containing 'Customer Name'.")
            continue
        header = {norm_text(v): k for k, v in rows[header_row].items()}
        c_name, c_code, c_country = header.get("Customer Name"), header.get("Customer Code"), header.get("Country")
        for rn in sorted(rows):
            if rn <= header_row:
                continue
            cells = rows[rn]
            name = norm_text(cells.get(c_name)) if c_name is not None else ""
            if not name:
                continue
            code = norm_text(cells.get(c_code)) if c_code is not None else ""
            country = norm_text(cells.get(c_country)) if c_country is not None else ""
            key = norm_key(name)
            if key in by_key:
                prev = by_key[key]
                if code and prev["CustomerCode"] and code != prev["CustomerCode"]:
                    findings.warn(src, rn, "11_Customers", name, "DUP_CODE_CONFLICT",
                                  f"'{name}' appears with codes {prev['CustomerCode']} and {code}. "
                                  f"Kept {prev['CustomerCode']}; confirm which is correct before commit.")
                if not prev["CountryName"] and country:
                    prev["CountryName"] = country
                continue
            by_key[key] = {
                "Title": name, "CustomerCode": code, "CustomerNameNormalized": key,
                "CountryName": country, "CustomerType": "Distributor",
                "IsActive": "TRUE", "SortOrder": 100,
            }
    return sorted(by_key.values(), key=lambda r: r["Title"].upper())


def extract_banks(books, findings):
    """The legacy 'Banks Data' sheet holds four independent columns: SA Banks, Global Banks,
    and two unlabelled lists headed 'our' and 'there'. They are merged into one master with
    role flags: domestic banks advise, global banks issue."""
    banks = {}

    def put(name, group, advise, issue):
        name = norm_text(name)
        if not name or name.lower() in ("#", "our", "there"):
            return
        key = name.upper()
        rec = banks.setdefault(key, {
            "Title": name, "BankCode": re.sub(r"[^A-Z0-9]", "", name.upper())[:20],
            "SwiftBIC": "", "BankGroup": group, "CanAdvise": "FALSE", "CanIssue": "FALSE",
            "CanConfirm": "FALSE", "CanReimburse": "FALSE", "CountryName": "",
            "StandardExamDays": 5, "IsActive": "TRUE", "SortOrder": 100,
        })
        if advise:
            rec["CanAdvise"] = "TRUE"
        if issue:
            rec["CanIssue"] = "TRUE"
        if group == "Global":
            rec["BankGroup"] = "Global"

    for src, book in books.items():
        rows = book.get("Banks Data")
        if not rows:
            continue
        for rn in sorted(rows):
            cells = rows[rn]
            put(cells.get(2), "Domestic", True, False)   # 'SA Banks' column
            put(cells.get(5), "Global", False, True)     # 'Global Banks' column
            put(cells.get(7), "Domestic", True, False)   # 'our' column - banks we advise through
            put(cells.get(9), "Global", False, True)     # 'there' column - customer-side issuers
    findings.info("banks", "", "12_Banks", "", "MERGE",
                  f"{len(banks)} unique banks merged from the four legacy columns.")
    return sorted(banks.values(), key=lambda r: r["Title"].upper())


def extract_payment_terms(books):
    """Derive tenor days and maturity basis from the free-text term so due dates become
    calculable instead of hand-typed."""
    terms = {}
    for book in books.values():
        rows = book.get("Payment Term")
        if not rows:
            continue
        for rn in sorted(rows):
            for col, val in rows[rn].items():
                text = norm_text(val)
                if not text or text in ("#", "Payment Term") or re.match(r"^\d+$", text):
                    continue
                if text.upper() in terms:
                    continue
                days = 0
                m = re.search(r"(\d+)\s*(?:calendar\s*)?days", text, re.I)
                if m:
                    days = int(m.group(1))
                lower = text.lower()
                if "at sight" in lower or lower == "sight":
                    basis, settle = "Sight", "Sight"
                elif "tcn" in lower:
                    basis, settle = "TCN Date", "Deferred"
                elif "presentation" in lower:
                    basis, settle = "Presentation Date", "Deferred"
                elif "shipment" in lower:
                    basis, settle = "Shipment Date", "Deferred"
                elif re.search(r"\bdn\b", lower):
                    basis, settle = "Invoice Date", "Deferred"
                else:
                    basis, settle = "Shipment Date", "Deferred"
                terms[text.upper()] = {
                    "Title": text,
                    "PaymentTermCode": re.sub(r"[^A-Z0-9]", "", text.upper())[:40] or f"PT{len(terms) + 1}",
                    "SettlementType": settle, "TenorDays": days, "MaturityBasis": basis,
                    "IsActive": "TRUE", "SortOrder": 100,
                }
    # Sight terms observed in the LC tracker but absent from the Payment Term sheet.
    if "AT SIGHT" not in terms:
        terms["AT SIGHT"] = {"Title": "At Sight", "PaymentTermCode": "ATSIGHT", "SettlementType": "Sight",
                             "TenorDays": 0, "MaturityBasis": "Sight", "IsActive": "TRUE", "SortOrder": 10}
    return sorted(terms.values(), key=lambda r: (r["SettlementType"], r["TenorDays"], r["Title"]))


COUNTRY_META = {
    "Oman": ("OM", "Middle East", "Low"), "Iraq": ("IQ", "Middle East", "High"),
    "Libya": ("LY", "North Africa", "High"), "Ethiopia": ("ET", "East Africa", "High"),
    "Morocco": ("MA", "North Africa", "Medium"), "UAE": ("AE", "Middle East", "Low"),
    "Kuwait": ("KW", "Middle East", "Low"), "Saudi Arabia": ("SA", "Middle East", "Low"),
    "Qatar": ("QA", "Middle East", "Low"), "Bahrain": ("BH", "Middle East", "Low"),
    "Jordan": ("JO", "Middle East", "Medium"), "Yemen": ("YE", "Middle East", "High"),
    "Sudan": ("SD", "East Africa", "High"), "Egypt": ("EG", "North Africa", "Medium"),
    "Algeria": ("DZ", "North Africa", "Medium"), "Tunisia": ("TN", "North Africa", "Medium"),
    "Kenya": ("KE", "East Africa", "Medium"), "Somalia": ("SO", "East Africa", "High"),
    "Djibouti": ("DJ", "East Africa", "Medium"), "Lebanon": ("LB", "Middle East", "High"),
    "Syria": ("SY", "Middle East", "Restricted"), "Pakistan": ("PK", "South Asia", "High"),
    "Afghanistan": ("AF", "South Asia", "Restricted"),
}


def extract_countries(customers, lc_rows):
    seen = {}
    for c in customers:
        if c["CountryName"]:
            seen[c["CountryName"]] = True
    for lc in lc_rows:
        if lc.get("CountryName"):
            seen[lc["CountryName"]] = True
    out = []
    for name in sorted(seen):
        code, region, risk = COUNTRY_META.get(name, ("", "", "Medium"))
        out.append({
            "Title": name, "CountryCode": code, "Region": region, "RiskRating": risk,
            "RequiresConfirmation": "TRUE" if risk in ("High", "Restricted") else "FALSE",
            "IsSanctioned": "FALSE", "IsActive": "TRUE", "SortOrder": 100,
        })
    return out


# ---------------------------------------------------------------------------
# Transactional extraction
# ---------------------------------------------------------------------------
LC_HEADER_ALIASES = {
    "2026#": "LCYearSeq", "Customer": "CustomerName", "Country": "CountryName",
    "Customer #": "CustomerCode", "Advising Bank": "AdvisingBankName",
    "Advising Bank #": "OurReference", "Payment Term": "PaymentTermText",
    "Issuing Bank2": "IssuingBankName", "Issuing Bank #2": "LCNumber",
    "Issuance Date": "IssuanceDate", "Expiry Date": "ExpiryDate",
    "Latest Date O/S": "LatestShipmentDate", "Sight / Deferred": "SightOrDeferred",
    "CCY": "CurrencyCode", "LC Value (USD)": "LCAmount",
}
INVOICE_BLOCK = ["InvoiceNumber", "InvoiceAmount", "PresentationDate", "InvoiceStatus",
                 "CollectionDate", "DueDate", "TrackingNumber"]


def extract_lcs_and_invoices(books, findings):
    """Flatten the 'LC Tracker' sheet. Columns 0-14 are the LC; columns 15+ are twelve repeating
    7-column invoice blocks. Each block becomes a row in 03_Invoices."""
    lcs, invoices = [], []
    seen_lc_numbers = {}
    seen_our_refs = {}

    for src, book in books.items():
        rows = book.get("LC Tracker")
        if not rows:
            continue
        header_row = next((r for r in sorted(rows)
                           if "Customer" in [norm_text(v) for v in rows[r].values()]), None)
        if header_row is None:
            findings.reject(src, "", "01_ExportLCs", "", "SHEET_LAYOUT",
                            "'LC Tracker' sheet has no recognisable header row.")
            continue
        header = {norm_text(v): k for k, v in rows[header_row].items()}
        colmap = {field: header[label] for label, field in LC_HEADER_ALIASES.items() if label in header}
        missing = [l for l in LC_HEADER_ALIASES if l not in header]
        if missing:
            findings.warn(src, header_row, "01_ExportLCs", "", "HEADER_MISSING",
                          "Header columns not found, those fields will be blank: " + ", ".join(missing))

        inv_start = max(colmap.values()) + 1 if colmap else 15

        for rn in sorted(rows):
            if rn <= header_row:
                continue
            cells = rows[rn]
            rec = {f: norm_text(cells.get(c)) for f, c in colmap.items()}

            # Grand total / spacer rows carry an amount but no customer.
            if not rec.get("CustomerName"):
                if norm_money(rec.get("LCAmount")) is not None:
                    findings.info(src, rn, "01_ExportLCs", "", "SKIP_TOTAL_ROW",
                                  "Row has an amount but no customer - treated as a spreadsheet total row and skipped.")
                continue

            rec["LCAmount"] = norm_money(rec.get("LCAmount"))
            rec["LCYearSeq"] = norm_int(rec.get("LCYearSeq"))
            for d in ("IssuanceDate", "ExpiryDate", "LatestShipmentDate"):
                raw = rec.get(d, "")
                rec[d] = norm_date(raw)
                if raw and not rec[d]:
                    findings.warn(src, rn, "01_ExportLCs", rec.get("LCNumber", ""), "DATE_UNPARSED",
                                  f"{d} value '{raw}' could not be parsed and was left blank.")
            rec["CurrencyCode"] = (rec.get("CurrencyCode") or "USD").upper()
            rec["CustomerNameKey"] = norm_key(rec["CustomerName"])
            rec["SourceFile"] = os.path.basename(src)
            rec["SourceRow"] = rn

            key = rec.get("LCNumber") or ""
            ref = rec.get("OurReference") or ""

            # --- validations -------------------------------------------------
            if not key:
                findings.reject(src, rn, "01_ExportLCs", ref, "LC_NUMBER_REQUIRED",
                                "No LC number (issuing bank reference). Row cannot be committed.")
            elif key.upper() in seen_lc_numbers:
                findings.reject(src, rn, "01_ExportLCs", key, "DUPLICATE_LC_NUMBER",
                                f"LC number already seen at row {seen_lc_numbers[key.upper()]}.")
            else:
                seen_lc_numbers[key.upper()] = rn

            if ref:
                if ref.upper() in seen_our_refs:
                    findings.warn(src, rn, "01_ExportLCs", key, "DUPLICATE_OUR_REFERENCE",
                                  f"Our reference '{ref}' already used at row {seen_our_refs[ref.upper()]}.")
                else:
                    seen_our_refs[ref.upper()] = rn

            if rec["LCAmount"] is None:
                findings.reject(src, rn, "01_ExportLCs", key, "AMOUNT_REQUIRED", "LC amount is missing or non-numeric.")
            elif rec["LCAmount"] < 0:
                findings.reject(src, rn, "01_ExportLCs", key, "AMOUNT_NEGATIVE", f"LC amount {rec['LCAmount']} is negative.")
            elif rec["LCAmount"] == 0:
                findings.warn(src, rn, "01_ExportLCs", key, "AMOUNT_ZERO", "LC amount is zero.")

            if rec.get("ExpiryDate") and rec.get("LatestShipmentDate") and rec["LatestShipmentDate"] > rec["ExpiryDate"]:
                findings.reject(src, rn, "01_ExportLCs", key, "SHIPMENT_AFTER_EXPIRY",
                                f"Latest shipment date {rec['LatestShipmentDate']} is after LC expiry {rec['ExpiryDate']}.")
            if rec.get("ExpiryDate") and rec.get("IssuanceDate") and rec["ExpiryDate"] < rec["IssuanceDate"]:
                findings.reject(src, rn, "01_ExportLCs", key, "EXPIRY_BEFORE_ISSUANCE",
                                f"Expiry {rec['ExpiryDate']} precedes issuance {rec['IssuanceDate']}.")
            if not rec.get("IssuingBankName"):
                findings.warn(src, rn, "01_ExportLCs", key, "ISSUING_BANK_MISSING",
                              "No issuing bank recorded.")
            if not rec.get("ExpiryDate"):
                findings.warn(src, rn, "01_ExportLCs", key, "EXPIRY_MISSING", "No expiry date - deadline alerts cannot run for this LC.")

            # --- invoice blocks ----------------------------------------------
            utilized, inv_count = 0.0, 0
            seen_inv_in_lc = {}
            block = 0
            while True:
                base = inv_start + block * len(INVOICE_BLOCK)
                if base > max(cells) if cells else True:
                    break
                block += 1
                if block > 40:
                    break
                inv_no = norm_text(cells.get(base))
                if not inv_no:
                    continue
                amount = norm_money(cells.get(base + 1))
                inv = {
                    "Title": inv_no,
                    "LCNumber": key, "OurReference": ref,
                    "CustomerName": rec["CustomerName"], "CustomerCode": rec.get("CustomerCode", ""),
                    "CurrencyCode": rec["CurrencyCode"],
                    "InvoiceAmount": amount,
                    "PresentationDate": norm_date(cells.get(base + 2)),
                    "InvoiceStatus": norm_text(cells.get(base + 3)) or "Issued",
                    "CollectionDate": norm_date(cells.get(base + 4)),
                    "DueDate": norm_date(cells.get(base + 5)),
                    "TrackingNumber": norm_text(cells.get(base + 6)),
                    "SourceFile": os.path.basename(src), "SourceRow": rn, "SourceBlock": block,
                }
                if inv_no.upper() in seen_inv_in_lc:
                    findings.reject(src, rn, "03_Invoices", f"{key}/{inv_no}", "DUPLICATE_INVOICE_IN_LC",
                                    f"Invoice {inv_no} appears twice under LC {key} (blocks "
                                    f"{seen_inv_in_lc[inv_no.upper()]} and {block}).")
                    inv["_rejected"] = True
                else:
                    seen_inv_in_lc[inv_no.upper()] = block
                if amount is None:
                    findings.reject(src, rn, "03_Invoices", f"{key}/{inv_no}", "INVOICE_AMOUNT_REQUIRED",
                                    "Invoice value is missing or non-numeric.")
                    inv["_rejected"] = True
                elif amount < 0:
                    findings.reject(src, rn, "03_Invoices", f"{key}/{inv_no}", "INVOICE_AMOUNT_NEGATIVE",
                                    f"Invoice value {amount} is negative.")
                    inv["_rejected"] = True
                else:
                    utilized += amount
                if inv["CollectionDate"] and inv["DueDate"] and inv["CollectionDate"] > inv["DueDate"]:
                    findings.warn(src, rn, "03_Invoices", f"{key}/{inv_no}", "COLLECTED_AFTER_DUE",
                                  "Collection date is after the due date.")
                invoices.append(inv)
                inv_count += 1

            rec["InvoiceCount"] = inv_count
            rec["UtilizedAmount"] = round(utilized, 2)
            if rec["LCAmount"] is not None:
                rec["OutstandingAmount"] = round(rec["LCAmount"] - utilized, 2)
                if utilized > rec["LCAmount"] + 0.01:
                    findings.warn(src, rn, "01_ExportLCs", key, "OVERDRAWN",
                                  f"Invoices total {utilized:,.2f} against an LC of {rec['LCAmount']:,.2f} "
                                  f"(over by {utilized - rec['LCAmount']:,.2f}). Check for a missing amendment.")
                rec["LCStatus"] = ("Fully Drawn" if abs(rec["OutstandingAmount"]) < 0.01
                                   else "Partially Drawn" if utilized > 0 else "Active")
                rec["IsClosed"] = "TRUE" if rec["LCStatus"] == "Fully Drawn" else "FALSE"
            else:
                rec["OutstandingAmount"] = None
                rec["LCStatus"] = "Draft"
                rec["IsClosed"] = "FALSE"
            lcs.append(rec)

    return lcs, invoices


def merge_invoice_process_tracker(books, lcs, invoices, findings):
    """The 'Invoice Process Tracker' sheet in the second workbook is a flat invoice register keyed
    on our reference (2026/ILC/nnnn) rather than the issuing bank LC number. It carries status,
    collection dates and next actions that the wide LC Tracker blocks do not.

    Rows are matched to already-extracted invoices and used to enrich them; unmatched rows are
    added as new invoices. Where the two sources disagree on an amount, both values are reported
    and the LC Tracker - the source of the reconciled totals - wins."""
    ref_to_lc = {}
    for lc in lcs:
        if lc.get("OurReference"):
            ref_to_lc[lc["OurReference"].upper()] = lc
    existing = {(i["OurReference"].upper(), i["Title"].upper()): i for i in invoices if i.get("OurReference")}
    by_number = {}
    for i in invoices:
        by_number.setdefault(i["Title"].upper(), []).append(i)

    added = enriched = 0
    for src, book in books.items():
        rows = book.get("Invoice Process Tracker")
        if not rows:
            continue
        header_row = next((r for r in sorted(rows)
                           if "Invoice Number" in [norm_text(v) for v in rows[r].values()]), None)
        if header_row is None:
            continue
        header = {norm_text(v): k for k, v in rows[header_row].items()}
        cols = {
            "ref": header.get("LC #"), "cust": header.get("Customer"),
            "inv": header.get("Invoice Number"), "val": header.get("Value"),
            "pres": header.get("Pres. Date"), "status": header.get("Status"),
            "coll": header.get("Coll. Date"), "due": header.get("Due Date"),
            "track": header.get("Tracking #"), "notes": header.get("Notes"),
            "next": header.get("Next Action"),
        }
        if cols["inv"] is None:
            continue

        for rn in sorted(rows):
            if rn <= header_row:
                continue
            cells = rows[rn]
            inv_no = norm_text(cells.get(cols["inv"]))
            if not inv_no or inv_no.upper() == "INVOICE NUMBER":
                continue
            ref = norm_text(cells.get(cols["ref"])) if cols["ref"] is not None else ""
            amount = norm_money(cells.get(cols["val"])) if cols["val"] is not None else None
            status = norm_text(cells.get(cols["status"])) if cols["status"] is not None else ""

            target = existing.get((ref.upper(), inv_no.upper()))
            if target is None:
                candidates = by_number.get(inv_no.upper(), [])
                if len(candidates) == 1:
                    target = candidates[0]
                elif len(candidates) > 1:
                    findings.warn(src, rn, "03_Invoices", inv_no, "AMBIGUOUS_INVOICE_MATCH",
                                  f"Invoice {inv_no} matches {len(candidates)} rows in the LC Tracker; "
                                  f"process-tracker detail not merged.")
                    continue

            if target is not None:
                if amount is not None and target.get("InvoiceAmount") is not None \
                        and abs(amount - target["InvoiceAmount"]) > 0.01:
                    findings.warn(src, rn, "03_Invoices", inv_no, "AMOUNT_CONFLICT",
                                  f"Invoice {inv_no} is {target['InvoiceAmount']:,.2f} in the LC Tracker but "
                                  f"{amount:,.2f} in the Invoice Process Tracker. LC Tracker value kept.")
                if amount is not None and target.get("InvoiceAmount") is None:
                    target["InvoiceAmount"] = amount
                for key, col in (("InvoiceStatus", "status"), ("TrackingNumber", "track")):
                    val = norm_text(cells.get(cols[col])) if cols[col] is not None else ""
                    if val and not target.get(key):
                        target[key] = val
                for key, col in (("PresentationDate", "pres"), ("CollectionDate", "coll"), ("DueDate", "due")):
                    val = norm_date(cells.get(cols[col])) if cols[col] is not None else ""
                    if val and not target.get(key):
                        target[key] = val
                for key, col in (("InvoiceNotes", "notes"), ("NextAction", "next")):
                    val = norm_text(cells.get(cols[col])) if cols[col] is not None else ""
                    if val and not target.get(key):
                        target[key] = val
                enriched += 1
                continue

            lc = ref_to_lc.get(ref.upper())
            if lc is None:
                findings.warn(src, rn, "03_Invoices", inv_no, "ORPHAN_INVOICE",
                              f"Invoice {inv_no} references LC '{ref}', which is not in the LC Tracker. "
                              f"Staged without an LC link - assign it before commit or it will be rejected.")
            new_inv = {
                "Title": inv_no,
                "LCNumber": lc["LCNumber"] if lc else "",
                "OurReference": ref,
                "CustomerName": (norm_text(cells.get(cols["cust"])) if cols["cust"] is not None else "")
                                or (lc["CustomerName"] if lc else ""),
                "CustomerCode": lc.get("CustomerCode", "") if lc else "",
                "CurrencyCode": lc["CurrencyCode"] if lc else "USD",
                "InvoiceAmount": amount,
                "PresentationDate": norm_date(cells.get(cols["pres"])) if cols["pres"] is not None else "",
                "InvoiceStatus": status or "Issued",
                "CollectionDate": norm_date(cells.get(cols["coll"])) if cols["coll"] is not None else "",
                "DueDate": norm_date(cells.get(cols["due"])) if cols["due"] is not None else "",
                "TrackingNumber": norm_text(cells.get(cols["track"])) if cols["track"] is not None else "",
                "InvoiceNotes": norm_text(cells.get(cols["notes"])) if cols["notes"] is not None else "",
                "NextAction": norm_text(cells.get(cols["next"])) if cols["next"] is not None else "",
                "SourceFile": os.path.basename(src), "SourceRow": rn, "SourceBlock": 0,
            }
            if amount is None:
                findings.reject(src, rn, "03_Invoices", inv_no, "INVOICE_AMOUNT_REQUIRED",
                                "Invoice value is missing or non-numeric.")
                new_inv["_rejected"] = True
            invoices.append(new_inv)
            if lc is not None:
                existing[(ref.upper(), inv_no.upper())] = new_inv
            by_number.setdefault(inv_no.upper(), []).append(new_inv)
            added += 1

    if added or enriched:
        findings.info("Invoice Process Tracker", "", "03_Invoices", "", "MERGE",
                      f"{enriched} invoice(s) enriched and {added} additional invoice(s) found in the "
                      f"Invoice Process Tracker sheet that are absent from the LC Tracker blocks.")
    return added, enriched


def recalculate_lc_totals(lcs, invoices, findings):
    """Re-derive utilisation after the merge so LC totals reflect every invoice source."""
    by_lc = defaultdict(list)
    for inv in invoices:
        if inv.get("LCNumber"):
            by_lc[inv["LCNumber"].upper()].append(inv)
    for lc in lcs:
        key = (lc.get("LCNumber") or "").upper()
        rows = by_lc.get(key, [])
        utilized = round(sum(i["InvoiceAmount"] or 0 for i in rows if not i.get("_rejected")), 2)
        lc["InvoiceCount"] = len(rows)
        lc["UtilizedAmount"] = utilized
        if lc.get("LCAmount") is None:
            continue
        lc["OutstandingAmount"] = round(lc["LCAmount"] - utilized, 2)
        if utilized > lc["LCAmount"] + 0.01:
            findings.warn(lc["SourceFile"], lc["SourceRow"], "01_ExportLCs", lc.get("LCNumber", ""),
                          "OVERDRAWN",
                          f"Invoices total {utilized:,.2f} against an LC of {lc['LCAmount']:,.2f} "
                          f"(over by {utilized - lc['LCAmount']:,.2f}). Check for a missing amendment.")
        lc["LCStatus"] = ("Fully Drawn" if abs(lc["OutstandingAmount"]) < 0.01
                          else "Partially Drawn" if utilized > 0 else "Active")
        lc["IsClosed"] = "TRUE" if lc["LCStatus"] == "Fully Drawn" else "FALSE"


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
def write_csv(path, rows, columns):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=columns, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({c: ("" if r.get(c) is None else r.get(c)) for c in columns})
    return len(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract and validate the legacy Export LC workbooks.")
    ap.add_argument("--legacy-dir", default="legacy")
    ap.add_argument("--out-dir", default="migration/out")
    ap.add_argument("--master-dir", default="sharepoint/masterdata")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.legacy_dir) if f.lower().endswith(".xlsx") and not f.startswith("~$"))
    if not files:
        print(f"No .xlsx files found in {args.legacy_dir}", file=sys.stderr)
        return 2

    books = {}
    for f in files:
        path = os.path.join(args.legacy_dir, f)
        try:
            books[path] = read_workbook(path)
            print(f"read {f}: {len(books[path])} sheets")
        except Exception as exc:  # a corrupt workbook must not take the whole run down
            print(f"FAILED to read {f}: {exc}", file=sys.stderr)

    findings = Findings()
    customers = extract_customers(books, findings)
    banks = extract_banks(books, findings)
    payment_terms = extract_payment_terms(books)
    lcs, invoices = extract_lcs_and_invoices(books, findings)
    merge_invoice_process_tracker(books, lcs, invoices, findings)
    recalculate_lc_totals(lcs, invoices, findings)
    countries = extract_countries(customers, lcs)

    # Cross-check every LC's customer against the customer master.
    cust_keys = {c["CustomerNameNormalized"] for c in customers}
    for lc in lcs:
        if lc["CustomerNameKey"] not in cust_keys:
            findings.warn(lc["SourceFile"], lc["SourceRow"], "01_ExportLCs", lc.get("LCNumber", ""),
                          "CUSTOMER_NOT_IN_MASTER",
                          f"Customer '{lc['CustomerName']}' is not in the customer master and will be "
                          f"created on commit. Check it is not a spelling variant of an existing customer.")

    bank_names = {b["Title"].upper() for b in banks}
    for lc in lcs:
        for field, label in (("IssuingBankName", "issuing"), ("AdvisingBankName", "advising")):
            name = lc.get(field, "")
            if name and name.upper() not in bank_names:
                findings.warn(lc["SourceFile"], lc["SourceRow"], "01_ExportLCs", lc.get("LCNumber", ""),
                              "BANK_NOT_IN_MASTER", f"{label.capitalize()} bank '{name}' is not in the bank master.")

    # Always seed the currencies the business could plausibly trade in, not only those seen
    # in the legacy data, so an officer registering a EUR LC on day one has a value to pick.
    STANDARD_CCY = ["USD", "EUR", "SAR", "AED", "GBP", "CHF", "JPY", "OMR", "KWD", "BHD", "QAR", "EGP", "MAD", "ETB"]
    seen_ccy = {(lc.get("CurrencyCode") or "USD") for lc in lcs} | {"USD"}
    currencies = STANDARD_CCY + sorted(seen_ccy - set(STANDARD_CCY))
    CCY_NAMES = {"USD": "US Dollar", "EUR": "Euro", "SAR": "Saudi Riyal", "AED": "UAE Dirham",
                 "GBP": "Pound Sterling", "CHF": "Swiss Franc", "JPY": "Japanese Yen",
                 "OMR": "Omani Rial", "KWD": "Kuwaiti Dinar", "BHD": "Bahraini Dinar",
                 "QAR": "Qatari Riyal", "EGP": "Egyptian Pound", "MAD": "Moroccan Dirham",
                 "ETB": "Ethiopian Birr"}
    # Pegged rates are stable and safe to seed; floating ones are left blank so nobody
    # reports exposure against a stale hard-coded number. Admin maintains them in 14_Currencies.
    CCY_RATE = {"USD": 1, "SAR": 0.266667, "AED": 0.272294, "OMR": 2.6008, "QAR": 0.274725, "BHD": 2.6525}
    CCY_DEC = {"JPY": 0, "KWD": 3, "BHD": 3, "OMR": 3}
    currency_rows = [{"Title": c, "CurrencyName": CCY_NAMES.get(c, c),
                      "CurrencySymbol": {"USD": "$", "EUR": "\u20ac", "GBP": "\u00a3", "JPY": "\u00a5"}.get(c, ""),
                      "DecimalPlaces": CCY_DEC.get(c, 2), "RateToUSD": CCY_RATE.get(c, ""),
                      "IsActive": "TRUE" if c in seen_ccy else "FALSE",
                      "SortOrder": 10 if c == "USD" else 100} for c in currencies]

    n = {}
    n["customers"] = write_csv(f"{args.master_dir}/11_Customers.csv", customers,
                               ["Title", "CustomerCode", "CustomerNameNormalized", "CountryName",
                                "CustomerType", "IsActive", "SortOrder"])
    n["banks"] = write_csv(f"{args.master_dir}/12_Banks.csv", banks,
                           ["Title", "BankCode", "SwiftBIC", "BankGroup", "CanAdvise", "CanIssue",
                            "CanConfirm", "CanReimburse", "CountryName", "StandardExamDays", "IsActive", "SortOrder"])
    n["countries"] = write_csv(f"{args.master_dir}/13_Countries.csv", countries,
                               ["Title", "CountryCode", "Region", "RiskRating", "RequiresConfirmation",
                                "IsSanctioned", "IsActive", "SortOrder"])
    n["currencies"] = write_csv(f"{args.master_dir}/14_Currencies.csv", currency_rows,
                                ["Title", "CurrencyName", "CurrencySymbol", "DecimalPlaces", "RateToUSD",
                                 "IsActive", "SortOrder"])
    n["paymentterms"] = write_csv(f"{args.master_dir}/25_PaymentTerms.csv", payment_terms,
                                  ["Title", "PaymentTermCode", "SettlementType", "TenorDays",
                                   "MaturityBasis", "IsActive", "SortOrder"])
    n["lcs"] = write_csv(f"{args.out_dir}/staging_01_ExportLCs.csv", lcs,
                         ["LCNumber", "OurReference", "LCYearSeq", "CustomerName", "CustomerCode",
                          "CountryName", "AdvisingBankName", "IssuingBankName", "PaymentTermText",
                          "SightOrDeferred", "CurrencyCode", "LCAmount", "UtilizedAmount",
                          "OutstandingAmount", "IssuanceDate", "ExpiryDate", "LatestShipmentDate",
                          "InvoiceCount", "LCStatus", "IsClosed", "SourceFile", "SourceRow"])
    n["invoices"] = write_csv(f"{args.out_dir}/staging_03_Invoices.csv", invoices,
                              ["Title", "LCNumber", "OurReference", "CustomerName", "CustomerCode",
                               "CurrencyCode", "InvoiceAmount", "PresentationDate", "InvoiceStatus",
                               "CollectionDate", "DueDate", "TrackingNumber", "InvoiceNotes",
                               "NextAction", "SourceFile", "SourceRow", "SourceBlock"])
    write_csv(f"{args.out_dir}/validation_report.csv", findings.rows,
              ["Severity", "SourceFile", "SourceRow", "TargetList", "RecordKey", "Rule", "Message"])

    counts = findings.counts()
    total_lc = sum(lc["LCAmount"] or 0 for lc in lcs)
    total_inv = sum(i["InvoiceAmount"] or 0 for i in invoices)
    matched_inv = sum(i["InvoiceAmount"] or 0 for i in invoices if i.get("LCNumber"))
    orphan_inv_rows = [i for i in invoices if not i.get("LCNumber")]
    orphan_inv = sum(i["InvoiceAmount"] or 0 for i in orphan_inv_rows)
    orphan_refs = sorted({i.get("OurReference", "") for i in orphan_inv_rows if i.get("OurReference")})
    rejected_keys = {f["RecordKey"] for f in findings.rows if f["Severity"] == "REJECT"}

    by_customer = defaultdict(lambda: [0, 0.0, 0.0])
    for lc in lcs:
        b = by_customer[lc["CustomerName"]]
        b[0] += 1
        b[1] += lc["LCAmount"] or 0
        b[2] += lc["OutstandingAmount"] or 0

    os.makedirs(args.out_dir, exist_ok=True)
    with open(f"{args.out_dir}/summary.md", "w", encoding="utf-8") as fh:
        fh.write("# Legacy extraction summary\n\n")
        fh.write(f"Generated {dt.datetime.now().strftime('%Y-%m-%d %H:%M')} from: {', '.join(files)}\n\n")
        fh.write("## Records extracted\n\n| Output | Rows |\n|---|---:|\n")
        for k in ("lcs", "invoices", "customers", "banks", "countries", "currencies", "paymentterms"):
            fh.write(f"| {k} | {n[k]} |\n")
        fh.write("\n## Validation findings\n\n| Severity | Count |\n|---|---:|\n")
        for sev in ("REJECT", "WARNING", "INFO"):
            fh.write(f"| {sev} | {counts.get(sev, 0)} |\n")
        fh.write(f"\n{len(rejected_keys)} record(s) carry at least one REJECT and will not be committed "
                 f"until corrected.\n")
        fh.write("\n## Reconciliation\n\n")
        fh.write(f"- LCs extracted: **{len(lcs)}**, total LC value **{total_lc:,.2f}**\n")
        fh.write(f"- Invoices extracted: **{len(invoices)}**, total value **{total_inv:,.2f}**\n")
        fh.write(f"- Invoices matched to an LC: **{len(invoices) - len(orphan_inv_rows)}**, "
                 f"value **{matched_inv:,.2f}**\n")
        fh.write(f"- Utilisation against extracted LCs: **{total_lc - matched_inv:,.2f}** outstanding\n")
        fh.write(f"- Orphan invoices (no matching LC): **{len(orphan_inv_rows)}**, value **{orphan_inv:,.2f}**\n\n")
        if orphan_refs:
            fh.write("The orphan invoices reference these LCs, which appear in the Invoice Process Tracker "
                     "but not in the LC Tracker sheet. Either the LC Tracker is behind, or these LCs were "
                     "registered somewhere else. They must be registered in the portal before their "
                     "invoices can be committed:\n\n")
            for r in orphan_refs:
                fh.write(f"- `{r}`\n")
            fh.write("\n")
        fh.write("Do not reconcile against the legacy Summary sheet: it contains `#REF!` errors and its "
                 "own stated LC count (14) disagrees with the 20 rows actually present in the LC Tracker. "
                 "Reconcile against the LC Tracker rows instead.\n")
        fh.write("\n## Exposure by customer\n\n| Customer | LCs | LC Value | Outstanding |\n|---|---:|---:|---:|\n")
        for cust, (cnt, val, out) in sorted(by_customer.items(), key=lambda kv: -kv[1][1]):
            fh.write(f"| {cust} | {cnt} | {val:,.2f} | {out:,.2f} |\n")
        fh.write("\n## Top validation rules triggered\n\n| Rule | Count |\n|---|---:|\n")
        rule_counts = defaultdict(int)
        for f in findings.rows:
            rule_counts[f["Rule"]] += 1
        for rule, cnt in sorted(rule_counts.items(), key=lambda kv: -kv[1]):
            fh.write(f"| {rule} | {cnt} |\n")

    print()
    print(f"LCs        : {n['lcs']}")
    print(f"Invoices   : {n['invoices']}")
    print(f"Customers  : {n['customers']}")
    print(f"Banks      : {n['banks']}")
    print(f"Findings   : " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print(f"LC value   : {total_lc:,.2f}   Invoice value: {total_inv:,.2f}")
    print(f"\nWrote master data to {args.master_dir}/ and staging + reports to {args.out_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
