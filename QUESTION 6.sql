DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT ck_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Peter Mwansa',   8000.00, 1500.00, 1200.00, TRUE),
    ('Ruth Chikwanda', 6500.00, 1000.00,  900.00, TRUE),
    ('Samuel Tonga',   7200.00,  800.00, 1000.00, TRUE),
    ('Lucy Nkonde',    5000.00,  500.00,  700.00, TRUE);   -- becomes inactive below

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) Procedure (one call = one transaction: any failure undoes every insert)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r       RECORD;
    v_gross NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;
    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(r.employee_id);
        v_gross := r.basic_salary + r.allowance;
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;     -- existing rows stay unchanged
    END LOOP;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- Two payroll months, then one employee goes inactive and one salary changes
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;

-- (e) View (no filter on active, so history of inactive employees stays)
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index: the UNIQUE (employee_id, pay_month) index leads with employee_id, so it cannot
--     efficiently serve "all employees for one month". An index on pay_month alone can.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- (g) Scheduled job: 02:00 on day 1, for the previous month
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('monthly-payroll', '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history:
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly-payroll')
ORDER BY start_time DESC;

-- DEMONSTRATION
SELECT fn_net_pay(1);
DO $$ BEGIN PERFORM fn_net_pay(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

CALL pr_process_payroll(DATE '2026-10-01');       -- rerun changes nothing
SELECT pay_month, COUNT(*) AS rows, SUM(net_pay) AS total_net FROM payroll GROUP BY pay_month ORDER BY 1;

CALL pr_process_payroll(DATE '2026-11-01');       -- only the 3 active employees
SELECT pay_month, COUNT(*) FROM payroll WHERE pay_month = '2026-11-01' GROUP BY 1;

DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-15');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$
BEGIN
    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;   -- negative net pay
    CALL pr_process_payroll(DATE '2026-12-01');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Whole call failed as expected: %', SQLERRM;
    RAISE NOTICE 'December rows stored: %', (SELECT COUNT(*) FROM payroll WHERE pay_month = '2026-12-01');
END $$;

UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;   -- unchanged: no audit
UPDATE employees SET allowance = 1100 WHERE employee_id = 2;              -- other column: no audit
SELECT employee_id, old_salary, new_salary FROM salary_audit;

SELECT * FROM v_payroll_report WHERE employee_id = 4 ORDER BY pay_month;  -- inactive employee's history

SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;