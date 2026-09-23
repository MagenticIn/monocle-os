-- Undo for 001-correctness-fixes.sql. Drops only what that migration created.
-- It discards the stamps it backfilled along with their columns, so this is a
-- migration rollback for the window before the platform starts writing them,
-- not an operational undo. No loan row is removed.
BEGIN;

-- 1 · An internal item can be made borrower-facing by accident
-- ROLLBACK. Drops only what this fix added, each by the name it was given. The
-- backfill's correction to already-wrong rows is deliberately NOT undone —
-- those rows are now telling the truth about themselves, nothing was deleted,
-- and the events rows stamped by the backfill remain as the record of what
-- changed and why (verified: events survive the rollback intact).
-- ---------------------------------------------------------------------------
-- ALTER TABLE loan_requirements DROP CONSTRAINT ck_loan_requirements_internal_not_borrower_facing;
-- ALTER TABLE loan_requirements DROP CONSTRAINT fk_loan_requirements_type_internal;
-- DROP TRIGGER trg_loan_requirements_set_internal ON loan_requirements;
-- DROP FUNCTION loan_requirements_set_internal();
-- ALTER TABLE loan_requirements DROP COLUMN internal;
-- ALTER TABLE requirement_types DROP CONSTRAINT uq_requirement_types_id_internal;
-- ALTER TABLE requirement_types DROP CONSTRAINT ck_requirement_types_internal_not_borrower_facing;


-- ---------------------------------------------------------------------------
-- WHAT THE MODEL MUST CHANGE (private build repo, the file owning the Needs
-- List and document catalogue domain). Without these, `node db/build.mjs`
-- silently drops the whole guard on the next rebuild.

-- 2 · Record who satisfied a Needs List item, and when
-- ROLLBACK. Drops only what this fix created, by name. It discards the
-- satisfied stamps along with the columns, so it is a migration rollback for
-- the window before the platform starts writing them, not an operational undo.
-- Nothing else on loan_requirements is touched, and no loan_requirements row is
-- removed. (This is a second reason the backfill must not move updated_at: the
-- rollback cannot put it back.)
DROP INDEX IF EXISTS ix_loan_requirements_loan_id_satisfied_at;
DROP INDEX IF EXISTS ix_loan_requirements_satisfied_by_party_id;
DROP INDEX IF EXISTS ix_loan_requirements_satisfied_by;
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS ck_loan_requirements_satisfied_one_actor;
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS ck_loan_requirements_satisfied_actor_needs_time;
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS fk_loan_requirements_satisfied_by_party_id;
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS fk_loan_requirements_satisfied_by;
ALTER TABLE loan_requirements DROP COLUMN IF EXISTS satisfied_by_party_id;
ALTER TABLE loan_requirements DROP COLUMN IF EXISTS satisfied_by;
ALTER TABLE loan_requirements DROP COLUMN IF EXISTS satisfied_at;


-- ---------------------------------------------------------------------------
-- MODEL NOTE (build repo), correcting the proposal's:
--   * Object names carry NO `fx_` marker. They are
--     fk_loan_requirements_satisfied_by, fk_loan_requirements_satisfied_by_party_id,
--     ck_loan_requirements_satisfied_actor_needs_time,
--     ck_loan_requirements_satisfied_one_actor,
--     ix_loan_requirements_satisfied_by, ix_loan_requirements_satisfied_by_party_id,
--     ix_loan_requirements_loan_id_satisfied_at — matching
--     fk_loan_requirements_not_needed_by and ix_loan_requirements_loan_id_submission_state.
--   * The process-step note for the review handler must record the DECIDING
--     LAYER rule above, not "third-party approved". An internal item
--     (requirement_types.internal) never reaches third-party review, and an
--     item the underwriter has spoken on is finished by him.
--   * closing_checklist_items.completed_at / completed_by map one-to-one onto
--     satisfied_at / satisfied_by; record the mapping so the fold carries the
--     stamps across. requirement_types.group_key already has 'closing'.
--   * If the generator emits per-FK indexes automatically (it did for
--     not_needed_by), do not declare the two single-column indexes twice; the
--     composite (loan_id, satisfied_at) must be declared by hand, as
--     (loan_id, submission_state) already is.
--   * Any derived reporting note must say that satisfied_at - uploaded_at and
--     satisfied_at - released_to_client_at are elapsed-time readings only — no
--     target, no threshold. D-014.

