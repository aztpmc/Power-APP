# Power Fx patterns and delegation

The single question that decides whether this portal survives contact with 5,000 LCs is:
**does the query run on the server, or does Power Apps pull rows down and filter them
locally?** Local filtering stops at the row limit (default 500, max 2,000) and returns a
wrong answer with no error. This document records how every query here stays server-side.

## What SharePoint delegates

| Delegable | Not delegable |
|---|---|
| `Filter` with `=`, `<>`, `<`, `<=`, `>`, `>=` | `in` over a list of values |
| `StartsWith(column, value)` | `Search()` across many columns (partially) |
| `And` / `Or` / `Not` of the above | `CountRows`, `Sum`, `Average`, `Max`, `Min` |
| `SortByColumns` on **indexed** columns | Sorting on unindexed columns |
| `LookUp` on indexed columns | Lookup column `.Value` comparisons |
| `FirstN` / `LastN` for paging | Person column comparisons |

Three consequences shape the whole app.

## Pattern 1 — optional filters with `StartsWith`

The register has six optional text filters. The naive form is not delegable:

```
// WRONG - the || with a non-column boolean cannot become OData
Filter('01_ExportLCs', IsBlank(f.Customer) || CustomerName = f.Customer)
```

`StartsWith(x, "")` is true for every row, so an empty filter box matches everything and
the predicate still folds into the query:

```
Filter('01_ExportLCs',
    IsClosed = false,
    StartsWith(CustomerName, f.Customer),     // "" matches all
    StartsWith(IssuingBankName, f.Bank),
    StartsWith(CurrencyCode, f.Currency),
    StartsWith(ResponsibleOfficerEmail, f.Officer)
)
```

The trade is that matching is prefix-based rather than "contains". That is a deliberate,
visible limitation — the search screen says so in its empty state — and it is much better
than a "contains" search that silently stops at 2,000 rows.

## Pattern 2 — optional ranges with sentinels

There is no OData way to say "ignore this predicate", but there is a way to say
"`<= 2999-12-31`":

```
DateFloor    = Date(1900, 1, 1);
DateCeiling  = Date(2999, 12, 31);
AmountCeiling = 999999999999;

Filter('01_ExportLCs',
    LCAmount >= Coalesce(f.AmountFrom, 0),
    LCAmount <= Coalesce(f.AmountTo, AmountCeiling),
    ExpiryDate >= Coalesce(f.ExpiryFrom, DateFloor),
    ExpiryDate <= Coalesce(f.ExpiryTo, DateCeiling)
)
```

## Pattern 3 — a stored flag instead of an `in` list

"Pending action" means status in Received, Under Review or Discrepancy — **or** open
discrepancies — **or** missing documents. `in` is not delegable and the `or` chain across
four columns is fragile.

`01_ExportLCs.RequiresAction` is an indexed boolean, written by the app on save and
recomputed hourly by `ExportLC-11`. The drill-through becomes one equality.

The same reasoning gives `IsClosed`, `IsSettled`, `IsOpen`, `IsShipped`. Each is a stored
boolean that replaces a non-delegable predicate, and each is the first filter in the
queries that use it.

## Pattern 4 — one filter record, one query

Every criterion the register understands lives in one record, `gblFilter`. Presets do not
branch the query; they set fields in that record:

```
PresetFilter(preset: Text, mineOnly: Boolean): Record =
    With({ base: Patch(DefaultRegisterFilter, { Preset: preset, ... }) },
        Switch(preset,
            "EXPIRING_SOON", Patch(base, { ExpiryFrom: Today0, ExpiryTo: DateExpirySoon }),
            "SHIPMENT_SOON", Patch(base, { ShipFrom: Today0, ShipTo: DateShipSoon }),
            ...
        )
    );
```

Three things follow. The register runs exactly one `Filter` no matter how the user got
there. "Clear all filters" is a single `Set`. And a dashboard KPI card and a register
preset chip with the same name **cannot disagree**, because both call `PresetFilter`.

The one place a branch is unavoidable is `IncludeClosed`: it branches the whole `Filter`
into two complete delegable arms rather than nesting one `Filter` inside another, which
would not delegate.

## Pattern 5 — aggregates belong in a flow

`CountRows` and `Sum` are not delegable. The dashboard therefore reads sixteen rows from
`29_DashboardMetrics`, computed server-side by `ExportLC-11-RecomputeDashboardMetrics`.

The screen shows when they were computed and marks itself stale after 90 minutes. A KPI
with no timestamp is a KPI nobody trusts; a KPI capped at the row limit is worse, because
it looks fine.

