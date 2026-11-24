DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('SC001', 'Mwape Chola'), ('SC002', 'Bwalya Musonda'), ('SC003', 'Tamara Njobvu');

-- Six PENDING applications: normal, boundary and failing cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 1500.00, 85.00, CURRENT_DATE - 20),   -- qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 15),   -- all lower boundaries: qualifies
    (2, 25, 2999.99, 70.00, CURRENT_DATE - 10),   -- upper age boundary: qualifies
    (2, 26, 1000.00, 90.00, CURRENT_DATE - 8),    -- too old
    (3, 22, 3000.01, 80.00, CURRENT_DATE - 5),    -- income just over the limit
    (3, 21, 2000.00, 69.99, CURRENT_DATE - 2);    -- mark just under the minimum

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE r applications%ROWTYPE;
BEGIN
    SELECT * INTO r FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;
    IF r.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, r.status;
    END IF;
    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(r.age_at_application, r.monthly_income, r.average_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (e) View (no income column)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index: equality on status first, then the submitted_on range
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status = 'PENDING'              -- completed applications are never touched
             ORDER BY application_id
             FOR UPDATE SKIP LOCKED
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess-pending-applications', '0 8 * * 1', $$CALL pr_assess_pending()$$);

-- DEMONSTRATION
SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_lower_boundaries,   -- true
       fn_scholarship_eligible(25, 2999.99, 70) AS age_25,                 -- true
       fn_scholarship_eligible(26, 1000, 90)    AS age_26,                 -- false
       fn_scholarship_eligible(22, 3000.01, 80) AS income_over,            -- false
       fn_scholarship_eligible(21, 2000, 69.99) AS mark_under;             -- false
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

CALL pr_assess_pending();
CALL pr_assess_pending();                                   -- rerun does nothing
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY 1;
SELECT application_id, old_status, new_status FROM decision_audit ORDER BY audit_id;   -- exactly 6

UPDATE applications SET status = status WHERE application_id = 1;       -- no audit
UPDATE applications SET average_mark = 86 WHERE application_id = 1;     -- no audit
SELECT COUNT(*) AS audit_rows FROM decision_audit;                      -- still 6

SELECT * FROM v_approved_applicants ORDER BY student_number;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'APPROVED' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;