-- 3 · Fire-once on the six vendor triggers becomes a constraint: unique firing per order, per trigger, per occasion
-- ROLLBACK
-- No firing row is removed — all history survives, exactly as it does through
-- the forward migration. Verified: every trigger_firings row is still present.
-- ============================================================================
-- CREATE INDEX ix_trigger_firings_vendor_order_id_trigger_id ON trigger_firings (vendor_order_id, trigger_id);
-- ALTER TABLE trigger_firings DROP CONSTRAINT uq_trigger_firings_occasion;
-- ALTER TABLE trigger_firings DROP CONSTRAINT ck_trigger_firings_occasion_key;
-- ALTER TABLE trigger_firings DROP CONSTRAINT ck_trigger_firings_repeat_no;
-- DROP INDEX ix_trigger_firings_rearmed_by_date_change_id;
-- ALTER TABLE trigger_firings DROP CONSTRAINT fk_trigger_firings_rearmed_by_date_change_id;
-- ALTER TABLE trigger_firings DROP COLUMN repeat_no;
-- ALTER TABLE trigger_firings DROP COLUMN occasion_key;
-- ALTER TABLE trigger_firings DROP COLUMN rearmed_by_date_change_id;
-- COMMENT ON TABLE trigger_firings IS 'Each time a trigger fired, on which order, and the email it produced — so nothing fires twice and the history is visible.';

-- 4 · Record who internally approved the budget and the appraisal, and in which role
-- ROLLBACK. Drops only what this fix created, each by exact name: constraints,
-- then indexes, then the columns. Verified to run clean against a populated
-- database, to leave vendor_orders exactly as schema.sql builds it, to leave
-- all five reporting views intact, and to allow the migration to be applied
-- again afterwards. Dropping the columns discards the approver identities
-- recorded since the fix; the audit trail in events still holds them, which is
-- where the backfill read them from.
-- ---------------------------------------------------------------------------
-- ALTER TABLE vendor_orders DROP CONSTRAINT ck_vendor_orders_approved_pending_budget_by;
-- ALTER TABLE vendor_orders DROP CONSTRAINT ck_vendor_orders_internally_approved_by;
-- ALTER TABLE vendor_orders DROP CONSTRAINT ck_vendor_orders_final_by;
-- DROP INDEX ix_vendor_orders_approved_pending_budget_by;
-- DROP INDEX ix_vendor_orders_internally_approved_by;
-- DROP INDEX ix_vendor_orders_final_by;
-- ALTER TABLE vendor_orders DROP CONSTRAINT fk_vendor_orders_approved_pending_budget_by;
-- ALTER TABLE vendor_orders DROP CONSTRAINT fk_vendor_orders_internally_approved_by;
-- ALTER TABLE vendor_orders DROP CONSTRAINT fk_vendor_orders_final_by;
-- ALTER TABLE vendor_orders DROP COLUMN approved_pending_budget_by;
-- ALTER TABLE vendor_orders DROP COLUMN internally_approved_by;
-- ALTER TABLE vendor_orders DROP COLUMN final_by;

