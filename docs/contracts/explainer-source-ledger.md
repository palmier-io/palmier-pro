# Source and claim ledger

Edit plans accept `sourceLedger` containing supplied research. This is not a web researcher, license certificate, or fact-checking model. A `reviewed` status records an explicit review assertion; the app validates structure, revision consistency, and references, not the factual truth of a passage.

## Records

- Sources: stable `sourceId`, title, author/organization, exactly one HTTPS `url` or supplied `documentReference`, optional publication date, required access date. Dates use valid `YYYY-MM-DD`; unknown publication dates are omitted, not guessed.
- Claims: stable `claimId`, `kind` (`statement`, `quantity`, `location`), exact statement, supporting evidence, and status (`unresolved`, `reviewed`). Each evidence record references an existing source and preserves its exact supporting passage.
- Quantities also require a finite value and explicit unit. Other claim kinds cannot carry numeric fields. The ledger does not guess unit conversions or interpret prose as a numeric validation rule.
- Chapter and shot `claimIds` link their factual content to the ledger. Factual evidence is independent of footage license/credit metadata.

Create or replace this ledger through `plan_edit`. Unknown fields, duplicate IDs/references, missing passages, invalid dates, and missing/broken claim references fail before mutation. Existing package snapshots persist it inside `plans.json`; malformed saved artifacts remain unreadable rather than being used as trusted research.

## Corrections and review

Changing a reviewed statement, value, unit, passage, or supporting source invalidates its reviewed status. Update receipts include `invalidatedClaimIds` and affected `sectionIds`/`shotIds`. Repeating a content update does not accidentally approve invalidated research. `apply_plan` blocks assembly when any referenced claim remains unresolved.

Read the current plan and check the revised evidence. Explicitly confirm selected claims with:

```json
{
  "action": "review_claims",
  "planId": "plan-id-from-receipt",
  "claimIds": ["claim-id-from-ledger"],
  "ledgerRevision": "sourceLedgerRevision-from-reviewed-receipt"
}
```

Review is bound to the exact supporting-content revision. A stale revision is refused. Repeating review on the same revision is a no-op. Content updates and explicit reviews are distinct undoable intents; failures and no-ops add no undo entries.

## Remaining production bindings

The current ledger provides chapter/shot and script-beat factual links and dependency receipts, including scenes linked to factual beats. Semantic chart/map consumers, final-output factual checking, and storyboard review remain later roadmap layers. A successful ledger test does not prove every fact in a rendered film was sourced or visually correct.

Manual UI confirmation remains: on an isolated project, review a revised claim through MCP, confirm the Undo menu shows localized “Review Claims,” then undo and confirm the prior research-review state returns. No storyboard UI is present yet.
