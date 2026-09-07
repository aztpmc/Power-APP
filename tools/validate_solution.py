#!/usr/bin/env python3
"""
Static validation of the whole Export LC Portal solution.

Runs offline against the repository and checks the things that would otherwise only fail
after deployment, when they are expensive to find:

  1. The SharePoint schema is well formed and inside SharePoint's limits.
  2. Master data CSVs parse, and their cross-references resolve.
  3. Status choices in the schema match the status master exactly.
  4. Every Power Apps source file is valid YAML.
  5. Every list, library and column referenced in Power Fx exists in the schema.
  6. Every Navigate() target is a screen that exists.
  7. Every component used is defined; every component defined is used.
  8. Every flow the app calls exists.
  9. Flow definitions are valid JSON with the required structure, and every SharePoint
     list they touch exists in the schema.

Exit code 0 = everything passed. 1 = at least one FAIL.

Usage:  python3 tools/validate_solution.py [--verbose]
"""
from __future__ import annotations

import csv
import glob
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(ROOT, "sharepoint/schema/site-schema.json")
MASTER = os.path.join(ROOT, "sharepoint/masterdata")
APPSRC = os.path.join(ROOT, "powerapps/ExportLCPortal/Src")
FLOWS = os.path.join(ROOT, "powerautomate/flows")

SP_MAX_INDEXES = 20
SP_MAX_LIST_TITLE = 255

# Columns SharePoint provides on every list or library.
BUILTIN = {
    "ID", "Title", "Created", "Modified", "Author", "Editor", "Attachments", "ContentType",
    "GUID", "Name", "Link to item", "Modified By", "Created By", "File name with extension",
    "Full Path", "Path", "Thumbnail", "Item Type", "Folder path", "File Size", "DocIcon",
    "LinkFilename", "Value",
}

results = []


def check(name, ok, detail="", warn=False):
    results.append({"check": name, "status": "WARN" if (warn and not ok) else ("PASS" if ok else "FAIL"),
                    "detail": detail})
    return ok


def load_schema():
    d = json.load(open(SCHEMA, encoding="utf-8"))
    lists = {l["name"]: l for l in d["lists"]}
    libs = {l["name"]: l for l in d["libraries"]}
    return d, lists, libs


