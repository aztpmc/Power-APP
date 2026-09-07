# Testing

## What was actually tested, and what was not

Be clear about the boundary. I have no access to a Microsoft 365 tenant in this session:
no SharePoint site, no Power Apps Studio, no Power Automate. So **nothing here has been
run against a live environment.** No list was created, no formula was evaluated by the
Power Fx engine, no flow was executed.

What *was* done is everything that can be verified offline, and it was done properly
rather than by eye:

| Verified mechanically | How |
|---|---|
| SharePoint schema is well formed and inside platform limits | `tools/validate_solution.py` |
| Master data parses and its cross-references resolve | same |
| Status choices match the status master for all 9 entities | same |
| No workflow transition points at a non-existent status | same |
| All 28 Power Apps source files are valid YAML | same |
| Every list and library referenced in Power Fx exists | same |
| 237 typed record-variable field references resolve to real columns | same |
| Component property references match their declarations | same |
| Every `Navigate()` target exists; no screen is unreachable | same |
| Every component used is defined; none is orphaned | same |
| All 14 flow definitions are valid and structurally complete | same |
| Every SharePoint list the flows touch exists | same |
| Every flow the app calls exists | same |
| All four PowerShell scripts parse | PowerShell 7.4 AST parser |
| The migration extractor runs and produces correct output | executed against the real workbooks |

## Validation run

```
[  ok  ] schema: file is valid JSON                                          
[  ok  ] schema: object titles are unique                                    
[  ok  ] schema: titles within SharePoint's length limit                     
[  ok  ] schema: all field types are supported                               
[  ok  ] schema: no duplicate field names within an object                   
[  ok  ] schema: indexed columns within SharePoint's limit of 20             
[  ok  ] schema: 550 columns across 34 objects                               
[  ok  ] schema: choice fields have choices and valid defaults               
[  ok  ] master data: 14 CSVs parse with consistent column counts            
[  ok  ] master data: every CSV column exists on its list                    
[  ok  ] workflow: status choices match 16_StatusMaster for all 9 entities   
[  ok  ] workflow: no transition points at a status that does not exist      
[  ok  ] workflow: 15 terminal states defined                                
[  ok  ] master data: checklist templates reference known document types     
[  ok  ] master data: document types route to libraries that exist           
[  ok  ] master data: checklist country rules reference known countries      
[  ok  ] app: 28 source files are valid YAML                                 
[  ok  ] app: every list referenced in Power Fx exists in the schema         
[  ok  ] app: every library referenced exists (5 referenced)                 
[  ok  ] app: 237 typed record-variable field references all resolve         
[  ok  ] app: component property references match their declarations         
[  ok  ] app: every Navigate() target is a screen that exists (26 screens)   
[  ok  ] app: no screen is unreachable                                       
[  ok  ] app: every component used is defined (9 components)                 
[  ok  ] app: no component is defined but never used                         
[  ok  ] flows: 14 definitions are valid and complete                        
[  ok  ] flows: every SharePoint list they touch exists in the schema        
[  ok  ] integration: every flow the app calls exists (4 called)             
```

`28 passed, 0 warnings, 0 failed`.

### The validator is not vacuous

A check suite that passes because it checks nothing is worse than no suite. Two deliberate
typos were introduced and the run repeated:

| Injected fault | Caught |
|---|---|
| `gblCurrentLC.OutstandingAmount` → `gblCurrentLC.OutstandingAmnt` | yes — named the file and the token |
| `cmpStageTracker.CurrentStage` → `cmpStageTracker.CurrntStage` | yes — named the component and the property |

Both were reverted; the suite returns to 28 passed, 0 failed.

Run it yourself: `python3 tools/validate_solution.py`

## The migration extractor, run for real

Executed against the two workbooks in `legacy/`:

```
read LC Export.xlsx: 6 sheets
read LC Master Export 2026.xlsx: 11 sheets

LCs        : 20
Invoices   : 60
Customers  : 127
Banks      : 28
Findings   : INFO=3, REJECT=4, WARNING=19
LC value   : 10,931,242.80   Invoice value: 11,219,391.75
```

Every finding was traced back to the source cells and confirmed genuine — see
`docs/10-source-data-analysis.md`. None is a parser artefact.

## Manual test plan

This must be worked through after deployment. It is the part I could not do.

### Provisioning

| # | Test | Expected |
|---|---|---|
| P1 | `Inspect-Environment.ps1` on the target site | Inventory CSV written; site unchanged |
| P2 | `Provision-ExportLCPortal.ps1 -WhatIf` | Full plan printed; nothing created |
| P3 | `Provision-ExportLCPortal.ps1` | 29 lists, 5 libraries, 550 columns; report shows 0 failures |
| P4 | Run it a second time | Every object reported `Exists`; nothing recreated; still 0 failures |
| P5 | `Import-MasterData.ps1` twice | Second run reports everything `Unchanged` |
| P6 | `Set-Permissions.ps1` | 5 groups, 2 permission levels; verification table matches expectations |
| P7 | As an OFFICER, try to delete a list item in the browser | Refused |
| P8 | As an OFFICER, try to edit a row in `10_AuditLog` | Refused |

