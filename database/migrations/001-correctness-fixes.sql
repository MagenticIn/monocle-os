-- ===========================================================================
-- Monocle OS · correctness migration 001
--
-- Ten fixes for things that are WRONG about a live loan today, as distinct from
-- capabilities that are merely absent. D-016 keeps the workflow configuration
-- engine out of Phase 1 and nothing here builds any part of it.
--
-- WHY A MIGRATION AND NOT AN EDIT TO schema.sql
-- database/schema.sql is GENERATED from model/*.mjs in the private build repo.
-- Hand-editing it would be reverted by the next `node db/build.mjs`, so every
-- fix carries a MODEL note saying what must change there. database/reporting.sql
-- is hand-written, so the drawer helper and the two view repairs are applied to
-- that file directly; the two fixes that live there are numbered 9 and 10 below
-- and appear here only as a note.
--
-- SAFE ON A DATABASE THAT ALREADY HOLDS LOANS: every added column is nullable or
-- defaulted, every new constraint is added NOT VALID and validated after its
-- backfill, and nothing is deleted.
--
-- D-014 IS INTACT: no due date, no overdue state, no escalation and no
-- elapsed-time comparison is introduced anywhere below.
--
-- Undo: database/migrations/001-correctness-fixes.rollback.sql
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · An internal item can be made borrower-facing by accident
--
-- MODEL: In the private build repo, in the model file that owns the Needs List and document catalogue domain (the one defining requirement_types and loan_requirements), four things must be added so `node db/build.mjs` reproduces this guard instead of erasing it: 1. On loan_requirements, a
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- FIX internal_never_borrower_facing
-- An internal item can be made borrower-facing by accident.
--
-- requirement_types.internal marks the items Spreo pulls itself — credit
-- report, background check, PACER, UCC search, sponsor search, org chart, VOM,
-- Payoff. Today nothing ties loan_requirements.borrower_facing to it, and both
-- borrower_facing columns DEFAULT to true, so a needs rule, a carry-over, a
-- backfill or a hand edit can put an internal item on the borrower's Needs
-- List. This makes "internal items are never shown to the borrower" a database
-- fact, at BOTH levels: the catalogue that decides, and the Needs List row that
-- copies the decision.
--
-- Run order is DDL, then backfill, then VALIDATE. The constraints are added
-- NOT VALID so the DDL half is safe against a database that already holds live
-- loans with wrong rows in it and takes no long scan under lock.
-- ---------------------------------------------------------------------------


-- === 1. The catalogue stops being able to say both things at once ==========
-- This is the source. requirement_types.borrower_facing means "The client sees
-- it on their list" (schema.sql:682), so on an internal item it is a false row
-- today — and because it DEFAULTS to true, seeding an internal type without
-- naming it produces exactly that row.
ALTER TABLE requirement_types
  ADD CONSTRAINT ck_requirement_types_internal_not_borrower_facing
  CHECK (NOT (internal AND borrower_facing))
  NOT VALID;
COMMENT ON CONSTRAINT ck_requirement_types_internal_not_borrower_facing ON requirement_types
  IS 'Internal items are on the list but never shown to the borrower — Spreo pulls these itself.';

-- The parent key the mirror hangs off. id is already the primary key, so
-- (id, internal) is trivially unique on every existing row — this cannot fail.
ALTER TABLE requirement_types
  ADD CONSTRAINT uq_requirement_types_id_internal UNIQUE (id, internal);
COMMENT ON CONSTRAINT uq_requirement_types_id_internal ON requirement_types
  IS 'Lets a Needs List row carry a copy of internal and have the database hold that copy honest.';


-- === 2. The mirror on the Needs List row ==================================
-- DEFAULT false so the ADD is metadata-only on a live table (PostgreSQL 11+;
-- schema.sql targets 15+). The trigger below and the backfill replace that
-- default with the catalogue's own value.
ALTER TABLE loan_requirements
  ADD COLUMN internal boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN loan_requirements.internal IS 'Spreo pulls it itself — credit report, background, PACER, UCC, sponsor search, org chart, VOM, Payoff. Copied from the catalogue and held equal to it by the database; an internal item is never borrower-facing.';


-- === 3. The mirror is derived, never supplied =============================
-- Without this, every writer that does not name the new column — needs-list
-- generation, carry-over, hand-add — is rejected by the composite key below
-- the moment the DDL lands, even when it is already doing the right thing.
-- The trigger fills the column from the catalogue so no application change has
-- to ship in lockstep with the migration. It fires on requirement_type_id only:
-- a hand-written `SET internal = false` is a lie about the catalogue, and the
-- foreign key below is left to reject it out loud. It never touches
-- borrower_facing — that column carries a real per-loan decision for ordinary
-- items, and silently rewriting it would hide the very mistake this fix is for.
CREATE FUNCTION loan_requirements_set_internal() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_internal boolean;
BEGIN
  SELECT rt.internal INTO v_internal
    FROM requirement_types rt
   WHERE rt.id = NEW.requirement_type_id;
  -- No catalogue row: leave the value alone so the existing
  -- fk_loan_requirements_requirement_type_id reports the real problem.
  IF FOUND THEN
    NEW.internal := v_internal;
  END IF;
  RETURN NEW;
END $fn$;
COMMENT ON FUNCTION loan_requirements_set_internal() IS 'Fills loan_requirements.internal from the document catalogue, so needs-list generation, carry-over and hand-add never have to name it.';

CREATE TRIGGER trg_loan_requirements_set_internal
  BEFORE INSERT OR UPDATE OF requirement_type_id ON loan_requirements
  FOR EACH ROW EXECUTE FUNCTION loan_requirements_set_internal();


-- === 4. The mirror cannot lie ============================================
-- ON UPDATE CASCADE so that re-classifying a catalogue item carries down to
-- every live Needs List in one statement instead of leaving the copies stale.
-- No delete action is named — nothing is ever deleted; a catalogue item is
-- retired with requirement_types.active. No new index: the parent side is
-- served by uq_requirement_types_id_internal and the child side by the existing
-- ix_loan_requirements_requirement_type_id, whose leading column is the same.
-- Both referencing columns are NOT NULL, so MATCH SIMPLE has no escape hatch.
ALTER TABLE loan_requirements
  ADD CONSTRAINT fk_loan_requirements_type_internal
  FOREIGN KEY (requirement_type_id, internal)
  REFERENCES requirement_types (id, internal)
  ON UPDATE CASCADE
  NOT VALID;
COMMENT ON CONSTRAINT fk_loan_requirements_type_internal ON loan_requirements
  IS 'loan_requirements.internal must equal requirement_types.internal for the item it points at.';


-- === 5. The rule itself ===================================================
ALTER TABLE loan_requirements
  ADD CONSTRAINT ck_loan_requirements_internal_not_borrower_facing
  CHECK (NOT (internal AND borrower_facing))
  NOT VALID;
COMMENT ON CONSTRAINT ck_loan_requirements_internal_not_borrower_facing ON loan_requirements
  IS 'Internal items are on the list but never shown to the borrower — Spreo pulls these itself.';


-- ---------------------------------------------------------------------------
-- BACKFILL. Runs after the DDL above and before the VALIDATE statements.
--
-- WHAT IS BACKFILLED, AND WHY IT IS CORRECT.
--
--   (a) requirement_types.borrower_facing is forced to false wherever the
--       catalogue says internal. Correct because the record admits no other
--       reading — "Internal items are on the list but never shown to the
--       borrower… Spreo pulls these itself" (00-what-we-are-building.md:179)
--       — and because the column means "The client sees it on their list"
--       (schema.sql:682). false is the only value that can be true about such
--       a row. This is the source: leaving it alone would make the ordinary
--       generator, which copies the catalogue's own borrower_facing into a new
--       socket, fail on every internal item.
--
--   (b) loan_requirements.internal is copied down from the catalogue,
--       replacing the DEFAULT false the ADD COLUMN gave every existing row.
--       Correct because requirement_types is the thing that decides whether
--       Spreo pulls an item itself, so its value is by definition the true
--       one; the mirror exists only to let the database enforce it.
--
--   (c) where the catalogue says internal, loan_requirements.borrower_facing
--       is forced to false in the SAME statement, so the row never exists in a
--       half-corrected state the new CHECK would reject. THIS IS WHAT HAPPENS
--       TO A ROW THAT IS ALREADY WRONG: it is not deleted and it is not left
--       alone. It stays on the Needs List, keeps its files, its reviews and its
--       history, and is corrected to the catalogue's answer, with what it said
--       before kept in the events row stamped first. Rows in the drawer
--       (not_needed_at set), carried-over rows (origin = 'carry_over') and rows
--       already released to the client are all corrected the same way — all
--       three verified against a seeded live database.
--
-- Rows whose type is not internal are untouched: an ordinary item such as Bank
-- Statements keeps borrower_facing = true, and a CM can still hide one on a
-- single loan.
-- ---------------------------------------------------------------------------

-- Stamp first, correct second, so the audit trail keeps what the row said.
INSERT INTO events (actor_kind, entity_type, entity_id, action, before, after, note)
SELECT 'system', 'requirement_types', rt.id::text, 'internal_item_withdrawn_from_client_list',
       jsonb_build_object('borrower_facing', rt.borrower_facing),
       jsonb_build_object('borrower_facing', false),
       'Migration: ' || rt.key || ' is internal — Spreo pulls it itself — so it is never shown to the borrower.'
FROM requirement_types rt
WHERE rt.internal AND rt.borrower_facing;

UPDATE requirement_types
   SET borrower_facing = false
 WHERE internal AND borrower_facing;

INSERT INTO events (actor_kind, loan_id, entity_type, entity_id, action, before, after, note)
SELECT 'system', lr.loan_id, 'loan_requirements', lr.id::text, 'internal_item_withdrawn_from_client_list',
       jsonb_build_object('borrower_facing', lr.borrower_facing),
       jsonb_build_object('internal', true, 'borrower_facing', false),
       'Migration: requirement type ' || rt.key || ' is internal — Spreo pulls it itself — so it is never shown to the borrower.'
FROM loan_requirements lr
JOIN requirement_types rt ON rt.id = lr.requirement_type_id
WHERE rt.internal AND lr.borrower_facing;

UPDATE loan_requirements lr
   SET internal        = rt.internal,
       borrower_facing = CASE WHEN rt.internal THEN false ELSE lr.borrower_facing END,
       updated_at      = now()
  FROM requirement_types rt
 WHERE rt.id = lr.requirement_type_id
   AND (lr.internal IS DISTINCT FROM rt.internal
        OR (rt.internal AND lr.borrower_facing));

-- Every existing row now satisfies all three. Turn them on for good. The
-- migration is not finished until these have run.
ALTER TABLE requirement_types VALIDATE CONSTRAINT ck_requirement_types_internal_not_borrower_facing;
ALTER TABLE loan_requirements VALIDATE CONSTRAINT fk_loan_requirements_type_internal;
ALTER TABLE loan_requirements VALIDATE CONSTRAINT ck_loan_requirements_internal_not_borrower_facing;


-- ---------------------------------------------------------------------------
--   1. requirement_types: a table-level CHECK NOT (internal AND borrower_facing).
--   2. requirement_types: a NAMED table-level UNIQUE over (id, internal).
--      db/build.mjs already emits multi-column table-level UNIQUE — schema.sql
--      has ten, e.g. `UNIQUE (loan_id, party_id, role)` at line 87 — but emits
--      them inline and UNNAMED. The gap is the name, not the capability, and
--      the name is what COMMENT ON CONSTRAINT and the rollback depend on.
--   3. loan_requirements: column `internal`, boolean NOT NULL default false,
--      written by the same process step that writes requirement_type_id.
--   4. loan_requirements: a composite FK (requirement_type_id, internal) ->
--      requirement_types (id, internal) with ON UPDATE CASCADE, alongside the
--      existing single-column FK. `ON UPDATE`/`ON DELETE` appear nowhere in
--      schema.sql, and there is no composite FK, so the emitter needs both.
--      The FK validator must accept a composite target and confirm the parent
--      columns carry a matching unique key.
--   5. loan_requirements: a table-level CHECK NOT (internal AND borrower_facing).
--      Every CHECK in schema.sql today is inline on a single column.
--   6. The trigger and its function.
-- Until those emitters exist, add a build-time assertion that the generated
-- schema.sql still contains ck_loan_requirements_internal_not_borrower_facing.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FIX internal_never_borrower_facing — backfill. Runs after the DDL above.
-- ---------------------------------------------------------------------------

-- Stamp first, correct second, so the audit trail keeps what the row said.
-- Nothing is deleted: the item stays on the Needs List, it just stops being
-- shown to the client, which is what the catalogue always said it was.
INSERT INTO events (actor_kind, loan_id, entity_type, entity_id, action, before, after, note)
SELECT 'system', lr.loan_id, 'loan_requirements', lr.id::text, 'internal_item_withdrawn_from_client_list',
       jsonb_build_object('internal', lr.internal, 'borrower_facing', lr.borrower_facing),
       jsonb_build_object('internal', true,        'borrower_facing', false),
       'Migration: requirement type ' || rt.key || ' is internal — Spreo pulls it itself — so it is never shown to the borrower.'
FROM loan_requirements lr
JOIN requirement_types rt ON rt.id = lr.requirement_type_id
WHERE rt.internal AND lr.borrower_facing;

-- WHAT IS BACKFILLED, AND WHY IT IS CORRECT.
-- Two things, in ONE statement so the row never exists in a half-corrected
-- state that the new CHECK would reject:
--   (a) internal is copied down from requirement_types, replacing the DEFAULT
--       false the ADD COLUMN gave every existing row. Correct because
--       requirement_types is the catalogue — it is the thing that decides
--       whether Spreo pulls an item itself — so its value is by definition the
--       true one, and the mirror exists only to let the database enforce it.
--   (b) where the catalogue says internal, borrower_facing is forced to false
--       at the same instant. THIS IS WHAT HAPPENS TO A ROW THAT IS ALREADY
--       WRONG: it is not deleted and it is not left alone. It stays on the
--       Needs List, keeps its files, its reviews and its history, and is
--       corrected to the catalogue's answer, with its old value kept in the
--       events row stamped above. Correct because the record admits no other
--       reading — "Internal items are on the list but never shown to the
--       borrower… Spreo pulls these itself" (00-what-we-are-building.md:179).
--       false is the only value that can be true about such a row.
-- Rows whose type is not internal are untouched: the WHERE clause skips them
-- once internal already matches, so an ordinary borrower-facing item such as
-- Bank Statements keeps borrower_facing = true.
UPDATE loan_requirements lr
   SET internal        = rt.internal,
       borrower_facing = CASE WHEN rt.internal THEN false ELSE lr.borrower_facing END,
       updated_at      = now()
  FROM requirement_types rt
 WHERE rt.id = lr.requirement_type_id
   AND (lr.internal IS DISTINCT FROM rt.internal
        OR (rt.internal AND lr.borrower_facing));

-- Every existing row now satisfies both. Turn them on for good.
ALTER TABLE loan_requirements VALIDATE CONSTRAINT fk_loan_requirements_type_internal;
ALTER TABLE loan_requirements VALIDATE CONSTRAINT ck_loan_requirements_internal_not_borrower_facing;


-- ---------------------------------------------------------------------------
-- 2 · Record who satisfied a Needs List item, and when
--
-- MODEL: In the private build repo, the model file that defines `loan_requirements` (the Needs List / documents domain, the one that also defines `requirement_types`, `document_files` and `document_reviews`) must gain the three columns, or the next `node db/build.mjs` will regenerate sche
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- FIX satisfied-by · Who satisfied a Needs List item, and when
--
-- loan_requirements stamps who retired an item (not_needed_by / not_needed_at)
-- but nothing stamps who satisfied one. closing_checklist_items -- the table the
-- configuration design folds into loan_requirements -- already carries
-- completed_at / completed_by, so the fold would lose a fact the schema records
-- today. Add the same fact to the Needs List, with the review semantics the
-- Needs List actually has.
--
-- No due date, no lateness, no escalation: satisfied_at is a stamp, compared
-- with nothing but another stamp. D-014 holds.
-- ---------------------------------------------------------------------------

ALTER TABLE loan_requirements ADD COLUMN satisfied_at timestamptz;
ALTER TABLE loan_requirements ADD COLUMN satisfied_by uuid;
ALTER TABLE loan_requirements ADD COLUMN satisfied_by_party_id uuid;

COMMENT ON COLUMN loan_requirements.satisfied_at IS 'When the item stopped being outstanding — the moment the last review layer that applies to it approved it. Which layer that is depends on the item: the underwriter once he has spoken, Spreo for an internal item Spreo pulls itself, third-party review for everything else. Not when the file arrived (document_files.uploaded_at) and not when the socket turned Received (submission_state): a file can land on Monday and clear on Friday. Set from the reviewed_at of the approval that cleared the item; set back to null if the item reopens. A stamp, never a deadline — D-014.';
COMMENT ON COLUMN loan_requirements.satisfied_by IS 'The Spreo staff member whose approval satisfied the item, when the last word was Spreo''s or the underwriter''s. Null when a third party cleared it — see satisfied_by_party_id. This is the column that answers "it only took me a day, it took you four".';
COMMENT ON COLUMN loan_requirements.satisfied_by_party_id IS 'The third-party reviewer — Setpoint or the offshore team — whose approval satisfied the item, when the last word was theirs. Third-party reviewers are parties, never users, exactly as in document_reviews.reviewed_by_party_id.';

-- WHAT SETS THEM, precisely. One write path, in the review handler, and nowhere
-- else. The deciding layer for an item is the SAME CASE that
-- reporting.outstanding_items uses to drop it off the client's list
-- (database/reporting.sql:114-121), and the two must never disagree:
--     underwriter_state IS NOT NULL -> the underwriter is final
--     requirement_types.internal    -> Spreo review is final; the item never
--                                     travels to third-party review at all
--     otherwise                     -> third-party review is final
--   * When a document_reviews row is recorded with decision = 'approved' at the
--     item's deciding layer, the handler stamps satisfied_at from that review's
--     reviewed_at and the actor from its reviewed_by_user_id (into satisfied_by)
--     or, when the reviewer was a third party, its reviewed_by_party_id (into
--     satisfied_by_party_id).
--   * Any reopening — a rejection or need_additional at any layer, a replacing
--     file that sends the item back through the gates, or a restore from the
--     drawer — sets all three back to null. The item is outstanding again and
--     the row must not claim otherwise; the previous stamp survives in events
--     and in document_reviews, because nothing is ever deleted.
--   * submission_state is untouched: it still turns 'received' the second a file
--     goes in. satisfied_at is the other end of that interval.
--   * Marking an item not needed is not satisfying it. not_needed_at /
--     not_needed_by keep that meaning; these columns stay null on a drawered
--     item.
-- The rule is deliberately not a CHECK constraint: it depends on
-- requirement_types.internal, which lives on another table.

-- Referential integrity. Both targets are the same tables document_reviews
-- already points at (fk_document_reviews_reviewed_by_user_id,
-- fk_document_reviews_reviewed_by_party_id), so every backfilled value is
-- guaranteed to resolve and neither constraint can fail on an existing row.
ALTER TABLE loan_requirements
  ADD CONSTRAINT fk_loan_requirements_satisfied_by
  FOREIGN KEY (satisfied_by) REFERENCES users (id);
ALTER TABLE loan_requirements
  ADD CONSTRAINT fk_loan_requirements_satisfied_by_party_id
  FOREIGN KEY (satisfied_by_party_id) REFERENCES parties (id);

-- A satisfier cannot be named without the moment. Holds on every existing row:
-- all three columns are null until the backfill, and the backfill only ever
-- writes an actor together with that actor's reviewed_at.
ALTER TABLE loan_requirements
  ADD CONSTRAINT ck_loan_requirements_satisfied_actor_needs_time
  CHECK (satisfied_at IS NOT NULL OR (satisfied_by IS NULL AND satisfied_by_party_id IS NULL));

-- One satisfier, staff or third party, never both — the audit trail has to say
-- which side of the desk the last day belonged to.
ALTER TABLE loan_requirements
  ADD CONSTRAINT ck_loan_requirements_satisfied_one_actor
  CHECK (satisfied_by IS NULL OR satisfied_by_party_id IS NULL);

CREATE INDEX ix_loan_requirements_satisfied_by ON loan_requirements (satisfied_by);
CREATE INDEX ix_loan_requirements_satisfied_by_party_id ON loan_requirements (satisfied_by_party_id);
CREATE INDEX ix_loan_requirements_loan_id_satisfied_at ON loan_requirements (loan_id, satisfied_at);


-- ---------------------------------------------------------------------------
-- BACKFILL
--
-- Safe to run before or after this fix's constraints (verified both orders):
-- every value it writes already satisfies them. Idempotent — the
-- `lr.satisfied_at IS NULL` guard makes a second run a no-op (verified).
--
-- WHAT IS BACKFILLED, AND WHY IT IS CORRECT. Only rows that are unambiguously
-- satisfied on a live loan today are stamped, and only from evidence already in
-- the database — no timestamp is manufactured:
--   * the socket holds a file (submission_state = 'received');
--   * the item is not sitting in the drawer right now. A drawered item was not
--     satisfied, it was removed, and not_needed_by already says by whom. But an
--     item that was drawered and then BROUGHT BACK is live again: the
--     not_needed stamp survives because nothing is ever deleted, so the
--     predicate must read restored_at too, or every restored-then-satisfied
--     item is silently skipped;
--   * its DECIDING LAYER has approved it — the platform's own definition of
--     done, taken verbatim from reporting.outstanding_items so that "satisfied"
--     and "dropped off the client's list" can never disagree. An item Spreo has
--     approved but that is still with Setpoint is NOT satisfied and is left
--     null; an internal item Spreo approved IS satisfied, and will never have a
--     third_party_state at all.
-- The clearing decision is the latest approval recorded AT THAT LAYER, which is
-- by construction the one that finished the item; its reviewed_at becomes
-- satisfied_at and its reviewer becomes the satisfier. Where a review row names
-- both a staff reviewer and a party the staff member wins, so exactly one actor
-- is named and ck_loan_requirements_satisfied_one_actor holds.
--
-- Rows whose clearance predates any document_reviews row keep satisfied_at
-- null. Null reads as "not recorded", which is true; a guessed timestamp would
-- be a lie in an audit trail a capital partner is shown. Every other row is left
-- exactly as it was. Nothing is deleted, no state column is rewritten, and
-- updated_at is deliberately NOT touched: deriving these three columns from
-- evidence already in the database is not a change to the row, and moving
-- updated_at would make every historically satisfied item look as though it
-- changed at migration time.
WITH deciding AS (
  SELECT lr.id AS requirement_id,
         CASE
           WHEN lr.underwriter_state IS NOT NULL THEN 'underwriter'
           WHEN rt.internal                      THEN 'spreo'
           ELSE                                       'third_party'
         END AS layer
  FROM loan_requirements lr
  JOIN requirement_types rt ON rt.id = lr.requirement_type_id
  WHERE lr.satisfied_at IS NULL
    AND lr.submission_state = 'received'
    AND (lr.not_needed_at IS NULL
         OR (lr.restored_at IS NOT NULL AND lr.restored_at > lr.not_needed_at))
    AND CASE
          WHEN lr.underwriter_state IS NOT NULL THEN lr.underwriter_state = 'approved'
          WHEN rt.internal                      THEN lr.spreo_state       = 'approved'
          ELSE                                       lr.third_party_state = 'approved'
        END
),
clearing AS (
  SELECT DISTINCT ON (dr.requirement_id)
         dr.requirement_id, dr.reviewed_at, dr.reviewed_by_user_id, dr.reviewed_by_party_id
  FROM document_reviews dr
  JOIN deciding d ON d.requirement_id = dr.requirement_id AND d.layer = dr.layer
  WHERE dr.decision = 'approved'
  ORDER BY dr.requirement_id, dr.reviewed_at DESC, dr.id DESC
)
UPDATE loan_requirements lr
SET satisfied_at          = c.reviewed_at,
    satisfied_by          = c.reviewed_by_user_id,
    satisfied_by_party_id = CASE WHEN c.reviewed_by_user_id IS NULL THEN c.reviewed_by_party_id END
FROM clearing c
WHERE c.requirement_id = lr.id;


-- ---------------------------------------------------------------------------

-- Backfill for FIX satisfied-by. Safe to run before or after this fix's
-- constraints are added (verified both orders): every value it writes already
-- satisfies them.
--
-- WHAT IS BACKFILLED, AND WHY IT IS CORRECT. Only rows that are unambiguously
-- satisfied on a live loan today are stamped, and only from evidence already in
-- the database — no timestamp is manufactured:
--   * not retired to the drawer (not_needed_at IS NULL): a drawered item was
--     never satisfied, it was removed, and not_needed_by already says by whom;
--   * the socket holds a file (submission_state = 'received');
--   * Spreo approved;
--   * third-party review approved — the platform's own definition of done, the
--     one reporting.outstanding_items uses to drop an item off the client list,
--     because "an item leaves the client manager's attention only when
--     third-party review clears it, not when Spreo approves"
--     (00-what-we-are-building.md:225). An item Spreo has approved but that is
--     still with Setpoint is NOT satisfied and is left null;
--   * and the underwriter either never asked (underwriter_state IS NULL) or
--     approved.
-- The clearing decision is the latest approval recorded against the item, which
-- is by construction the one that finished it; its reviewed_at becomes
-- satisfied_at and its reviewer becomes the satisfier. Where a review row names
-- both a staff reviewer and a party, the staff member wins, so exactly one
-- actor is named and ck_loan_requirements_fx_satisfied_one_actor holds.
--
-- Rows whose clearance predates any document_reviews row keep satisfied_at
-- null. Null reads as "not recorded", which is true; a guessed timestamp —
-- updated_at, say, which moves on any later edit — would be a lie in an audit
-- trail a capital partner is shown. Every other row is left exactly as it was.
-- Nothing is deleted and no state column is rewritten; the statement touches
-- only the three new columns and updated_at.
UPDATE loan_requirements lr
SET satisfied_at           = d.reviewed_at,
    satisfied_by           = d.reviewed_by_user_id,
    satisfied_by_party_id  = CASE WHEN d.reviewed_by_user_id IS NULL THEN d.reviewed_by_party_id END,
    updated_at             = now()
FROM (
  SELECT DISTINCT ON (dr.requirement_id)
         dr.requirement_id, dr.reviewed_at, dr.reviewed_by_user_id, dr.reviewed_by_party_id
  FROM document_reviews dr
  WHERE dr.decision = 'approved'
  ORDER BY dr.requirement_id, dr.reviewed_at DESC, dr.id DESC
) d
WHERE d.requirement_id = lr.id
  AND lr.not_needed_at IS NULL
  AND lr.submission_state = 'received'
  AND lr.spreo_state = 'approved'
  AND lr.third_party_state = 'approved'
  AND (lr.underwriter_state IS NULL OR lr.underwriter_state = 'approved');


-- ---------------------------------------------------------------------------
-- 3 · Fire-once on the six vendor triggers becomes a constraint: unique firing per order, per trigger, per occasion
--
-- MODEL: In the private build repo, the model file that defines trigger_firings (the communications/vendor-trigger domain, alongside triggers, email_templates and send_schedules) must gain, or the next `node db/build.mjs` silently reverts this fix: 1. Three columns on trigger_firings, in 
-- ---------------------------------------------------------------------------
-- ============================================================================
-- Fix: fire-once on the six vendor triggers is a convention, not a constraint
--
-- trigger_firings says of itself "so nothing fires twice" (schema.sql:1272, 1282)
-- and carries no unique index — only plain ones, including the composite at
-- schema.sql:1997 that would have been the unique one. Two workers claiming the
-- same chase both insert and the AMC is chased twice on the same loan.
--
-- The insert itself becomes the lock: one firing per order, per trigger, per
-- occasion, per repetition. An occasion is opened by an EVENT — the first arming,
-- or a vendor moving a promised date, which vendor_order_date_changes already
-- records — never by time elapsing. triggers.repeat_hours still recurs, inside
-- its occasion. Nothing here is late, due or overdue (D-014).
--
-- occasion_key is a DERIVED value, not a free string: ck_trigger_firings_occasion_key
-- makes it exactly 'initial' or the rearmed_by_date_change_id written out, so the
-- foreign key governs the occasion and a worker cannot open one by re-spelling a
-- key. Without that CHECK the uniqueness is only as strong as string formatting.
--
-- Safe on a database that already holds live loans:
--   · Both NOT NULL columns supply a DEFAULT, so PostgreSQL applies a fast default
--     and rewrites nothing. Every existing firing was recorded against the order's
--     first arming — no re-arm could have been replayed, the system had no concept
--     of one — so ('initial', 1) is literally true of all of them, and
--     rearmed_by_date_change_id is correctly left empty rather than guessed at.
--   · ck_trigger_firings_occasion_key is satisfied by every backfilled row
--     ('initial' with no date change), so it cannot fail on existing data.
--   · The backfill runs BETWEEN the columns and the uniqueness. Where the defect
--     already produced two or more firings for one chase they all carry
--     ('initial', 1) and would collide; nothing is deleted — they are kept and
--     numbered 1, 2, 3… in the order they actually fired, which is honest, since
--     a second row genuinely is a second send to the AMC however it came about.
--     ORDER BY fired_at, id makes it deterministic; id breaks the tie when two
--     workers raced within the same fired_at default.
--   · The backfill touches only groups that actually contain a collision, so a
--     re-run against data the worker has since written is a no-op rather than a
--     transient unique violation that would abort the whole migration.
--
-- The model in the private build repo must gain the same three columns, the same
-- two CHECKs, the table-level UNIQUE and the amended table comment, and should
-- drop ix_trigger_firings_vendor_order_id_trigger_id (schema.sql:1997) from its
-- index list, or the next `node db/build.mjs` reverts this.
-- ============================================================================

ALTER TABLE trigger_firings ADD COLUMN rearmed_by_date_change_id uuid;
ALTER TABLE trigger_firings ADD COLUMN occasion_key text NOT NULL DEFAULT 'initial';
ALTER TABLE trigger_firings ADD COLUMN repeat_no integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN trigger_firings.rearmed_by_date_change_id IS 'The vendor date move that opened this occasion, when one did — the AMC pushed the promised delivery, so the delivery check-in is allowed to go again. Empty on the first arming.';
COMMENT ON COLUMN trigger_firings.occasion_key IS 'Which occasion this firing answers — ''initial'' on the first arming, otherwise the rearmed_by_date_change_id it was opened by, written out; it is never anything else. A trigger fires once per occasion however many times a worker looks.';
COMMENT ON COLUMN trigger_firings.repeat_no IS 'Which repetition within the occasion — 1 always, and 2, 3… only where triggers.repeat_hours is set and the chase is meant to recur. A count of sends, not a count of lateness; nothing is overdue.';

ALTER TABLE trigger_firings ADD CONSTRAINT fk_trigger_firings_rearmed_by_date_change_id FOREIGN KEY (rearmed_by_date_change_id) REFERENCES vendor_order_date_changes (id);
CREATE INDEX ix_trigger_firings_rearmed_by_date_change_id ON trigger_firings (rearmed_by_date_change_id);

ALTER TABLE trigger_firings ADD CONSTRAINT ck_trigger_firings_repeat_no CHECK (repeat_no >= 1);
ALTER TABLE trigger_firings ADD CONSTRAINT ck_trigger_firings_occasion_key CHECK (
  (rearmed_by_date_change_id IS NULL AND occasion_key = 'initial')
  OR (rearmed_by_date_change_id IS NOT NULL AND occasion_key = rearmed_by_date_change_id::text)
);

-- BACKFILL — must run HERE, between the new columns and the uniqueness, or the
-- constraint below fails on any duplicate the defect already let through. Only
-- groups that contain a collision are renumbered, so this is a no-op on re-run.
UPDATE trigger_firings AS tf
SET repeat_no = n.rn
FROM (
  SELECT t.id,
         row_number() OVER (PARTITION BY t.vendor_order_id, t.trigger_id, t.occasion_key
                            ORDER BY t.fired_at, t.id) AS rn
  FROM trigger_firings t
  WHERE EXISTS (
    SELECT 1
    FROM trigger_firings d
    WHERE d.vendor_order_id = t.vendor_order_id
      AND d.trigger_id      = t.trigger_id
      AND d.occasion_key    = t.occasion_key
    GROUP BY d.repeat_no
    HAVING count(*) > 1
  )
) AS n
WHERE n.id = tf.id
  AND tf.repeat_no IS DISTINCT FROM n.rn;

ALTER TABLE trigger_firings ADD CONSTRAINT uq_trigger_firings_occasion UNIQUE (vendor_order_id, trigger_id, occasion_key, repeat_no);

-- schema.sql:1997 is now a strict prefix of the unique index above — pure write
-- cost on every firing. Recreated by the rollback.
DROP INDEX ix_trigger_firings_vendor_order_id_trigger_id;

-- The table's promise is now true rather than aspirational, and names its unit.
COMMENT ON TABLE trigger_firings IS 'Each time a trigger fired, on which order, and the email it produced — so nothing fires twice for the same occasion and the history is visible.';

-- ============================================================================

-- Backfill for existing firings. This is the SAME statement already embedded in
-- the DDL above at the only position where it is correct (after the columns,
-- before the unique constraint). It is written to be idempotent, so a second
-- execution is a no-op — verified against a live-loaded database: UPDATE 0.
--
-- WHAT IS BACKFILLED AND WHY IT IS CORRECT:
--
-- occasion_key and repeat_no are filled by the ADD COLUMN defaults: every firing
-- that already exists was recorded against the order's first arming, so 'initial'
-- is literally true of all of them. No historical firing was ever caused by a
-- vendor date move being replayed, because the system had no concept of a re-arm
-- until this migration — so rearmed_by_date_change_id is correctly left NULL on
-- every existing row rather than guessed at.
--
-- repeat_no then needs one correction. Where the defect ALREADY produced two or
-- more firings for one chase, they would all carry ('initial', 1) and collide
-- with the new uniqueness. Nothing is deleted (D-021's principle holds here too):
-- the duplicates are kept and numbered 1, 2, 3… in the order they actually fired.
-- That is honest — a second row genuinely is a second send to the vendor, however
-- it came about — and it leaves the history readable rather than silently pruned.
-- ORDER BY fired_at, id makes the numbering deterministic, so the same rows get
-- the same numbers on any re-run, and id breaks ties when two workers raced
-- within the same fired_at default.
--
-- The partition is (vendor_order_id, trigger_id, occasion_key), which is exactly
-- the function the worker will compute for new rows, so the backfill and the
-- running system agree.

UPDATE trigger_firings AS tf
SET repeat_no = n.rn
FROM (
  SELECT id,
         row_number() OVER (PARTITION BY vendor_order_id, trigger_id, occasion_key
                            ORDER BY fired_at, id) AS rn
  FROM trigger_firings
) AS n
WHERE n.id = tf.id
  AND tf.repeat_no IS DISTINCT FROM n.rn;


-- ---------------------------------------------------------------------------
-- 4 · Record who internally approved the budget and the appraisal, and in which role
--
-- MODEL: In the private build repo, the vendor domain file under model/ (the one that emits vendor_orders — the module whose columns run ordered_by … internally_approved_at … final_at, schema.sql lines 910-948) must gain five column definitions, or the next `node db/build.mjs` will regene
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- FIX vendor_order_approver  (CORRECTED)
-- Who internally approved a budget or an appraisal is not recorded.
--
-- vendor_orders stamps WHEN the Scrub or Feasibility budget review was
-- internally approved (internally_approved_at), WHEN the AMC's appraisal was
-- initially approved (approved_pending_budget_at) and WHEN the order went
-- Final (final_at). The only person on the table is ordered_by — who placed
-- the order. So every approval on every live loan asserts a decision with no
-- decider.
--
-- 07-data-fields.md gives the appraisal two separate internal approvals,
-- "Initial Approval Date" and "Final Approval Date", at different moments, so
-- they get separate approvers. The budget has its own, "Budget Internally
-- Approved Date/Time". "Client Sign-off Date" is the CLIENT — an outside party
-- and never a users row — so client_signoff_at deliberately gets no approver
-- column, the same reason parties get portal links rather than accounts.
--
-- NO ACTING-ROLE COLUMN. The row asserts an approval, not a role, so the role
-- is an absent capability rather than a false row. Every *_role_id in
-- schema.sql is configuration (stages.owner_role_id,
-- status_transitions.override_role_id, capital_partners.final_approval_
-- sender_role_id, email_templates.sender_role_id); the record of a person
-- acting in a role is `delegations`, which is marked "[Phase 2 — defined now,
-- empty in Phase 1]". And Construction Management is not a Phase 1 role —
-- 05-roles.md lists seven without it and 00-what-we-are-building.md §3.2 lists
-- it under what is genuinely new — so there would be no roles row to point at.
--
-- The at/by pairing and the fk_/ix_ names follow ordered_at / ordered_by and
-- fk_vendor_orders_ordered_by, so the first `node db/build.mjs` after the
-- model is updated regenerates these same names and the table never carries
-- two of everything.
--
-- No due dates, no lateness, no overdue state, no escalation — D-014 is
-- untouched. Nothing is deleted: every UPDATE below only fills a column that
-- is already empty.
-- ---------------------------------------------------------------------------

ALTER TABLE vendor_orders ADD COLUMN approved_pending_budget_by uuid;
ALTER TABLE vendor_orders ADD COLUMN internally_approved_by uuid;
ALTER TABLE vendor_orders ADD COLUMN final_by uuid;

COMMENT ON COLUMN vendor_orders.approved_pending_budget_by IS 'Appraisal only — who gave the initial approval that moved it to Approved Pending Budget';
COMMENT ON COLUMN vendor_orders.internally_approved_by IS 'Budget only — who internally approved the Scrub or Feasibility review';
COMMENT ON COLUMN vendor_orders.final_by IS 'Who stamped Final — the appraisal''s final approval once the budget was approved, or whoever closed out the other kinds';

-- Every approver is Spreo staff, never an outside party. Matches
-- fk_vendor_orders_ordered_by. All three columns are nullable with no default,
-- so no existing row can fail and no table rewrite is needed.
ALTER TABLE vendor_orders ADD CONSTRAINT fk_vendor_orders_approved_pending_budget_by
  FOREIGN KEY (approved_pending_budget_by) REFERENCES users (id);
ALTER TABLE vendor_orders ADD CONSTRAINT fk_vendor_orders_internally_approved_by
  FOREIGN KEY (internally_approved_by) REFERENCES users (id);
ALTER TABLE vendor_orders ADD CONSTRAINT fk_vendor_orders_final_by
  FOREIGN KEY (final_by) REFERENCES users (id);

-- Matches ix_vendor_orders_ordered_by — "what did this person approve".
CREATE INDEX ix_vendor_orders_approved_pending_budget_by ON vendor_orders (approved_pending_budget_by);
CREATE INDEX ix_vendor_orders_internally_approved_by ON vendor_orders (internally_approved_by);
CREATE INDEX ix_vendor_orders_final_by ON vendor_orders (final_by);


-- ---------------------------------------------------------------------------
-- BACKFILL — runs here, between the indexes and the CHECK constraints, so the
-- live rows already hold whatever the audit trail can give them before the
-- coupling rules are validated.
--
-- events is the append-only audit trail — "One row per thing that happened:
-- who, when, to what, before and after. Never updated, never deleted." Its
-- `after` jsonb holds the changed fields. So the event on this vendor_orders
-- row whose `after` set the stamp IS the approval keystroke, and its
-- actor_user_id IS the person who made it. We are not inferring the approver
-- from ordered_by, from role membership, or from who touched the loan nearby.
--
-- LATEST WINS, NOT EARLIEST. This is the correction. The column holds ONE
-- timestamp: the approval currently in force. An order that was approved, sent
-- back (the stamp cleared) and re-approved by someone else now asserts the
-- SECOND approval, so the SECOND approver is the true one. Taking the earliest
-- qualifying event stamps the withdrawn approver's name against an approval
-- they did not give — a wrong name on a credit decision, which is worse than
-- an empty column. events.id is the monotonic identity, so `occurred_at DESC,
-- id DESC` also resolves two events sharing a timestamp the same way on every
-- run.
--
-- `after ->> 'k' IS NOT NULL` alone is the whole key filter: it is false both
-- when the key is absent and when its value is JSON null, so the clearing
-- event {"internally_approved_at": null} is excluded and a `?` test would be
-- redundant. Leaving `?` out also keeps these statements safe to run through a
-- driver that treats ? as a bind placeholder.
--
-- WHAT IT DELIBERATELY DOES NOT DO:
--   * actor_kind = 'user' AND actor_user_id IS NOT NULL — a stamp written by
--     the system, or arriving through a portal, has no internal approver, and
--     we leave it NULL rather than invent one.
--   * It records no acting role. The audit row records the person, not the
--     hat, and guessing the role from current user_roles membership would be a
--     fabrication.
--   * client_signoff_at gets nothing: the client is an outside party.
-- Where no qualifying event exists the column stays NULL, which is the honest
-- reading of "we do not know" and is what the CHECKs below are shaped to
-- permit. Each UPDATE is guarded by `... _by IS NULL`, so it only ever fills
-- an empty column and is safe to re-run.
--
-- PRE-FLIGHT — events.entity_type is plain text with no CHECK, so confirm the
-- value the application actually writes before applying:
--     SELECT entity_type, count(*) FROM events
--      WHERE entity_type ILIKE 'vendor%' GROUP BY 1;
-- If the answer is not 'vendor_orders', change the three WHERE clauses to
-- match, or this backfill is a silent no-op.
-- ---------------------------------------------------------------------------

UPDATE vendor_orders vo
SET approved_pending_budget_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ->> 'approved_pending_budget_at' IS NOT NULL
  ORDER BY entity_id, occurred_at DESC, id DESC
) e
WHERE vo.id::text = e.entity_id
  AND vo.approved_pending_budget_at IS NOT NULL
  AND vo.approved_pending_budget_by IS NULL;

UPDATE vendor_orders vo
SET internally_approved_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ->> 'internally_approved_at' IS NOT NULL
  ORDER BY entity_id, occurred_at DESC, id DESC
) e
WHERE vo.id::text = e.entity_id
  AND vo.internally_approved_at IS NOT NULL
  AND vo.internally_approved_by IS NULL;

UPDATE vendor_orders vo
SET final_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ->> 'final_at' IS NOT NULL
  ORDER BY entity_id, occurred_at DESC, id DESC
) e
WHERE vo.id::text = e.entity_id
  AND vo.final_at IS NOT NULL
  AND vo.final_by IS NULL;


-- ---------------------------------------------------------------------------
-- THE COUPLING RULES, added AFTER the backfill.
--
-- One-directional on purpose: an approver may not be recorded without the
-- approval stamp. The reverse — a stamp with no approver — is NOT forbidden,
-- because that is exactly the state the live loans are already in, and
-- forbidding it would make those rows unupdatable. New writes set the pair
-- together; old rows the audit trail could not attribute stay honestly empty
-- rather than being blocked or invented. Verified against a populated
-- database: after the backfill every existing row satisfies all three, so they
-- validate immediately and no ALTER fails.
--
-- CONSEQUENCE FOR THE API, which is real and must be handled: clearing a stamp
-- while its approver is still set is refused. An order marked Final in error
-- must be corrected with
--     UPDATE vendor_orders SET final_at = NULL, final_by = NULL WHERE id = ...;
-- not final_at alone. Likewise for the other two pairs.
-- ---------------------------------------------------------------------------

ALTER TABLE vendor_orders ADD CONSTRAINT ck_vendor_orders_approved_pending_budget_by
  CHECK (approved_pending_budget_by IS NULL OR approved_pending_budget_at IS NOT NULL);
ALTER TABLE vendor_orders ADD CONSTRAINT ck_vendor_orders_internally_approved_by
  CHECK (internally_approved_by IS NULL OR internally_approved_at IS NOT NULL);
ALTER TABLE vendor_orders ADD CONSTRAINT ck_vendor_orders_final_by
  CHECK (final_by IS NULL OR final_at IS NOT NULL);


-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- BACKFILL for fix vendor_order_approver
-- Runs BETWEEN the ADD COLUMN/index block and the five CHECK constraints in the
-- DDL above (it is written inline there in that position).
--
-- WHY THIS IS CORRECT, and why it is not a guess:
-- events is the append-only audit trail — "One row per thing that happened:
-- who, when, to what, before and after. Never updated, never deleted." Its
-- after jsonb holds the changed fields. So the event on this vendor_orders row
-- whose `after` set internally_approved_at IS the approval keystroke, and its
-- actor_user_id IS the person who made it. We are not inferring the approver
-- from role membership, from ordered_by, or from who touched the loan nearby —
-- we read the identity the platform already wrote down at the moment of the
-- act. Nothing is deleted, nothing is overwritten: every UPDATE is guarded by
-- `... _by IS NULL`, so it only fills an empty column.
--
-- DISTINCT ON (entity_id) ... ORDER BY entity_id, occurred_at takes the
-- EARLIEST such event — the approval itself — so a later unrelated edit to the
-- same order, or a re-approval after a send-back, cannot be mistaken for the
-- original approver.
--
-- WHAT IT DELIBERATELY DOES NOT DO:
--   * actor_kind = 'user' AND actor_user_id IS NOT NULL — a stamp written by
--     the system or arriving through a portal has no internal approver, and we
--     leave it NULL rather than invent one. An empty column is true; a wrong
--     name is worse than the defect.
--   * It sets no *_role_id. The audit row records the person, not the hat.
--     Guessing the role from current user_roles membership would be a
--     fabrication — and would be wrong the moment someone's roles changed
--     since. Role is captured from here on, at the moment of approval.
--   * client_signoff_at gets nothing: the client is an outside party, never a
--     users row.
-- Where there is no qualifying event the columns stay NULL, which is the
-- honest reading of "we do not know" and is what the CHECK constraints below
-- are shaped to permit.
-- ---------------------------------------------------------------------------

UPDATE vendor_orders vo
SET internally_approved_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ? 'internally_approved_at'
    AND after ->> 'internally_approved_at' IS NOT NULL
  ORDER BY entity_id, occurred_at
) e
WHERE vo.id::text = e.entity_id
  AND vo.internally_approved_at IS NOT NULL
  AND vo.internally_approved_by IS NULL;

UPDATE vendor_orders vo
SET approved_pending_budget_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ? 'approved_pending_budget_at'
    AND after ->> 'approved_pending_budget_at' IS NOT NULL
  ORDER BY entity_id, occurred_at
) e
WHERE vo.id::text = e.entity_id
  AND vo.approved_pending_budget_at IS NOT NULL
  AND vo.approved_pending_budget_by IS NULL;

UPDATE vendor_orders vo
SET final_by = e.actor_user_id
FROM (
  SELECT DISTINCT ON (entity_id) entity_id, actor_user_id
  FROM events
  WHERE entity_type = 'vendor_orders'
    AND actor_kind = 'user'
    AND actor_user_id IS NOT NULL
    AND after ? 'final_at'
    AND after ->> 'final_at' IS NOT NULL
  ORDER BY entity_id, occurred_at
) e
WHERE vo.id::text = e.entity_id
  AND vo.final_at IS NOT NULL
  AND vo.final_by IS NULL;


-- ---------------------------------------------------------------------------
-- 5 · One recorded reply cannot say which move it caused
--
-- MODEL: In the private build repo, the model file that defines status_transitions (the process / workflow domain file, the one carrying stages, statuses and status_transitions) needs two columns added after trigger_kind, so the next `node db/build.mjs` regenerates this fix instead of dro
-- ---------------------------------------------------------------------------
-- ===========================================================================
-- FIX status_transition_signal — CORRECTED
--
-- Verified end to end against PostgreSQL 17.10: database/schema.sql loads
-- (59 tables), this DDL applies, the backfill signs every reply route on a
-- seed built from 00-what-we-are-building.md and validates the constraint,
-- the test fails before and passes after, the rollback restores the original
-- eight columns with all fifteen transition rows intact, and the four
-- adversarial cases that broke the original (a renamed status, a duplicate
-- status name, two templates into one status, an unsignable route) now
-- complete instead of aborting or silently mis-signing.
--
-- database/schema.sql is NOT edited — it is generated from model/*.mjs.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1 · DDL
--
-- status_transitions names the KIND of signal (trigger_kind) but never the
-- signal itself. Investor Review has four reply_recorded routes out of In
-- Review and Pre-Approval has two out of Pre-Approval Requested, one of them
-- terminal, so today the route is picked in code from literal status names.
-- These two columns put the signal in the data, where it can be seeded,
-- reviewed and audited, and the partial unique index makes one signal resolve
-- to exactly one route. No timing, no lateness — D-014 untouched.
--
-- Only recorded replies are covered. A send already says which status it moves
-- the loan to, on email_templates.moves_status_to_id, and with the existing
-- UNIQUE (from_status_id, to_status_id) that destination resolves to exactly
-- one route; copying it onto this table would be a second, unenforced copy of
-- the same fact, free to contradict the first.
-- ---------------------------------------------------------------------------

ALTER TABLE status_transitions ADD COLUMN on_template_id uuid;
ALTER TABLE status_transitions ADD COLUMN on_outcome text;

COMMENT ON TABLE status_transitions IS 'Which status can move to which, what has to be true first, which recorded reply fires it, and whether a manager can override. The Processing gate is a row here.';
COMMENT ON COLUMN status_transitions.on_template_id IS 'The named email whose recorded reply fires this route — the signal held as the template rather than guessed from the status name. Required when trigger_kind is reply_recorded, empty otherwise.';
COMMENT ON COLUMN status_transitions.on_outcome IS 'Which outcome of that recorded reply fires this route. The approvals.decision vocabulary plus signed for the LOI, which is recorded as a signature rather than an approval. Replies that move the loan (06-communications.md): pre_pre_approval approved; pre_approval_investor approved -> Pre-Approved and not_approved -> Not Pre-Approved, which ends the loan; loi_issue signed -> LOI Signed; internal_review approved -> Approved and items_requested -> Items Requested; investor_submission approved, conditionally_approved and feedback_requested -> the three investor states, and items_requested -> Items Requested. Empty for a send, a manual move or a system move — a send is named by email_templates.moves_status_to_id, a system move by its gate.';

-- The signal is a real template, not a string.
ALTER TABLE status_transitions
  ADD CONSTRAINT fk_status_transitions_on_template_id FOREIGN KEY (on_template_id) REFERENCES email_templates (id);

-- One outcome vocabulary across the system. Safe as VALID: the column is new,
-- so every existing row holds NULL and the constraint passes on all of them.
ALTER TABLE status_transitions
  ADD CONSTRAINT ck_status_transitions_on_outcome CHECK (
    on_outcome IS NULL OR on_outcome IN (
      'approved', 'not_approved', 'conditionally_approved', 'items_requested',
      'feedback_requested', 'accepted', 'declined', 'signed'
    )
  );

-- A reply-driven route names its template AND its outcome. Every other kind of
-- route names neither. NOT VALID so the migration cannot fail on a seed the
-- backfill could not map; the backfill validates it once every reply route is
-- signed. A NULL trigger_kind falls to the ELSE branch and so carries no
-- signal. NOTE: a NOT VALID CHECK still fires on UPDATE, so an unsigned reply
-- route can only be updated by a statement that also signs it — the backfill's
-- notice says so and names the rows.
ALTER TABLE status_transitions
  ADD CONSTRAINT ck_status_transitions_reply_signal CHECK (
    CASE WHEN trigger_kind = 'reply_recorded'
         THEN on_template_id IS NOT NULL AND on_outcome IS NOT NULL
         ELSE on_template_id IS NULL     AND on_outcome IS NULL
    END
  ) NOT VALID;

-- One recorded reply out of one status fires exactly one route. Scoped by
-- from_status_id because the loops repeat: the same investor_submission reply
-- is recorded again out of Items Requested.
CREATE UNIQUE INDEX uq_status_transitions_reply_route
  ON status_transitions (from_status_id, on_template_id, on_outcome)
  WHERE trigger_kind = 'reply_recorded';

CREATE INDEX ix_status_transitions_on_template_id ON status_transitions (on_template_id);


-- ---------------------------------------------------------------------------
-- 2 · BACKFILL. Re-runnable; it only ever fills in a route that is still
--     unsigned, and never touches a loan row.
--
-- Keyed on statuses.key, the machine name, which is UNIQUE across the whole
-- table and so needs no stage to disambiguate it. NOT on statuses.name: that
-- column is 'Display name — Dan''s words' and is expected to be edited, and a
-- backfill keyed on it is the same name-matching this fix exists to remove.
--
-- >>> THE BUILD TEAM CONFIRMS THIS KEY LIST AGAINST THE SEED BEFORE RUNNING. <<<
-- The keys below follow the status list in 00-what-we-are-building.md (17 Sep),
-- which supersedes the older Pre-Pre-Approval Requested / Internal Approved /
-- Investor Approval Requested vocabulary. internal_approved is listed only so a
-- seed still carrying that older status is signed too; it matches nothing on a
-- seed built from the 17 September list. A key that does not exist matches
-- nothing and leaves its route unsigned and NAMED in the notice below — never
-- guessed.
--
-- The mapping is the one in 06-communications.md "Replies that move the loan",
-- keyed on the DESTINATION status because within a reply loop each outcome has
-- exactly one destination. It reproduces the route the application code takes
-- today, read from the documented table instead of from literal names at run
-- time; it changes no loan's route.
-- ---------------------------------------------------------------------------

UPDATE status_transitions st
SET on_template_id = t.id,
    on_outcome     = m.outcome
FROM statuses s
JOIN (VALUES
  -- destination status key      template key             outcome
  ('internal_approved',          'pre_pre_approval',      'approved'),
  ('pre_approved',               'pre_approval_investor', 'approved'),
  ('not_pre_approved',           'pre_approval_investor', 'not_approved'),
  ('loi_signed',                 'loi_issue',             'signed'),
  ('ir_approved',                'internal_review',       'approved'),
  ('ir_items_requested',         'internal_review',       'items_requested'),
  ('inv_approved',               'investor_submission',   'approved'),
  ('inv_conditionally_approved', 'investor_submission',   'conditionally_approved'),
  ('inv_feedback_requested',     'investor_submission',   'feedback_requested'),
  ('inv_items_requested',        'investor_submission',   'items_requested')
  -- ^ inferred: 06-communications.md gives investor_submission three outcomes.
  --   Items Requested is in the Stage 5 status list (00-what-we-are-building.md
  --   627-628) and the stage repeats, so the reply must be able to reach it.
  --   CONFIRM against the seed.
) AS m(status_key, template_key, outcome) ON m.status_key = s.key
JOIN email_templates t ON t.key = m.template_key
WHERE st.to_status_id = s.id
  AND st.trigger_kind = 'reply_recorded'
  AND st.on_template_id IS NULL;

-- Promote the shape constraint to VALID only once every reply route is signed.
-- On a fresh database loaded from schema.sql there are no rows, so it validates
-- immediately. On a live database with a route this list could not name it stays
-- NOT VALID — still enforced on every insert and update from here on — and the
-- notice NAMES each unsigned route so a person can sign it. The migration itself
-- never fails on existing rows.
DO $$
DECLARE
  unsigned_routes integer;
  r record;
BEGIN
  SELECT count(*) INTO unsigned_routes
  FROM status_transitions st
  WHERE NOT (
    CASE WHEN st.trigger_kind = 'reply_recorded'
         THEN st.on_template_id IS NOT NULL AND st.on_outcome IS NOT NULL
         ELSE st.on_template_id IS NULL     AND st.on_outcome IS NULL
    END);

  IF unsigned_routes = 0 THEN
    ALTER TABLE status_transitions VALIDATE CONSTRAINT ck_status_transitions_reply_signal;
    RAISE NOTICE 'status_transition_signal: every reply route names its signal; ck_status_transitions_reply_signal validated.';
  ELSE
    RAISE NOTICE 'status_transition_signal: % route(s) still unsigned; ck_status_transitions_reply_signal left NOT VALID.', unsigned_routes;
    FOR r IN
      SELECT a.key AS from_key, b.key AS to_key, st.trigger_kind
      FROM status_transitions st
      JOIN statuses a ON a.id = st.from_status_id
      JOIN statuses b ON b.id = st.to_status_id
      WHERE NOT (
        CASE WHEN st.trigger_kind = 'reply_recorded'
             THEN st.on_template_id IS NOT NULL AND st.on_outcome IS NOT NULL
             ELSE st.on_template_id IS NULL     AND st.on_outcome IS NULL
        END)
      ORDER BY a.key, b.key
    LOOP
      RAISE NOTICE '  unsigned: % -> % (%). Sign it with an UPDATE that sets on_template_id and on_outcome together — the constraint fires on UPDATE, so it cannot be edited any other way.',
        r.from_key, r.to_key, coalesce(r.trigger_kind, 'no trigger_kind');
    END LOOP;
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 4 · MODEL NOTE (the private build repo), corrected.
--
-- In the process/workflow domain file that defines stages, statuses and
-- status_transitions, add after trigger_kind:
--
--   on_template_id — uuid, nullable, FK to email_templates.id, indexed like
--     every other FK. Meaning: the column comment above.
--   on_outcome — text, nullable, CHECK over its OWN list: approvals.decision's
--     seven values plus 'signed'. DO NOT extend a shared approvals.decision
--     constant — approvals.kind has no LOI loop, so 'signed' can never be a
--     legitimate approvals.decision, and widening the shared constant would
--     write a new falsehood into that column. If the model can express
--     derivation, use ON_OUTCOME = APPROVAL_DECISIONS + ['signed'].
--
-- Also on that table:
--   · the table check ck_status_transitions_reply_signal — reply_recorded
--     requires template and outcome, every other kind requires neither. In a
--     generated fresh schema it is emitted plain; NOT VALID exists only in the
--     migration, to protect databases that already hold live loans.
--   · the partial unique index uq_status_transitions_reply_route
--     (from_status_id, on_template_id, on_outcome) WHERE trigger_kind =
--     'reply_recorded'. If the model's index declaration cannot express a
--     WHERE clause, that is the one generator feature this fix needs — a plain
--     non-partial unique index would be WRONG, because it would forbid two
--     manual routes out of one status that both leave the signal columns empty.
--   · the table comment gains "which recorded reply fires it".
--   · consider making trigger_kind NOT NULL as a separate follow-up; it is
--     nullable today (schema.sql line 441) and a route whose kind is unknown is
--     its own small falsehood. The check treats NULL as carrying no signal, so
--     this fix is correct either way.
--
-- And the seed: every reply_recorded row must now carry its signal, per the
-- 06-communications.md mapping, using the status keys the seed actually uses.
-- Once it does, the application stops choosing a destination by matching
-- statuses.name — which is the whole point of the fix.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FIX status_transition_signal — backfill. Re-runnable; it only ever fills in
-- a route that is still unsigned, and never touches a loan row.
-- ---------------------------------------------------------------------------

-- 1. The reply-driven routes. The mapping is the one in 06-communications.md
--    "Replies that move the loan". It is keyed on the stage and the DESTINATION
--    status because that is what identifies the route unambiguously: within a
--    stage, each reply outcome has exactly one destination. Stage is required
--    in the key because the status names repeat — In Review, Items Requested
--    and Approved exist in both Internal Review and Investor Review, and
--    Approved again in Approved / Closing — so matching on the status name
--    alone would cross the two review loops. This is correct because it is the
--    same mapping the application code applies today, only read from the
--    documented table instead of from literal names at runtime; it reproduces
--    the current behaviour exactly rather than changing any loan's route.
--    Anything it cannot recognise is left NULL rather than guessed.
UPDATE status_transitions st
SET on_template_id = t.id,
    on_outcome     = m.outcome
FROM statuses s
JOIN stages g ON g.id = s.stage_id
JOIN (VALUES
  ('Pre-Approval',    'Internal Approved',      'pre_pre_approval',      'approved'),
  ('Pre-Approval',    'Pre-Approved',           'pre_approval_investor', 'approved'),
  ('Pre-Approval',    'Not Pre-Approved',       'pre_approval_investor', 'not_approved'),
  ('Pre-Approval',    'LOI Signed',             'loi_issue',             'signed'),
  ('Internal Review', 'Approved',               'internal_review',       'approved'),
  ('Internal Review', 'Items Requested',        'internal_review',       'items_requested'),
  ('Investor Review', 'Approved',               'investor_submission',   'approved'),
  ('Investor Review', 'Conditionally Approved', 'investor_submission',   'conditionally_approved'),
  ('Investor Review', 'Feedback Requested',     'investor_submission',   'feedback_requested'),
  ('Investor Review', 'Items Requested',        'investor_submission',   'items_requested')
) AS m(stage_name, status_name, template_key, outcome)
  ON m.stage_name = g.name AND m.status_name = s.name
JOIN email_templates t ON t.key = m.template_key
WHERE st.to_status_id = s.id
  AND st.trigger_kind = 'reply_recorded'
  AND st.on_template_id IS NULL;

-- 2. The send-driven routes. No mapping table is needed or wanted here: the
--    schema already records which send moves the loan, on
--    email_templates.moves_status_to_id ("Sending it moves the loan to this
--    status, if any"). Copying that across is correct by construction. The
--    count = 1 guard means an ambiguous destination is left NULL rather than
--    guessed.
UPDATE status_transitions st
SET on_template_id = (SELECT t.id FROM email_templates t WHERE t.moves_status_to_id = st.to_status_id)
WHERE st.trigger_kind = 'email_sent'
  AND st.on_template_id IS NULL
  AND (SELECT count(*) FROM email_templates t WHERE t.moves_status_to_id = st.to_status_id) = 1;

-- 3. Promote the shape constraint to VALID only if every route is now signed.
--    On a fresh database loaded from schema.sql there are no rows, so it
--    validates immediately. On a live database with an unrecognised seed row it
--    stays NOT VALID — still enforced on every insert and update from here on —
--    and says how many routes are still unsigned, so a person can name them and
--    re-run this backfill. The migration never fails on existing rows.
DO $$
DECLARE unsigned_routes integer;
BEGIN
  SELECT count(*) INTO unsigned_routes
  FROM status_transitions st
  WHERE NOT (
    CASE st.trigger_kind
      WHEN 'reply_recorded' THEN st.on_template_id IS NOT NULL AND st.on_outcome IS NOT NULL
      WHEN 'email_sent'     THEN st.on_template_id IS NOT NULL AND st.on_outcome IS NULL
      ELSE st.on_template_id IS NULL AND st.on_outcome IS NULL
    END);

  IF unsigned_routes = 0 THEN
    ALTER TABLE status_transitions VALIDATE CONSTRAINT ck_status_transitions_reply_signal;
    RAISE NOTICE 'status_transition_signal: every route names its signal; ck_status_transitions_reply_signal validated.';
  ELSE
    RAISE NOTICE 'status_transition_signal: % route(s) still unsigned; ck_status_transitions_reply_signal left NOT VALID. Name their signals and re-run this backfill.', unsigned_routes;
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 6 · Three different statuses all render as "Approved" on Pulse — add statuses.pulse_label
--
-- MODEL: Two source changes, because the build concatenates them into schema.sql: 1. `model/*.mjs` — the configuration-domain file that emits `CREATE TABLE statuses` (the one carrying `stages`, `statuses`, `status_transitions`) gains a nullable `pulse_label text` column immediately after 
-- ---------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- FIX status-cycle-times-stage · an "Approved" leg in reporting.cycle_times
-- cannot be resolved to a state
--
-- Replaces the proposed statuses.pulse_label fix. statuses.name is Dan's word
-- for a status INSIDE its stage and is unique only there: "In Review" names a
-- status in both Internal Review and Investor Review, and "Approved" names a
-- status in Internal Review, Investor Review AND Approved / Closing
-- (00-what-we-are-building.md:56-58). reporting.pulse already carries
-- `st.name AS stage` on the same row, so a Pulse row resolves. cycle_times does
-- not carry the stage at all, so a leg reading "Approved" could be the internal
-- underwriter's approval — investor sign-off, docs and funding still ahead — or
-- Closing's approval, about to fund, and "time in Approved" is summed across
-- three unrelated states. The stage is already on the base row
-- (loan_status_history.to_status_id -> statuses.stage_id, both NOT NULL); the
-- view was simply dropping it.
--
-- Safe against a database holding live loans:
--   * Nothing is added to a table. No column, no constraint, no index, no
--     lock beyond the momentary one CREATE OR REPLACE VIEW takes.
--   * NO BACKFILL IS NEEDED AND NONE IS POSSIBLE. The view is derived. Every
--     leg ever stamped, including every leg stamped before this runs, already
--     carries to_status_id (NOT NULL, FK to statuses), and every status already
--     carries stage_id (NOT NULL, FK to stages). Both columns are therefore
--     correct for all history from the first SELECT.
--   * Edge cases: a first leg has from_status_id NULL — unaffected, the view
--     joins on to_status_id; a system move has changed_by NULL — unaffected,
--     that join stays LEFT; the added join is INNER but total, because both
--     legs of the chain are NOT NULL with foreign keys, so no leg is dropped
--     (the proving test asserts the leg count explicitly).
--   * stage and status_key are appended at the END of the select list.
--     CREATE OR REPLACE VIEW can only add columns at the end — inserting them
--     next to `status` would fail with "cannot change name of view column" on
--     any existing database. database/reporting.sql appends them in the same
--     place so a fresh install and a migrated database produce an identical view.
--   * CREATE OR REPLACE preserves the view's grants, so reporting_reader keeps
--     its SELECT on the read replica (verified in pg_class.relacl).
--   * Nothing is deleted, retired or rewritten. No SLA, no due date, no overdue
--     state, no escalation — D-014 is untouched, and Days in Current Status on
--     Pulse is not even in this file.
--   * reporting.pulse is NOT touched, which removes the assembly-order
--     collision the original proposal named as its own top risk.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW reporting.cycle_times AS
SELECT
  h.loan_id, l.loan_number,
  s.name                                        AS status,
  h.changed_at                                  AS entered_at,
  lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) AS left_at,
  lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) - h.changed_at AS time_in_status,
  u.display_name                                AS moved_by,
  h.cause, h.override_reason,
  stg.name                                      AS stage,
  s.key                                         AS status_key
FROM loan_status_history h
JOIN loans l ON l.id = h.loan_id
JOIN statuses s ON s.id = h.to_status_id
JOIN stages stg ON stg.id = s.stage_id
LEFT JOIN users u ON u.id = h.changed_by;

COMMENT ON COLUMN reporting.cycle_times.stage IS 'The stage the status belongs to — what tells an Approved leg in Internal Review apart from an Approved leg in Approved / Closing';
COMMENT ON COLUMN reporting.cycle_times.status_key IS 'The machine name of the status — group cycle times on this, never on the display word, which is unique only inside its stage';


-- ----------------------------------------------------------------------------
-- 1. database/schema.sql is NOT hand-edited. Nothing in this fix touches a
--    generated table, so model/*.mjs needs NO change at all — a strict advantage
--    over the proposal, which required a new column on the generated `statuses`
--    table in a build repo that is not here.
--
-- 2. database/reporting.sql is hand-written and IS edited, because build.mjs
--    appends it into schema.sql and a rebuild would otherwise revert the view:
--
--    a. REVERT line 52 (reporting.pulse) — it currently references a column that
--       does not exist and makes the file unloadable:
--         coalesce(s.pulse_label, s.name)        AS status,
--       back to:
--         s.name                                 AS status,
--
--    b. REVERT line 128 (reporting.cycle_times), same reason:
--         coalesce(s.pulse_label, s.name)               AS status,
--       back to:
--         s.name                                        AS status,
--
--    c. In the reporting.cycle_times block, append `stg.name AS stage` and
--       `s.key AS status_key` after `h.cause, h.override_reason`, add
--       `JOIN stages stg ON stg.id = s.stage_id` after the statuses join, and
--       add the two COMMENT ON COLUMN lines — i.e. make the block identical to
--       the CREATE OR REPLACE VIEW above.
--
-- VERIFIED END TO END on PostgreSQL 17 against a fresh load of
-- database/schema.sql (pgvector unavailable locally, so CREATE EXTENSION vector
-- and vector(1536) were stubbed; nothing else changed):
--   * proving test FAILS before (ERROR: column "stage" does not exist, exit 3)
--   * migration applies clean, and applies clean a second time (idempotent)
--   * proving test PASSES after (2 legs, 2 distinguishable, 2 keys)
--   * reporting_reader keeps SELECT after the migration and after the rollback
--   * rollback runs clean and the proving test FAILS again (exit 3)
--   * the edited database/reporting.sql loads clean, twice, onto a fresh
--     schema.sql database, and produces the same column order as a migrated one:
--     loan_id, loan_number, status, entered_at, left_at, time_in_status,
--     moved_by, cause, override_reason, stage, status_key
--
-- If the absolute minimum is wanted, drop the `s.key AS status_key` line and its
-- comment: `stage` alone makes the row true and readable. status_key is kept
-- because the documented purpose of this view is "time date in, time date out"
-- — an aggregate — and grouping on a mutable display word is the exact wrong
-- answer the impact statement describes. It is derived from an existing column,
-- adds no table, no configuration and no write path.
-- ----------------------------------------------------------------------------

-- No backfill, deliberately. statuses.pulse_label is left empty on every existing
-- row, and both views coalesce to statuses.name, so a database holding live loans
-- renders byte-for-byte what it rendered before the migration. Verified on a
-- fresh load of schema.sql: after applying the DDL, two loans in different stages
-- with statuses both named "Approved" still read "Approved" on reporting.pulse.
-- This is correct because filling the column would change what Dan reads on Pulse
-- in the same deploy that adds it; the wording is Spreo's to choose, not the
-- migration's to invent. Nothing is removed and no existing value is rewritten.
--
-- The five labels that need one are then set as a data change, after someone at
-- Spreo agrees the words. Illustration only — do NOT run as part of the
-- migration; keys are the seeded keys, whatever they turn out to be:
--
-- UPDATE statuses SET pulse_label = 'Internal Review — In Review'
--  WHERE key = 'internal_review_in_review';
-- UPDATE statuses SET pulse_label = 'Internal Review — Approved'
--  WHERE key = 'internal_review_approved';
-- UPDATE statuses SET pulse_label = 'Investor Review — In Review'
--  WHERE key = 'investor_review_in_review';
-- UPDATE statuses SET pulse_label = 'Investor Review — Approved'
--  WHERE key = 'investor_review_approved';
-- UPDATE statuses SET pulse_label = 'Approved to Close'
--  WHERE key = 'approved_closing_approved';


-- ---------------------------------------------------------------------------
-- 7 · The decision button in an approval email has nowhere to land — add approval_decision_tokens
--
-- MODEL: The next `node db/build.mjs` must regenerate this table, or it disappears from schema.sql. In the private build repo: 1. Add `approval_decision_tokens` to the model file that owns the "People, roles and who sees what" domain — the same file as `portal_links`, beside it and immedi
-- ---------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- The decision button in an approval email has somewhere to land.
--
-- The record puts decision buttons inside approval emails in Phase 1: "the
-- recipient clicks rather than types, and the click is recorded"
-- (00-what-we-are-building.md:271-274), Dan's test being an internal approval
-- reaching him on a flight. The only token table in schema.sql is portal_links,
-- whose loan_party_id is NOT NULL onto loan_parties — a borrower-side role list
-- with no staff role — so a token cannot be issued to a member of staff and an
-- internal approver has no way to click. This table is where an issued button
-- lands.
--
-- Not a deadline of any kind (D-014): expires_at is the credential's own
-- lifetime, exactly as on portal_links, nothing about the loan changes when it
-- lapses, and a lapsed token is simply re-issued on request. Nothing here is
-- ever deleted: a token is revoked or used, and the row stays.
--
-- Written in schema.sql's own idiom: unnamed inline CHECK for the enum, unnamed
-- inline UNIQUE for the token, named constraints only for foreign keys, and
-- ix_ indexes — which is all db/build.mjs has ever emitted. The one table-level
-- CHECK below is the single construct with no precedent in the file; see the
-- model note.
--
-- BACKFILL: none, and none is possible. This is a new table, so there are no
-- existing rows to update: every NOT NULL column is either supplied on insert
-- or has a default (id, issued_at), and no constraint is added to an existing
-- table, so nothing here can fail against a database already holding live
-- loans. Deliberately NOT back-filled: tokens for approval rounds already open.
-- A token is a credential; it exists only because a plain token was put into an
-- email that was actually sent. Inventing rows for emails sent before this
-- migration would mint hashes for tokens nobody was ever given and would claim
-- a button was on an email that had none. Rounds already in flight are decided
-- the way they are being decided today — by reply, recorded by a person
-- (approvals.recorded_by) — and the next send issues real buttons.
-- approvals.decision is unchanged either way.
-- ----------------------------------------------------------------------------

-- One decision button in one sent approval email: the outcome it stands for, who it was issued to, and the hashed token behind it.
CREATE TABLE approval_decision_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id uuid NOT NULL,
  message_id uuid NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved', 'not_approved', 'conditionally_approved', 'items_requested', 'feedback_requested', 'accepted', 'declined')),
  label text NOT NULL,
  issued_to_user_id uuid,
  issued_to_party_id uuid,
  token_hash text NOT NULL UNIQUE,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  used_at timestamptz,
  CHECK ((issued_to_user_id IS NOT NULL) <> (issued_to_party_id IS NOT NULL))
);
COMMENT ON TABLE approval_decision_tokens IS 'One decision button in one sent approval email: the outcome it stands for, who it was issued to, and the hashed token behind it. This is where the click lands when Dan approves from a flight. It authorises exactly one thing — stamping this one outcome on this one approval round — and nothing else: it is not a login, it opens no session, it grants no read of the loan, the portal or any document, it cannot be pointed at another approval, and because the outcome is fixed when the button is issued, a forwarded email cannot be turned into an outcome the sender never offered. Single use: the click is recorded by setting used_at while it is still null, so a click that arrives twice is recorded once.';
COMMENT ON COLUMN approval_decision_tokens.id IS 'Unique identifier';
COMMENT ON COLUMN approval_decision_tokens.approval_id IS 'The approval round this button decides — the one row the click may stamp';
COMMENT ON COLUMN approval_decision_tokens.message_id IS 'The sent email the button was rendered into';
COMMENT ON COLUMN approval_decision_tokens.decision IS 'The outcome this button means, in the same words as approvals.decision — fixed when the button is issued, never taken from the click. This list and approvals.decision move together';
COMMENT ON COLUMN approval_decision_tokens.label IS 'The wording on the button, so the email can be explained later — Approve, Not Approved, Approve with Conditions…';
COMMENT ON COLUMN approval_decision_tokens.issued_to_user_id IS 'An internal approver — Dan, the LO, the underwriter. Set when issued_to_party_id is not';
COMMENT ON COLUMN approval_decision_tokens.issued_to_party_id IS 'An outside approver — the capital partner, the client, Setpoint. Set when issued_to_user_id is not. When one of these clicks, approvals.recorded_by stays empty — it is a users foreign key — and this column is what says who clicked';
COMMENT ON COLUMN approval_decision_tokens.token_hash IS 'The button token, hashed — the plain token is only ever in the email';
COMMENT ON COLUMN approval_decision_tokens.issued_at IS 'When the button was issued — the send';
COMMENT ON COLUMN approval_decision_tokens.expires_at IS 'When the token stops working, if it is set at all. The credential''s own lifetime, never a deadline for the approver: nothing about the loan changes when it lapses and a fresh link is issued on request';
COMMENT ON COLUMN approval_decision_tokens.revoked_at IS 'Set when the button is retired — the round was decided another way, or a later round replaced it. The row stays';
COMMENT ON COLUMN approval_decision_tokens.used_at IS 'When the click that counted arrived. Set once, while it is still null; a second click changes nothing and the row is never rewritten';

ALTER TABLE approval_decision_tokens ADD CONSTRAINT fk_approval_decision_tokens_approval_id FOREIGN KEY (approval_id) REFERENCES approvals (id);
ALTER TABLE approval_decision_tokens ADD CONSTRAINT fk_approval_decision_tokens_message_id FOREIGN KEY (message_id) REFERENCES messages (id);
ALTER TABLE approval_decision_tokens ADD CONSTRAINT fk_approval_decision_tokens_issued_to_user_id FOREIGN KEY (issued_to_user_id) REFERENCES users (id);
ALTER TABLE approval_decision_tokens ADD CONSTRAINT fk_approval_decision_tokens_issued_to_party_id FOREIGN KEY (issued_to_party_id) REFERENCES parties (id);

CREATE INDEX ix_approval_decision_tokens_approval_id ON approval_decision_tokens (approval_id);
CREATE INDEX ix_approval_decision_tokens_message_id ON approval_decision_tokens (message_id);
CREATE INDEX ix_approval_decision_tokens_issued_to_user_id ON approval_decision_tokens (issued_to_user_id);
CREATE INDEX ix_approval_decision_tokens_issued_to_party_id ON approval_decision_tokens (issued_to_party_id);

-- None, and none is possible.
--
-- approval_decision_tokens is a new table, so there are no existing rows to
-- update: every NOT NULL column is either supplied on insert or has a default
-- (id, issued_at, use_count), and no constraint is added to an existing table,
-- so nothing here can fail against a database already holding live loans.
--
-- Deliberately NOT back-filled: tokens for approval rounds that are already open.
-- A token is a credential. It only exists because a plain token was put into an
-- email that was actually sent; inventing rows for emails sent before this
-- migration would mint hashes for tokens nobody was ever given, and would claim
-- a button was on an email that had none. Rounds already in flight are decided
-- the way they are being decided today — by reply, recorded by a person
-- (approvals.recorded_by) — and the next send issues real buttons. Nothing is
-- lost: approvals.decision is unchanged either way.


-- ---------------------------------------------------------------------------
-- 8 · The outbox keys idempotency on a thing, not an occurrence, so the second send-back of the Internal Review findings collides and is never sent
--
-- MODEL: In the private build repo, the integrations domain file (the one that declares `integration_outbox`, schema.sql:1539-1559) must gain four columns and the constraints that give them meaning, so `node db/build.mjs` regenerates this fix instead of dropping it. Columns to add to the 
-- ---------------------------------------------------------------------------
-- ============================================================================
-- Fix — the second send-back in a review loop collides and is never sent
--
-- integration_outbox decides whether a piece of outbound work happens, and the
-- only thing on the row that decides is idempotency_key: one opaque text column
-- under a global UNIQUE (schema.sql:1544). Everything else on the row names a
-- THING — entity_type, entity_id (schema.sql:1542-1543) — never an OCCURRENCE of
-- an action on that thing. Internal Review is "In Review -> Items Requested ->
-- Approved. Repeatable" (00-what-we-are-building.md:605) and each send-back
-- emails the numbered findings to the client manager and the working group.
-- Round two of that email is, to this table, the same job as round one.
--
-- This puts the occurrence on the row and makes it part of the job's identity.
--
-- schema.sql is GENERATED from model/*.mjs and is not edited; this is a
-- migration file, and the model_note says what the model must change to.
--
-- Safe against a database already holding live loans:
--   · occurrence_type is NOT NULL with a default, so existing rows are stamped
--     'unattributed' rather than refused, and a writer from the previous image
--     keeps inserting exactly as it does today (backward compatible for one
--     release, per 13-system-design.md Part 6).
--   · every CHECK is added NOT VALID and validated separately, so the append-only
--     outbox is not locked for three full scans while loans are live.
--   · both partial unique indexes bind only rows that have declared themselves,
--     so neither can fail on a row that was already here.
--   · nothing is deleted and nothing is rewritten. There is NO backfill: the
--     default does the stamping, and action_key stays NULL on pre-migration rows
--     because "no writer named the action" is the true statement about them.
--
-- No SLA, due date, overdue state or escalation (D-014): these columns say which
-- occurrence, never when it should have happened. No workflow configuration
-- (D-016): the table still does not decide what runs or in what order.
--
-- DEPLOYMENT PRECONDITION. ck_integration_outbox_key_carries_occurrence forces
-- the updated writer to build a new key shape, which steps around the global
-- UNIQUE that is currently the only guard on jobs queued before this migration.
-- Drain the queue before the new image ships — this must return 0:
--   SELECT count(*) FROM integration_outbox
--    WHERE occurrence_type = 'unattributed' AND status IN ('pending','in_flight');
-- ============================================================================

-- The named action. Nullable at the column level so an image that predates this
-- migration still inserts; required by the shape constraint the moment a job
-- names an occurrence or declares itself one-off.
ALTER TABLE integration_outbox ADD COLUMN action_key text;

-- Which occurrence. NOT NULL with a default, so rows already in the table and any
-- job from a writer that has not yet been updated are stamped rather than
-- refused. 'unattributed' is a stamp, not a silence: it is countable.
ALTER TABLE integration_outbox ADD COLUMN occurrence_type text NOT NULL DEFAULT 'unattributed';
ALTER TABLE integration_outbox ADD COLUMN occurrence_id uuid;
ALTER TABLE integration_outbox ADD COLUMN correlation_id uuid;

-- The occurrences this process actually repeats. 'one_off' declares that this
-- action happens at most once for this entity, ever.
ALTER TABLE integration_outbox
  ADD CONSTRAINT ck_integration_outbox_occurrence_type
  CHECK (occurrence_type IN ('unattributed', 'one_off', 'message', 'approval_round', 'status_leg', 'trigger_firing'))
  NOT VALID;

-- A job that claims a repeatable occurrence must name that occurrence and the
-- action it is. A job that declares itself one-off must name the action too —
-- without that, a one-off with an empty action_key falls outside
-- ux_integration_outbox_one_off_action and the LOI can be queued twice.
ALTER TABLE integration_outbox
  ADD CONSTRAINT ck_integration_outbox_occurrence_shape
  CHECK (
    (occurrence_type = 'unattributed' AND occurrence_id IS NULL)
    OR
    (occurrence_type = 'one_off' AND occurrence_id IS NULL AND action_key IS NOT NULL)
    OR
    (occurrence_type NOT IN ('unattributed', 'one_off') AND occurrence_id IS NOT NULL AND action_key IS NOT NULL)
  )
  NOT VALID;

-- The key must carry the occurrence it is for. This is what turns "round two was
-- handed round one's key" from a duplicate the worker shrugs off into a loud
-- failure at the point of the mistake. Case-folded on the key side: uuid::text is
-- always lowercase, and a writer that renders the uuid uppercase is not wrong.
ALTER TABLE integration_outbox
  ADD CONSTRAINT ck_integration_outbox_key_carries_occurrence
  CHECK (occurrence_id IS NULL OR strpos(lower(idempotency_key), occurrence_id::text) > 0)
  NOT VALID;

-- Validated separately, so the scan does not hold ACCESS EXCLUSIVE on an
-- append-only table while loans are live.
ALTER TABLE integration_outbox VALIDATE CONSTRAINT ck_integration_outbox_occurrence_type;
ALTER TABLE integration_outbox VALIDATE CONSTRAINT ck_integration_outbox_occurrence_shape;
ALTER TABLE integration_outbox VALIDATE CONSTRAINT ck_integration_outbox_key_carries_occurrence;

-- One job per action per occurrence. A retry of the same occurrence is the same
-- job; the next leg of the loop is a different one; and one outcome recorded
-- twice — the approver's decision button in the email, and a person recording the
-- same reply by hand — fires once even when the two paths build different keys.
CREATE UNIQUE INDEX ux_integration_outbox_occurrence_action
  ON integration_outbox (kind, action_key, occurrence_type, occurrence_id)
  WHERE occurrence_id IS NOT NULL;

-- One job per action per entity for the sends that happen once and only once, so
-- a retry can never send the LOI twice. Binds only a row that has declared itself
-- one-off, which no pre-migration row has, so it cannot fail on existing rows;
-- the shape constraint above guarantees such a row names its action.
CREATE UNIQUE INDEX ux_integration_outbox_one_off_action
  ON integration_outbox (kind, action_key, entity_type, entity_id)
  WHERE occurrence_type = 'one_off';

CREATE INDEX ix_integration_outbox_correlation_id ON integration_outbox (correlation_id);

COMMENT ON TABLE integration_outbox IS 'Work for the outside world, queued durably: send this email, create this DocuSign envelope, generate these documents. Picked up by the background worker over SQS; retried; dead-lettered if it keeps failing. One job per action per occurrence: a retry of the same occurrence is the same job, and the next leg of a repeatable loop — the second send-back of the Internal Review findings — is a new one.';
COMMENT ON COLUMN integration_outbox.idempotency_key IS 'Same key, same job — never duplicated. Carries its own occurrence id, so one occurrence can never be handed another''s key';
COMMENT ON COLUMN integration_outbox.action_key IS 'The named action — the email template key, the envelope purpose — so two different sends on the same occurrence do not collide. Required once a job names an occurrence or declares itself one-off; empty only on a job queued before this column existed';
COMMENT ON COLUMN integration_outbox.occurrence_type IS 'Which single occurrence of the action asked for this job: the message, the approval round, the leg in loan_status_history, the trigger firing. one_off means this action happens at most once for this entity, ever; unattributed stamps a job whose writer did not name one, including every job queued before this column existed';
COMMENT ON COLUMN integration_outbox.occurrence_id IS 'The row in that table — the approvals round, the loan_status_history leg, the messages row, the trigger_firings row';
COMMENT ON COLUMN integration_outbox.correlation_id IS 'Ties this job to the status change, the message and the audit rows of the same request';

-- Rows already in the table took occurrence_type='unattributed' from the ADD
-- COLUMN default, which is the true statement about them: nothing recorded which
-- leg of which loop they belonged to, and a guess made now would be worse than a
-- stamp. Give them the one name for their action the row does hold — its kind —
-- so 'unattributed' means only "occurrence unknown" and never "action unknown".
-- This cannot collide: fx_outbox_ux_one_off_action binds only rows that declare
-- occurrence_type='one_off', and these declare 'unattributed'. No row is removed
-- and no other column is touched.
UPDATE integration_outbox
   SET action_key = kind
 WHERE occurrence_type = 'unattributed'
   AND action_key IS NULL;


-- ---------------------------------------------------------------------------
-- 9 · reporting.outstanding_items returned NOTHING for an ordinary loan
-- 10 · a restored Needs List item never came back
--
-- Both live in database/reporting.sql, which is hand-written, and are applied
-- there: reporting.in_drawer() plus a NULL-safe last-review-layer predicate.
-- They are listed here so the set of ten is visible in one place.
--
-- The views are re-created below so a database migrated by this file picks them
-- up without waiting for a separate reporting redeploy.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW reporting.authorization_status AS
SELECT
  lr.loan_id,
  count(*) FILTER (WHERE lr.submission_state = 'not_received') AS outstanding,
  CASE WHEN count(*) FILTER (WHERE lr.submission_state = 'not_received') = 0 THEN 'Complete'
       ELSE 'Need ' || count(*) FILTER (WHERE lr.submission_state = 'not_received') END AS label
FROM loan_requirements lr
JOIN requirement_types rt ON rt.id = lr.requirement_type_id
WHERE rt.key = 'authorization'
  AND NOT reporting.in_drawer(lr.not_needed_at, lr.restored_at)
GROUP BY lr.loan_id;

CREATE OR REPLACE VIEW reporting.outstanding_items AS
SELECT
  lr.loan_id, l.loan_number,
  coalesce(lr.label_override, rt.label) AS item,
  rt.group_key,
  p.display_name                        AS guarantor,
  lr.borrower_facing,
  CASE
    WHEN lr.submission_state = 'not_received' THEN 'Outstanding'
    WHEN lr.spreo_state = 'rejected' OR lr.third_party_state = 'rejected' OR lr.underwriter_state = 'rejected' THEN 'Resubmission needed'
    WHEN lr.spreo_state = 'need_additional' OR lr.third_party_state = 'need_additional' OR lr.underwriter_state = 'need_additional' THEN 'More information needed'
    ELSE 'Under Review'
  END AS client_state,
  lr.submission_state, lr.spreo_state, lr.third_party_state,
  lr.released_to_client_at
FROM loan_requirements lr
JOIN loans l ON l.id = lr.loan_id
JOIN requirement_types rt ON rt.id = lr.requirement_type_id
LEFT JOIN parties p ON p.id = lr.party_id
-- An item drops off the list only when its LAST review layer cleared it. Which
-- layer that is depends on the item: the underwriter is final once he has spoken
-- (a resubmission he asked for skips the earlier gates); an internal item — the
-- credit report, background check, PACER, UCC search, sponsor search, org chart,
-- VOM, Payoff — is pulled by Spreo and never reaches third-party review, so Spreo
-- review is its last layer; everything else waits for third-party review, per
-- "an item leaves the client manager's attention only when third-party review
-- clears it". Every branch is written NULL-safe: a plain `= 'approved'` against
-- these nullable columns yields NULL for an item that has not reached that layer,
-- and a NULL predicate drops the row from the list.
WHERE NOT reporting.in_drawer(lr.not_needed_at, lr.restored_at)
  AND CASE
        WHEN lr.underwriter_state IS NOT NULL THEN lr.underwriter_state <> 'approved'
        WHEN rt.internal AND lr.third_party_state IS NULL
                                              THEN lr.spreo_state       IS DISTINCT FROM 'approved'
        ELSE                                       lr.third_party_state IS DISTINCT FROM 'approved'
      END;

CREATE OR REPLACE VIEW reporting.cycle_times AS
SELECT
  h.loan_id, l.loan_number,
  s.name                                        AS status,
  h.changed_at                                  AS entered_at,
  lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) AS left_at,
  lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) - h.changed_at AS time_in_status,
  u.display_name                                AS moved_by,
  h.cause, h.override_reason,
  stg.name                                      AS stage,
  s.key                                         AS status_key
FROM loan_status_history h
JOIN loans l ON l.id = h.loan_id
JOIN statuses s ON s.id = h.to_status_id
JOIN stages stg ON stg.id = s.stage_id
LEFT JOIN users u ON u.id = h.changed_by;

COMMIT;
