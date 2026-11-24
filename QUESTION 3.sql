DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE      NULL,
    new_returned_on DATE      NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES ('Database Systems'), ('Operating Systems'), ('Computer Networks');

-- (b) Function: K2 per day after the due date
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));   -- fines stop on return
    RETURN 2 * GREATEST(v_end - v_due, 0);                    -- due date itself = 0
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)   -- date and final fine together
    WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- Six loans, then three returns through the procedure
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice',  CURRENT_DATE - 20, CURRENT_DATE - 6),    -- 1: open and overdue
    (1, 'Brian',  CURRENT_DATE - 3,  CURRENT_DATE + 11),   -- 2: open, on time
    (2, 'Cathy',  CURRENT_DATE - 30, CURRENT_DATE - 16),   -- 3: returned late
    (2, 'David',  CURRENT_DATE - 14, CURRENT_DATE - 7),    -- 4: returned on due date
    (3, 'Esther', CURRENT_DATE - 10, CURRENT_DATE + 4),    -- 5: returned early
    (3, 'Felix',  CURRENT_DATE - 25, CURRENT_DATE - 11);   -- 6: open and overdue

CALL pr_return_loan(3, CURRENT_DATE - 10);   -- 6 days late -> K12
CALL pr_return_loan(4, CURRENT_DATE - 7);    -- on due date -> K0
CALL pr_return_loan(5, CURRENT_DATE - 2);    -- early       -> K0

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title AS book_title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- (f) Index: partial, only unreturned loans, so it stays small
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned as of that date
      AND due_on < p_as_of                                 -- and past due
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-overdue-summary', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

-- DEMONSTRATION
SELECT loan_id, due_on, returned_on, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today, fine_amount
FROM loans ORDER BY loan_id;
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

UPDATE loans SET borrower_name = 'Alice B.' WHERE loan_id = 1;   -- returned_on unchanged: no audit
SELECT loan_id, old_returned_on, new_returned_on FROM loan_audit ORDER BY audit_id;

SELECT * FROM v_overdue_loans ORDER BY loan_id;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;