Client-side `Sum` is still used in two safe places: over `galModule.AllItems` (the page
just fetched, at most 50 rows) for a page total, and over `colChecklist` (a few dozen rows
per LC). Both are explicitly bounded.

## Pattern 6 — named formulas and user-defined functions instead of `OnStart`

Named formulas are lazy and recompute only when their inputs change. Assignments in
`OnStart` all run before the first screen appears.

`App.Formulas` holds ~40 theme tokens, the config accessors, the role booleans, the
formatting helpers and every reusable query. `OnStart` does only what must be imperative:
eight `ClearCollect` calls over small master lists inside one `Concurrent`, plus the user's
role and the initial navigation state.

The four config accessors are user-defined functions, because a named formula cannot take
a parameter:

```
CfgN(key: Text, fallback: Number): Number =
    Coalesce(Value(LookUp(colConfig, Title = key).ConfigValue), fallback);
```

**If your tenant does not have user-defined functions enabled** (Settings → Updates →
"User-defined functions"), replace each call with the inline `LookUp`:

```
// CfgN("DashboardExpiringSoonDays", 30)  becomes
Coalesce(Value(LookUp(colConfig, Title = "DashboardExpiringSoonDays").ConfigValue), 30)
```

Everything else in the app works unchanged.

## Pattern 7 — validation as data

Each form has one hidden label whose `Text` is a `Concat` over a filtered table of rules:

```
Concat(
    Filter(
        Table(
            { M: "LC amount cannot be negative.", F: Coalesce(gblDraft.LCAmount, 0) < 0 },
            { M: "Latest shipment date cannot be after LC expiry...", F: ... },
            ...
        ),
        F
    ),
    M, Char(10)
)
```

Save is disabled while that text is non-empty. Adding a rule is one row. Every control on
the screen references one evaluation rather than each re-deriving the rule set.

## Pattern 8 — the transition gate

Section 35 of the brief — controlled workflow transitions — is one function:

```
CanTransition(entity: Text, fromStatus: Text, toStatus: Text): Boolean =
    fromStatus = toStatus ||
    Trim(toStatus) in ForAll(
        Split(Coalesce(StatusRow(entity, fromStatus).AllowedNextStatuses, ""), ";") As s,
        { Value: Trim(s.Value) }
    ).Value;
```

The transitions themselves are rows in `16_StatusMaster` (83 of them across 9 entities).
Applied in two places: the status dropdown only offers legal targets, and a validation
rule blocks the save anyway. The dropdown is the courtesy; the validation rule is the
control.

`TransitionBlockReason` produces the message, which names the allowed next statuses rather
than just refusing.

## Pattern 9 — audit as a `ForAll` over changed fields

```
ForAll(
    Filter(
        Table(
            { F: "LCAmount",   O: Text(gblOriginal.LCAmount),   N: Text(gblDraft.LCAmount) },
            { F: "ExpiryDate", O: DateShort(gblOriginal.ExpiryDate), N: DateShort(gblDraft.ExpiryDate) },
            ...
        ),
        O <> N
    ) As chg,
    Patch('10_AuditLog', Defaults('10_AuditLog'), { ..., CorrelationId: gblCorrelation, ... })
)
```

One row per changed field, all sharing one `CorrelationId` (a GUID per save), so a
six-field edit reads as one transaction rather than six unrelated events.
`IsCriticalField` is decided by membership of the configurable `CriticalAuditFields` list,
and `PartitionKey` is `yyyy-mm` so audit queries stay indexed as history grows.

## Anti-patterns deliberately avoided

| Not done | Why |
|---|---|
| `ClearCollect(colLCs, '01_ExportLCs')` | Pulls at most 2,000 rows and then lies. Every transactional query here is a live delegable `Filter`. |
| SharePoint lookup columns | Not delegable in Power Apps. Denormalised indexed text and number columns instead. |
| Calculated columns for money | Cannot be indexed, cannot be sorted server-side. Stored and maintained instead. |
| `Search()` over the register | Partially delegable, unpredictable. `StartsWith` across four indexed columns instead. |
| Sorting on an unindexed column | The register's sort picker offers indexed columns only. |
| Deleting master data | Deactivated instead, so historical records keep resolving. |
| Nested `Filter(Filter(...))` | Breaks delegation. The `IncludeClosed` branch duplicates the whole `Filter` for this reason. |

## Performance budget

| Screen | Server calls on open | Rows fetched |
|---|---|---|
| Dashboard | 3 | 16 metrics + 25 LCs + 30 audit rows |
| LC register | 1 | 50 (one page) |
| LC workspace | 3 | 1 LC + checklist + the active tab |
| Module register | 1 | 50 |
| Global search | 6 | 20 per entity |
| App start | 8 concurrent | master data, all small lists |