### LC lifecycle

| # | Test | Expected |
|---|---|---|
| L1 | Register an LC with valid data | Saved; internal ID matches `LC-{YYYY}-{####}`; checklist materialised; one audit row |
| L2 | Register with latest shipment date after expiry | Save disabled; message explains why |
| L3 | Register with a duplicate LC number | Save disabled; message names the clash |
| L4 | Register with a negative amount | Save disabled |
| L5 | Edit an LC, change amount and expiry | Two audit rows sharing one correlation id, both flagged critical |
| L6 | Try to move an LC from Draft straight to Paid | Not offered in the dropdown; blocked by validation if forced |
| L7 | Reduce the LC amount below what is drawn | Blocked, with a prompt to record an amendment |
| L8 | Open the workspace on an LC expiring in under 30 days | Expiry warning banner; expiry shown in the urgency colour |

### Children and rollups

| # | Test | Expected |
|---|---|---|
| C1 | Add an invoice | LC `UtilizedAmount` and `OutstandingAmount` update |
| C2 | Add a duplicate invoice number under the same LC | Blocked |
| C3 | Add an invoice that overdraws the LC | Blocked, prompting to check for a missing amendment |
| C4 | Record a shipment dated after the LC's latest shipment date | Blocked, with the reason |
| C5 | Record a discrepancy | LC `OpenDiscrepancyCount` increments; workspace warning appears |
| C6 | Resolve it | Count decrements; warning clears |
| C7 | Record an amendment, accept it, apply it | LC values move; before/after trail correct; one audit row per changed field |
| C8 | Try to apply an amendment that is not Accepted | Button not shown |

### Documents

| # | Test | Expected |
|---|---|---|
| D1 | Upload a Commercial Invoice from a workspace | Lands in `ExportLCInvoices` with metadata; checklist line ticks; `MissingDocumentCount` drops |
| D2 | Upload a Bill of Lading | Lands in `ExportLCShippingDocuments` — routing came from `15_DocumentTypes` |
| D3 | Change a document type's `TargetLibrary`, upload again | Goes to the new library with no code change |
| D4 | Register an LC for a Libyan customer | Checklist includes the legalised invoice, health certificate and free sale certificate |
| D5 | Register one for Oman | Different checklist — country rules applied |

### Flows

| # | Test | Expected |
|---|---|---|
| F1 | Set an LC expiry exactly 7 days out; run `ExportLC-01` | One email, one task, one `26_NotificationLog` row |
| F2 | Run it again immediately | Nothing sent, nothing created |
| F3 | Change `LCExpiryReminderDays` to `10;5`; re-run | Fires on the new offsets only |
| F4 | Clear `EscalationManagerEmail`, run against an unassigned LC | Logged as `Suppressed`, not silently dropped |
| F5 | Leave a discrepancy open past its category window; run `ExportLC-06` | Escalated to level 1; audit row written |
| F6 | Run `ExportLC-11` | All 16 metric rows updated; dashboard freshness stamp moves |
| F7 | Import a workbook with two bad rows | Preview shows them rejected with reasons; nothing in the live register |
| F8 | Commit that batch | Only valid rows written; rejected rows stay staged |

### Roles

| # | Test | Expected |
|---|---|---|
| R1 | Sign in as READONLY | No Register LC button, no Save, Administration refuses |
| R2 | As OFFICER | Can create and edit; cannot reach Administration; cannot commit an import |
| R3 | As MANAGER | Approvals available; can close an LC |
| R4 | As ADMIN | Everything, including master data and import commit |
| R5 | A user with no `17_Users` row | Treated as READONLY; no error |

### Performance

Load-test with realistic volume before go-live — 5,000 LCs, 20,000 invoices.

| # | Test | Target |
|---|---|---|
| X1 | App start | under 3s |
| X2 | Register first page | under 2s |
| X3 | Register filtered by customer | under 2s, correct count |
| X4 | **Register total with 5,000+ LCs** | The count must be right, not capped. This is the single most important test in this document |
| X5 | Workspace open | under 2s |
| X6 | Dashboard | under 2s (reads 16 pre-aggregated rows) |
| X7 | Global search | under 3s |

X4 is the one to be ruthless about. Every delegation decision in
`docs/04-powerfx-patterns.md` exists to make it pass, and a delegation failure does not
raise an error — it just returns a smaller, wrong answer. Seed 5,000 rows, filter to a
subset you can count independently, and check the two numbers agree.