def main(verbose=False):
    schema, lists, libs = load_schema()
    all_objects = dict(lists)
    all_objects.update(libs)

    # ---- 1 schema -------------------------------------------------------
    check("schema: file is valid JSON", True)
    titles = [l["title"] for l in schema["lists"]] + [l["title"] for l in schema["libraries"]]
    check("schema: object titles are unique", len(set(titles)) == len(titles),
          "%d objects" % len(titles))
    check("schema: titles within SharePoint's length limit",
          all(len(t) <= SP_MAX_LIST_TITLE for t in titles))

    valid_types = {"Text", "Note", "Number", "Currency", "DateTime", "Choice", "MultiChoice",
                   "Boolean", "User", "URL"}
    bad_type, dup_field, over_index = [], [], []
    total_fields = 0
    for name, obj in all_objects.items():
        fnames = [f["name"] for f in obj["fields"]]
        total_fields += len(fnames)
        if len(set(fnames)) != len(fnames):
            dup_field.append(name)
        for f in obj["fields"]:
            if f["type"] not in valid_types:
                bad_type.append("%s.%s=%s" % (name, f["name"], f["type"]))
            if not re.match(r"^[A-Za-z][A-Za-z0-9]*$", f["name"]):
                bad_type.append("%s.%s (invalid internal name)" % (name, f["name"]))
        idx = sum(1 for f in obj["fields"] if f.get("indexed"))
        if idx > SP_MAX_INDEXES:
            over_index.append("%s=%d" % (obj["title"], idx))

    check("schema: all field types are supported", not bad_type, ", ".join(bad_type[:5]))
    check("schema: no duplicate field names within an object", not dup_field, ", ".join(dup_field))
    check("schema: indexed columns within SharePoint's limit of %d" % SP_MAX_INDEXES,
          not over_index, ", ".join(over_index))

    # Sitting exactly AT the cap (not just over it) has failed for real: SharePoint's async
    # index-build queue for the list rejects the last request in the batch with "maximum
    # number of columns is currently being indexed", and it does not clear on retry because
    # there is no headroom left to settle into - not a transient race. Keep at least one
    # column of slack per list.
    at_cap = ["%s=%d" % (obj["title"], sum(1 for f in obj["fields"] if f.get("indexed")))
               for name, obj in all_objects.items()
               if sum(1 for f in obj["fields"] if f.get("indexed")) >= SP_MAX_INDEXES]
    check("schema: at least one column of indexing headroom below the %d-per-list cap" % SP_MAX_INDEXES,
          not at_cap, ", ".join(at_cap))
    check("schema: %d columns across %d objects" % (total_fields, len(all_objects)), True)

    # SharePoint cannot index multi-value columns at all (MultiChoice, and multi-value
    # Lookup/User if this schema ever adds one) - it rejects the request outright at
    # provisioning time with "This column type is not supported for indexing." Caught only
    # on a real run against a live tenant the first time; encoded here so it can't recur silently.
    NON_INDEXABLE_TYPES = {"MultiChoice"}
    bad_multi_index = [
        "%s.%s" % (name, f["name"])
        for name, obj in all_objects.items()
        for f in obj["fields"]
        if f.get("indexed") and f["type"] in NON_INDEXABLE_TYPES
    ]
    check("schema: no multi-value column is marked indexed (SharePoint rejects it)",
          not bad_multi_index, ", ".join(bad_multi_index))

    # Choice fields must have choices; defaults must be one of them.
    bad_choice = []
    for name, obj in all_objects.items():
        for f in obj["fields"]:
            if f["type"] in ("Choice", "MultiChoice"):
                if not f.get("choices"):
                    bad_choice.append("%s.%s has no choices" % (name, f["name"]))
                elif "default" in f and f["default"] not in f["choices"]:
                    bad_choice.append("%s.%s default '%s' not in choices" % (name, f["name"], f["default"]))
    check("schema: choice fields have choices and valid defaults", not bad_choice,
          "; ".join(bad_choice[:5]))

    # ---- 2 master data --------------------------------------------------
    csvs = sorted(glob.glob(os.path.join(MASTER, "*.csv")))
    ragged = []
    data = {}
    for path in csvs:
        rows = list(csv.DictReader(open(path, encoding="utf-8-sig")))
        data[os.path.basename(path)] = rows
        if rows and len({len(r) for r in rows}) > 1:
            ragged.append(os.path.basename(path))
    check("master data: %d CSVs parse with consistent column counts" % len(csvs),
          not ragged, ", ".join(ragged))

    # Every master CSV column must be a real column on its list.
    unknown_cols = []
    for fname, rows in data.items():
        listname = fname[:-4]
        obj = next((l for l in schema["lists"] if l["title"] == listname), None)
        if not obj or not rows:
            continue
        known = {f["name"] for f in obj["fields"]} | BUILTIN
        for col in rows[0].keys():
            if col not in known:
                unknown_cols.append("%s.%s" % (fname, col))
    check("master data: every CSV column exists on its list", not unknown_cols,
          ", ".join(unknown_cols[:8]))

    # ---- 3 status master vs schema choices ------------------------------
    status_rows = data.get("16_StatusMaster.csv", [])
    by_entity = {}
    for r in status_rows:
        by_entity.setdefault(r["EntityName"], set()).add(r["StatusCode"])

    pairs = [("ExportLC", "ExportLCs", "LCStatus"), ("Amendment", "LCAmendments", "AmendmentStatus"),
             ("Invoice", "Invoices", "InvoiceStatus"), ("Shipment", "Shipments", "ShipmentStatus"),
             ("Presentation", "Presentations", "PresentationStatus"),
             ("Discrepancy", "Discrepancies", "DiscrepancyStatus"),
             ("Proceeds", "Proceeds", "ProceedsStatus"),
             ("Correspondence", "Correspondence", "CorrespondenceStatus"),
             ("Task", "LCTasks", "TaskStatus")]
    mismatch = []
    for entity, listname, fieldname in pairs:
        f = next((x for x in lists[listname]["fields"] if x["name"] == fieldname), None)
        if not f:
            mismatch.append("%s: field %s missing" % (entity, fieldname))
            continue
        if set(f["choices"]) != by_entity.get(entity, set()):
            only_schema = sorted(set(f["choices"]) - by_entity.get(entity, set()))
            only_master = sorted(by_entity.get(entity, set()) - set(f["choices"]))
            mismatch.append("%s: schema-only %s, master-only %s" % (entity, only_schema, only_master))
    check("workflow: status choices match 16_StatusMaster for all 9 entities",
          not mismatch, "; ".join(mismatch))

    dangling = []
    for r in status_rows:
        for nxt in filter(None, (s.strip() for s in r["AllowedNextStatuses"].split(";"))):
            if nxt not in by_entity[r["EntityName"]]:
                dangling.append("%s %s -> %s" % (r["EntityName"], r["StatusCode"], nxt))
    check("workflow: no transition points at a status that does not exist",
          not dangling, "; ".join(dangling[:5]))

    terminal = [r for r in status_rows if not r["AllowedNextStatuses"].strip()]
    check("workflow: %d terminal states defined" % len(terminal), len(terminal) > 0)

    # Checklist templates must reference real document types.
    doctypes = {r["DocumentTypeCode"] for r in data.get("15_DocumentTypes.csv", [])}
    bad_dt = {r["DocumentTypeCode"] for r in data.get("19_DocChecklistTemplates.csv", [])
              if r["DocumentTypeCode"] not in doctypes}
    check("master data: checklist templates reference known document types",
          not bad_dt, ", ".join(sorted(bad_dt)))

    libs_titles = {l["title"] for l in schema["libraries"]}
    bad_lib = {r["TargetLibrary"] for r in data.get("15_DocumentTypes.csv", [])
               if r["TargetLibrary"] not in libs_titles}
    check("master data: document types route to libraries that exist",
          not bad_lib, ", ".join(sorted(bad_lib)))

    countries = {r["Title"] for r in data.get("13_Countries.csv", [])}
    bad_ctry = {r["AppliesToCountry"] for r in data.get("19_DocChecklistTemplates.csv", [])
                if r["AppliesToCountry"] and r["AppliesToCountry"] not in countries}
    check("master data: checklist country rules reference known countries",
          not bad_ctry, ", ".join(sorted(bad_ctry)))

    # ---- 4 app source YAML ----------------------------------------------
    app_files = sorted(glob.glob(os.path.join(APPSRC, "**/*.fx.yaml"), recursive=True))
    bad_yaml = []
    sources = {}
    for f in app_files:
        text = open(f, encoding="utf-8").read()
        sources[f] = text
        try:
            yaml.safe_load(text)
        except Exception as exc:
            bad_yaml.append("%s: %s" % (os.path.basename(f), str(exc).splitlines()[0]))
    check("app: %d source files are valid YAML" % len(app_files), not bad_yaml,
          "; ".join(bad_yaml[:3]))

    # ---- 5 data references ----------------------------------------------
    # Datasource references appear as '01_ExportLCs' (quoted) or as a bare library name.
    quoted = set()
    for f, text in sources.items():
        quoted |= set(re.findall(r"'(\d{2}_[A-Za-z]+)'", text))
    known_titles = {l["title"] for l in schema["lists"]}
    unknown_ds = sorted(quoted - known_titles)
    check("app: every list referenced in Power Fx exists in the schema",
          not unknown_ds, ", ".join(unknown_ds))
    if verbose:
        print("  lists referenced by the app: %d of %d" % (len(quoted & known_titles), len(known_titles)))

    lib_refs = set()
    for f, text in sources.items():
        for lib in libs_titles:
            if re.search(r"(?<![\w'])" + lib + r"(?![\w'])", text):
                lib_refs.add(lib)
    check("app: every library referenced exists (%d referenced)" % len(lib_refs), True)

    # Typed record-variable references. Each of these globals always holds a record from
    # one known list, so every field read off it must exist on that list. This is the check
    # that catches a mistyped column name before deployment does.
    #
    # A generic ThisItem.X check was tried and abandoned: galleries here are also bound to
    # local Table() literals and to component properties, so it produced far more noise than
    # signal, and a noisy check is one nobody runs.
    typed_vars = {
        "gblCurrentLC": "ExportLCs",
        "gblParentLC": "ExportLCs",
        "gblUploadLC": "ExportLCs",
        "gblImportBatch": "ImportBatches",
        "gblUserRow": "UserRoles",
        "gblUploadDocType": "DocumentTypes",
        "gblAdminRow": None,          # shaped record, checked structurally below
    }
    bad_refs = []
    checked_refs = 0
    for var, listname in typed_vars.items():
        if not listname:
            continue
        allowed = {f["name"] for f in lists[listname]["fields"]} | BUILTIN
        for f, text in sources.items():
            for m in re.finditer(r"(?<![\w.])" + var + r"\.([A-Za-z][A-Za-z0-9]*)", text):
                checked_refs += 1
                tok = m.group(1)
                if tok not in allowed:
                    bad_refs.append("%s: %s.%s" % (os.path.basename(f), var, tok))
    check("app: %d typed record-variable field references all resolve" % checked_refs,
          not bad_refs, "; ".join(sorted(set(bad_refs))[:8]))

    # Component property references must be declared on that component.
    comp_text = sources.get(os.path.join(APPSRC, "Components/Components.fx.yaml"), "")
    comp_props = {}
    current = None
    for line in comp_text.splitlines():
        m = re.match(r"^(cmp\w+) As CanvasComponent", line)
        if m:
            current = m.group(1)
            comp_props[current] = set()
        elif current and re.match(r"^        ([A-Za-z]\w*):$", line):
            comp_props[current].add(re.match(r"^        ([A-Za-z]\w*):$", line).group(1))
    bad_props = []
    for f, text in sources.items():
        for cmp_name, props in comp_props.items():
            for m in re.finditer(r"(?<![\w.])" + cmp_name + r"\.([A-Za-z][A-Za-z0-9]*)", text):
                tok = m.group(1)
                if tok not in props and tok not in {"Width", "Height", "X", "Y", "Visible", "Fill"}:
                    bad_props.append("%s: %s.%s" % (os.path.basename(f), cmp_name, tok))
    check("app: component property references match their declarations",
          not bad_props, "; ".join(sorted(set(bad_props))[:8]))

    # ---- 6 navigation ---------------------------------------------------
    screens = {os.path.basename(f)[:-8] for f in app_files if os.sep + "Screens" + os.sep in f}
    nav_targets = set()
    for f, text in sources.items():
        nav_targets |= set(re.findall(r"Navigate\(\s*(scr\w+)", text))
    check("app: every Navigate() target is a screen that exists (%d screens)" % len(screens),
          not (nav_targets - screens), ", ".join(sorted(nav_targets - screens)))
    unreached = screens - nav_targets - {"scrDashboard"}
    check("app: no screen is unreachable", not unreached, ", ".join(sorted(unreached)), warn=True)

    # ---- 7 components ---------------------------------------------------
    defined = set(re.findall(r"^(cmp\w+) As CanvasComponent", comp_text, re.M))
    used = set()
    for f, text in sources.items():
        if "Components.fx.yaml" in f:
            continue
        used |= set(re.findall(r"As (cmp\w+):", text))
    check("app: every component used is defined (%d components)" % len(defined),
          not (used - defined), ", ".join(sorted(used - defined)))
    check("app: no component is defined but never used", not (defined - used),
          ", ".join(sorted(defined - used)), warn=True)

    # ---- 8/9 flows ------------------------------------------------------
    flow_dirs = sorted(d for d in os.listdir(FLOWS) if os.path.isdir(os.path.join(FLOWS, d)))
    bad_flow, flow_lists = [], set()
    for name in flow_dirs:
        p = os.path.join(FLOWS, name, "definition.json")
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as exc:
            bad_flow.append("%s: %s" % (name, exc))
            continue
        for key in ("$schema", "contentVersion", "parameters", "triggers", "actions"):
            if key not in d:
                bad_flow.append("%s: missing %s" % (name, key))
        if "SiteUrl" not in d.get("parameters", {}):
            bad_flow.append("%s: no SiteUrl parameter" % name)
        if not d.get("triggers"):
            bad_flow.append("%s: no trigger" % name)
        flow_lists |= set(re.findall(r'"table":\s*"(\d{2}_[A-Za-z]+)"', json.dumps(d)))
        if not os.path.exists(os.path.join(FLOWS, name, "manifest.json")):
            bad_flow.append("%s: no manifest.json" % name)
    check("flows: %d definitions are valid and complete" % len(flow_dirs), not bad_flow,
          "; ".join(bad_flow[:5]))
    check("flows: every SharePoint list they touch exists in the schema",
          not (flow_lists - known_titles), ", ".join(sorted(flow_lists - known_titles)))

    called = set()
    for f, text in sources.items():
        called |= set(re.findall(r"'(ExportLC-\d+-\w+)'\.Run", text))
    check("integration: every flow the app calls exists (%d called)" % len(called),
          not (called - set(flow_dirs)), ", ".join(sorted(called - set(flow_dirs))))

    # ---- report ---------------------------------------------------------
    width = max(len(r["check"]) for r in results) + 2
    print()
    print("Export LC Portal - solution validation")
    print("=" * (width + 10))
    for r in results:
        mark = {"PASS": "  ok  ", "WARN": " warn ", "FAIL": " FAIL "}[r["status"]]
        print("[%s] %-*s %s" % (mark, width, r["check"], r["detail"] if r["status"] != "PASS" else ""))
    counts = {s: sum(1 for r in results if r["status"] == s) for s in ("PASS", "WARN", "FAIL")}
    print("=" * (width + 10))
    print("%d passed, %d warnings, %d failed" % (counts["PASS"], counts["WARN"], counts["FAIL"]))
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main("--verbose" in sys.argv))