-- 5 · One recorded reply cannot say which move it caused
-- 3 · ROLLBACK. Drops only what this fix added; every status_transitions row
--     survives untouched. Verified: 15 rows before, 15 after, 8 columns after.
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS uq_status_transitions_reply_route;
DROP INDEX IF EXISTS ix_status_transitions_on_template_id;
ALTER TABLE status_transitions DROP CONSTRAINT IF EXISTS ck_status_transitions_reply_signal;
ALTER TABLE status_transitions DROP CONSTRAINT IF EXISTS ck_status_transitions_on_outcome;
ALTER TABLE status_transitions DROP CONSTRAINT IF EXISTS fk_status_transitions_on_template_id;
ALTER TABLE status_transitions DROP COLUMN IF EXISTS on_outcome;
ALTER TABLE status_transitions DROP COLUMN IF EXISTS on_template_id;
COMMENT ON TABLE status_transitions IS 'Which status can move to which, what has to be true first, and whether a manager can override. The Processing gate is a row here.';


-- ---------------------------------------------------------------------------

-- 6 · Three different statuses all render as "Approved" on Pulse — add statuses.pulse_label
-- ROLLBACK
--
-- CREATE OR REPLACE VIEW cannot DROP a column, so the view has to be dropped and
-- recreated; DROP VIEW discards its grants, so reporting_reader's SELECT must be
-- re-granted in the same transaction or the read replica goes blind. Nothing in
-- a table is touched, so no stamped row is lost.
-- ----------------------------------------------------------------------------
-- BEGIN;
-- DROP VIEW reporting.cycle_times;
-- CREATE VIEW reporting.cycle_times AS
-- SELECT
--   h.loan_id, l.loan_number,
--   s.name                                        AS status,
--   h.changed_at                                  AS entered_at,
--   lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) AS left_at,
--   lead(h.changed_at) OVER (PARTITION BY h.loan_id ORDER BY h.changed_at) - h.changed_at AS time_in_status,
--   u.display_name                                AS moved_by,
--   h.cause, h.override_reason
-- FROM loan_status_history h
-- JOIN loans l ON l.id = h.loan_id
-- JOIN statuses s ON s.id = h.to_status_id
-- LEFT JOIN users u ON u.id = h.changed_by;
-- GRANT SELECT ON reporting.cycle_times TO reporting_reader;
-- COMMIT;


-- ----------------------------------------------------------------------------
-- SOURCE CHANGES
--

-- 7 · The decision button in an approval email has nowhere to land — add approval_decision_tokens
-- Every object this fix creates, dropped by the name it was created with.
DROP INDEX IF EXISTS ix_approval_decision_tokens_issued_to_party_id;
DROP INDEX IF EXISTS ix_approval_decision_tokens_issued_to_user_id;
DROP INDEX IF EXISTS ix_approval_decision_tokens_message_id;
DROP INDEX IF EXISTS ix_approval_decision_tokens_approval_id;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS fk_approval_decision_tokens_issued_to_party_id;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS fk_approval_decision_tokens_issued_to_user_id;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS fk_approval_decision_tokens_message_id;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS fk_approval_decision_tokens_approval_id;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS ck_approval_decision_tokens_expires_after_issued;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS ck_approval_decision_tokens_used_at_matches_use_count;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS ck_approval_decision_tokens_single_use;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS ck_approval_decision_tokens_issued_to_alternatives;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS ck_approval_decision_tokens_decision;
ALTER TABLE approval_decision_tokens DROP CONSTRAINT IF EXISTS uq_approval_decision_tokens_token_hash;
DROP TABLE IF EXISTS approval_decision_tokens;
-- Note: rolling back discards issued buttons. Revoke any live tokens first
-- (UPDATE approval_decision_tokens SET revoked_at = now() WHERE used_at IS NULL
-- AND revoked_at IS NULL) so no link in a delivered email is left resolving to
-- nothing; approvals.decision, which is where the outcome actually lives, is
-- untouched by this rollback.

-- 8 · The outbox keys idempotency on a thing, not an occurrence, so the second send-back of the Internal Review findings collides and is never sent
-- Undoes this fix alone. The occurrences recorded since the migration are lost
-- with the columns — that is what a rollback of this fix means — and the rows
-- themselves are untouched.
DROP INDEX IF EXISTS fx_outbox_ix_correlation_id;
DROP INDEX IF EXISTS fx_outbox_ux_one_off_action;
DROP INDEX IF EXISTS fx_outbox_ux_occurrence_action;

