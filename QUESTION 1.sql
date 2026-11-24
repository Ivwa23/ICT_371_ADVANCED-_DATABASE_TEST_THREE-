DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Tables
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(80)   NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  30),
    ('Ibuprofen 400mg',   4.00,  20);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END $$;

-- (c) Procedure (any RAISE aborts the call, so an invalid sale changes nothing)
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- Six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 12, CURRENT_DATE - 2);
CALL pr_record_sale(3,  8, CURRENT_DATE - 1);
CALL pr_record_sale(3,  5, CURRENT_DATE);
CALL pr_record_sale(2, 10, CURRENT_DATE);

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- (f) Index: equality on medicine_id, then a range on sold_on = one contiguous slice
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-daily-sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);

-- DEMONSTRATION
SELECT fn_sale_value(1, 4);
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

SELECT (SELECT SUM(stock_qty) FROM medicines) AS stock_before, (SELECT COUNT(*) FROM sales) AS sales_before;
DO $$ BEGIN CALL pr_record_sale(1, 1000, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_sale(42, 1, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT (SELECT SUM(stock_qty) FROM medicines) AS stock_after, (SELECT COUNT(*) FROM sales) AS sales_after;

SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM medicines ORDER BY medicine_id;
SELECT audit_id, medicine_id, old_qty, new_qty FROM stock_audit ORDER BY audit_id;

SELECT * FROM v_low_stock;                    -- view queried after the sales

SET enable_seqscan = off;                     -- only because the demo table is tiny
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);      -- rerun: still one row, no double count
SELECT * FROM daily_sales;