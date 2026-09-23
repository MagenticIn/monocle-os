-- ============================================================================
-- The reporting schema — the read-only copy
--
-- Served from the RDS read replica. Dashboards, Pulse exports and the Phase 2
-- intelligence layer read here through reporting_reader, which can only SELECT.
-- Nothing here is ever written by the application; everything is derived.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS reporting;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reporting_reader') THEN
    CREATE ROLE reporting_reader NOLOGIN;
  END IF;
END $$;

-- Four business days, per Dan: "let's just make it obvious. Let's just say four."
CREATE OR REPLACE FUNCTION reporting.add_business_days(start_date date, days integer)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d date := start_date; n integer := 0;
BEGIN
  IF start_date IS NULL THEN RETURN NULL; END IF;
  WHILE n < days LOOP
    d := d + 1;
    IF extract(isodow FROM d) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN d;
END $$;

-- Is a Needs List item currently in the not-needed drawer? Credit removes an item
-- with a reason (D-013) and may bring it back; neither stamp is ever cleared, so
-- the removal and its reason survive the item returning. Written once, here,
-- because two views and the recurring Needs List email all have to agree.
CREATE OR REPLACE FUNCTION reporting.in_drawer(not_needed_at timestamptz, restored_at timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT $1 IS NOT NULL AND ($2 IS NULL OR $2 < $1);
$$;

-- Authorization Status as Dan reads it: Complete, or Need N.
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

-- The pipeline. One row per loan, every column Dan reads off Pulse.
CREATE OR REPLACE VIEW reporting.pulse AS
SELECT
  l.id                                   AS loan_id,
  l.loan_number,
  lo.last_name                           AS lo_last_name,
  cm.display_name                        AS client_manager,
  cp.code                                AS capital_source,
  l.property_street, l.property_city, l.property_state,
  st.name                                AS stage,
  s.name                                 AS status,
  (current_date - l.status_since::date)  AS days_in_current_status,
  l.transaction_type, l.loan_type, l.property_type, l.channel,
  t.total_loan_amount, t.initial_loan_amount, t.holdback, t.interest_reserve, t.note_rate,
  l.target_submission_date, l.target_funding_date, l.loi_funding_date, l.psa_closing_date,
  ap.status                              AS appraisal_status,
  ap.promised_delivery_date              AS appraisal_promised,
  ap.target_delivery_date                AS appraisal_target,
  ap.vendor_needs                        AS appraiser_needs,
  apv.display_name                       AS appraisal_company,
  bu.status                              AS budget_status,
  bu.review_type                         AS budget_review_type,
  bu.promised_delivery_date              AS budget_promised,
  bu.vendor_needs                        AS budget_vendor_needs,
  (bu.sent_to_appraiser_at IS NOT NULL)  AS budget_to_appraiser,
  greatest(ap.promised_delivery_date, bu.promised_delivery_date)                                   AS calculated_submission_date,
  reporting.add_business_days(greatest(ap.promised_delivery_date, bu.promised_delivery_date), 4)  AS calculated_funding_date,
  l.vom_status, l.payoff_status, l.escrow_contact_provided, l.track_record_status,
  coalesce(auth.label, 'Complete')       AS authorization_status,
  l.portfolio_refinance, l.repeat_borrower, l.insurance_paid, l.rate_lock_expiration
FROM loans l
JOIN stages st ON st.id = l.stage_id
JOIN statuses s ON s.id = l.status_id
LEFT JOIN users lo ON lo.id = l.loan_officer_id
LEFT JOIN users cm ON cm.id = l.client_manager_id
LEFT JOIN capital_partners cp ON cp.id = l.capital_partner_id
LEFT JOIN loan_terms t ON t.id = l.current_terms_id
LEFT JOIN vendor_orders ap ON ap.loan_id = l.id AND ap.kind = 'appraisal'
LEFT JOIN parties apv ON apv.id = ap.vendor_party_id
LEFT JOIN vendor_orders bu ON bu.loan_id = l.id AND bu.kind = 'budget_review'
LEFT JOIN reporting.authorization_status auth ON auth.loan_id = l.id
WHERE l.deleted_at IS NULL;

-- Everything still open on every loan — the same list the recurring email sends,
-- in the four words the client sees.
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

-- Every leg of every loan: how long it sat in each status, and who moved it.
-- "Time date in, time date out. And then time date back in, time date back out."
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
COMMENT ON COLUMN reporting.cycle_times.stage IS 'The stage the status belongs to — what tells an Approved leg in Internal Review apart from an Approved leg in Approved / Closing.';
COMMENT ON COLUMN reporting.cycle_times.status_key IS 'The machine name of the status — group cycle times on this, never on the display word, which is unique only inside its stage.';


-- How vendor dates drift — "every time you told us you'd get it by X, you missed it by two days."
CREATE OR REPLACE VIEW reporting.vendor_drift AS
SELECT
  vo.loan_id, l.loan_number, vo.kind, v.display_name AS vendor,
  c.field, c.old_value, c.new_value, (c.new_value - c.old_value) AS days_moved,
  c.changed_at, c.reason
FROM vendor_order_date_changes c
JOIN vendor_orders vo ON vo.id = c.vendor_order_id
JOIN loans l ON l.id = vo.loan_id
LEFT JOIN parties v ON v.id = vo.vendor_party_id;

GRANT USAGE ON SCHEMA reporting TO reporting_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO reporting_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA reporting GRANT SELECT ON TABLES TO reporting_reader;
