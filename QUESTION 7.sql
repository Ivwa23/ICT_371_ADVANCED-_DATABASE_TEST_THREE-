DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Kelvin Moyo'), ('Natasha Daka'), ('Oscar Lubinda');

-- (b) Function: first 10 units K5, above 10 K8
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be a non-negative number (got %)', p_units;
    END IF;
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2)::NUMERIC(12,2);
END $$;

-- (d) Trigger (installed before the data is loaded)
CREATE OR REPLACE FUNCTION trg_fn_reading_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

-- Six readings: 0, exactly 10, and above-10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100.00, 100.00),    -- 0 units
    (1, '2026-10-01', 100.00, 110.00),    -- exactly 10
    (2, '2026-09-01',  50.00,  65.00),    -- 15
    (2, '2026-10-01',  65.00,  90.50),    -- 25.5
    (3, '2026-09-01',   0.00,   4.00),    -- 4
    (3, '2026-10-01',   4.00,  20.00);    -- 16

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

CALL pr_generate_bill(1, CURRENT_DATE - 30);     -- September bills already past due
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 10);     -- October bills not yet due
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;   -- fully paid
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;   -- part paid

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id, c.full_name AS customer_name, b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index: partial, only unpaid bills; paid bills never matter for overdue searches
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-receivables', '30 0 * * *', $$CALL pr_refresh_receivables()$$);

-- DEMONSTRATION
SELECT u AS units, fn_water_charge(u) AS charge
FROM (VALUES (0::numeric),(4),(10),(15),(25.5)) t(u);
DO $$ BEGIN PERFORM fn_water_charge(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 105);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 6;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_stored FROM readings;        -- still 6

DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT * FROM bills ORDER BY bill_id;

SELECT * FROM v_overdue_bills ORDER BY bill_id;

SET enable_seqscan = off;
EXPLAIN SELECT bill_id, charge - amount_paid AS outstanding
FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;