ALTER TABLE integration_outbox DROP CONSTRAINT IF EXISTS fx_outbox_ck_key_carries_occurrence;
ALTER TABLE integration_outbox DROP CONSTRAINT IF EXISTS fx_outbox_ck_occurrence_shape;
ALTER TABLE integration_outbox DROP CONSTRAINT IF EXISTS fx_outbox_ck_occurrence_type;

ALTER TABLE integration_outbox DROP COLUMN IF EXISTS correlation_id;
ALTER TABLE integration_outbox DROP COLUMN IF EXISTS occurrence_id;
ALTER TABLE integration_outbox DROP COLUMN IF EXISTS occurrence_type;
ALTER TABLE integration_outbox DROP COLUMN IF EXISTS action_key;

COMMENT ON TABLE integration_outbox IS 'Work for the outside world, queued durably: send this email, create this DocuSign envelope, generate these documents. Picked up by the background worker over SQS; retried; dead-lettered if it keeps failing; never done twice thanks to the idempotency key.';
COMMENT ON COLUMN integration_outbox.idempotency_key IS 'Same key, same job — never duplicated';

-- Completion: constraints, columns and indexes the per-fix rollbacks above miss.
-- Verified by round-trip diff against a fresh database — after this file runs,
-- pg_constraint and pg_indexes match the baseline exactly.

-- 1 · an internal item can be made borrower-facing by accident
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS fk_loan_requirements_type_internal;
ALTER TABLE loan_requirements DROP CONSTRAINT IF EXISTS ck_loan_requirements_internal_not_borrower_facing;
DROP TRIGGER IF EXISTS trg_loan_requirements_set_internal ON loan_requirements;
DROP FUNCTION IF EXISTS loan_requirements_set_internal();
ALTER TABLE loan_requirements DROP COLUMN IF EXISTS internal;
ALTER TABLE requirement_types DROP CONSTRAINT IF EXISTS uq_requirement_types_id_internal;
ALTER TABLE requirement_types DROP CONSTRAINT IF EXISTS ck_requirement_types_internal_not_borrower_facing;

-- 3 · fire-once on the six vendor triggers
ALTER TABLE trigger_firings DROP CONSTRAINT IF EXISTS uq_trigger_firings_occasion;
ALTER TABLE trigger_firings DROP CONSTRAINT IF EXISTS fk_trigger_firings_rearmed_by_date_change_id;
ALTER TABLE trigger_firings DROP CONSTRAINT IF EXISTS ck_trigger_firings_occasion_key;
ALTER TABLE trigger_firings DROP CONSTRAINT IF EXISTS ck_trigger_firings_repeat_no;
ALTER TABLE trigger_firings DROP COLUMN IF EXISTS rearmed_by_date_change_id;
ALTER TABLE trigger_firings DROP COLUMN IF EXISTS occasion_key;
ALTER TABLE trigger_firings DROP COLUMN IF EXISTS repeat_no;
-- the migration drops this as redundant once the unique index exists; put it back
CREATE INDEX IF NOT EXISTS ix_trigger_firings_vendor_order_id_trigger_id
  ON trigger_firings (vendor_order_id, trigger_id);

-- 4 · who internally approved the budget and the appraisal
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS ck_vendor_orders_approved_pending_budget_by;
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS ck_vendor_orders_internally_approved_by;
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS ck_vendor_orders_final_by;
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS fk_vendor_orders_approved_pending_budget_by;
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS fk_vendor_orders_internally_approved_by;
ALTER TABLE vendor_orders DROP CONSTRAINT IF EXISTS fk_vendor_orders_final_by;
ALTER TABLE vendor_orders DROP COLUMN IF EXISTS approved_pending_budget_by;
ALTER TABLE vendor_orders DROP COLUMN IF EXISTS internally_approved_by;
ALTER TABLE vendor_orders DROP COLUMN IF EXISTS final_by;

COMMIT;
