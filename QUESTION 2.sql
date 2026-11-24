DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S1001', 'Chanda Mwila',   5000.00),
    ('S1002', 'Mutale Banda',   3000.00),
    ('S1003', 'Thandiwe Phiri', 4000.00);     -- no payments yet

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_fee NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments WHERE student_id = p_student_id), 0);
END $$;

-- (c) Procedure (does NOT write the audit row; the trigger does)
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % (credit balances not allowed)',
                        p_amount, v_balance;
    END IF;
    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- Six payments through the procedure
CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);     -- student 2 now fully settled

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- (f) Index: equality column first (student_id), range column second (paid_on)
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-daily-collections', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

-- DEMONSTRATION
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;
DO $$ BEGIN PERFORM fn_fee_balance(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 4000.01, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

SELECT COUNT(*) AS payments, (SELECT COUNT(*) FROM payment_audit) AS audit_rows FROM payments;
SELECT student_id, fee_due FROM students ORDER BY 1;      -- fee_due unchanged

SELECT * FROM v_fee_balances ORDER BY student_number;     -- settled student excluded

SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);            -- rerun replaces the row
SELECT * FROM daily_collections;