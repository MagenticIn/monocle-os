# Migrations

Changes to the schema that cannot be made in this repository, because
`../schema.sql` is **generated** from `model/*.mjs` in the private build repo —
`../notes.md`: *"The source of truth. Edit this, then rebuild."* Hand-editing the
generated file would be reverted by the next `node db/build.mjs`.

Each migration therefore carries a **MODEL** note against every fix, saying what
has to change in the model so the next rebuild keeps it. Until that is done, a
freshly built database and a migrated one differ — which is the normal state
between a migration landing and the model catching up, not a mistake.

`../reporting.sql` is hand-written, so changes to the reporting views are applied
there directly and appear in a migration only when an existing database needs
them too.

| | |
|---|---|
| `001-correctness-fixes.sql` | Ten fixes for things that are wrong about a live loan today |
| `001-correctness-fixes.rollback.sql` | The undo for it |

---

## 001 · correctness fixes

**What it is for.** Ten defects that make a row *false* about the one process
Spreo runs, as distinct from a capability that is merely *absent*. Decision
**D-016** keeps the workflow configuration engine out of Phase 1, and nothing
here builds any part of it.

Two candidates were rejected on that test and are not in this file: a second
labelled route between one pair of statuses (nothing in the process needs one —
the rework loop's two legs are already two different pairs), and multi-approver
approvals (Construction Management approving alongside Credit is a role the
17 September reconciliation *adds*, so it is an absent capability, and the budget
sign-off never creates an `approvals` row at all — it lands on
`vendor_orders.internally_approved_at`).

**The one that matters most.** `reporting.outstanding_items` ended with
`AND NOT (lr.third_party_state = 'approved')`. That column is NULL on every item
that has not reached third-party review, `NOT (NULL = 'approved')` is NULL, and a
NULL predicate drops the row — so the view returned **nothing at all** for an
ordinary loan. The recurring Needs List email (**D-015**) is built from it, so the
Mon/Wed/Fri message would have gone out empty while the borrower still owed
everything on the list.

**What it changes.**

| # | Fix | Where |
|---|---|---|
| 1 | An internal item can no longer be made borrower-facing — composite foreign key, not a convention | `loan_requirements`, `requirement_types` |
| 2 | Who satisfied a Needs List item, and when | `loan_requirements` |
| 3 | Fire-once on the six vendor triggers becomes a unique index, with a re-arm when a vendor moves a promised date | `trigger_firings` |
| 4 | Who internally approved the budget and the appraisal, and in which role | `vendor_orders` |
| 5 | A recorded reply now says which move it caused | `status_transitions` |
| 6 | A status rendered outside its own stage is disambiguated by stage and machine key | `reporting.cycle_times` |
| 7 | The decision button in an approval email has somewhere to land | `approval_decision_tokens` (new) |
| 8 | The outbox keys idempotency on an occurrence, so the second send-back in a review loop is a new send rather than a collision | `integration_outbox` |
| 9 | `outstanding_items` returned nothing for an ordinary loan | `reporting.sql` |
| 10 | A restored Needs List item never came back | `reporting.sql` |

**Verified, not asserted.** Against a database loaded from `schema.sql` and
`reporting.sql` (59 tables, 157 foreign keys, 5 views — matching `../notes.md`):

```
140 statements                          ALL STATEMENTS APPLIED

BEFORE (as shipped)   outstanding items visible: 0 of 3   (none)
AFTER  (migrated)     outstanding items visible: 3 of 3   Credit Report, Driver's Licence, PSA

internal item made borrower-facing      refused by the database
unique index on trigger_firings         uq_trigger_firings_occasion
columns named due_date / overdue / sla  0

baseline    59 tables, 877 constraints, 277 indexes
migrated    60 tables, 920 constraints, 296 indexes
rolled back 59 tables, 877 constraints, 277 indexes
```

The round trip is exact: no constraint or index is left behind, and none fails to
come back.

**D-014 is intact.** No due date, no overdue state, no escalation and no
elapsed-time comparison is introduced anywhere. Days in status remains the only
timing signal, and the trigger re-arm in fix 3 keys on a vendor changing a
promised date — an event, never a deadline.

**Safe on a live database.** Every added column is nullable or defaulted, every
new constraint is added `NOT VALID` and validated after its backfill, and nothing
is deleted — rows are retired, superseded or stamped.

**Order.** Run `001-correctness-fixes.sql` on the primary. The `reporting` schema
is served from the read replica and arrives there by replication; the two view
repairs are already in `../reporting.sql` for fresh builds.
