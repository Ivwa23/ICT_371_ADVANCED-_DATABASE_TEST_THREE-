DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,      -- filled by the trigger
    total_value  NUMERIC(14,2) NOT NULL,      -- filled by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Joseph Mbewe'), ('F002', 'Agnes Chisanga'), ('F003', 'Moses Katongo');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;
    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade % (use A, B or C)', p_grade;
    END IF;
    RETURN v_rate;
END $$;

-- (d) Trigger: the single place where pricing happens
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);   -- overrides anything supplied
    RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);          -- rejects NULL / unsupported grade early
    -- basic fields only; 0 placeholders satisfy NOT NULL until the BEFORE trigger sets the real values
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 0, 0, p_date, FALSE);
END $$;

-- Six deliveries, loaded after the trigger exists
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, 0, 0, CURRENT_DATE - 1, FALSE),
    (1, 'B', 250.50, 0, 0, CURRENT_DATE - 1, TRUE),
    (2, 'C', 400.00, 0, 0, CURRENT_DATE - 1, FALSE),
    (2, 'A',  80.25, 0, 0, CURRENT_DATE - 2, TRUE),
    (3, 'B',  60.00, 0, 0, CURRENT_DATE - 2, TRUE),
    (3, 'C',  35.00, 0, 0, CURRENT_DATE,     FALSE);

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index: farmer_id (equality) first, delivered_on (range) second
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-daily-purchases', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- DEMONSTRATION
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

CALL pr_receive_delivery(3, 'A', 20, CURRENT_DATE);
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 20, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'Z', 20, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- direct SQL cannot bypass pricing, and updates are re-priced
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (1, 'C', 10, 99, 9999, CURRENT_DATE);                 -- bogus rate/value overwritten
UPDATE deliveries SET grade = 'A' WHERE delivery_id = 3;     -- 400 kg: C (1200) becomes A (2000)
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', -5, 0, 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 1;    -- farmer 1 now shows 0
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);                 -- replaces, does not add
SELECT * FROM daily_purchases;