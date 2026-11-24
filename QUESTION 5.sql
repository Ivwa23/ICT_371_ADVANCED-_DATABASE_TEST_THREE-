DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
-- safety net for concurrent sessions: one ACTIVE allocation per student
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO students (student_number, full_name) VALUES
    ('H001', 'Ann Mulenga'), ('H002', 'Ben Sakala'), ('H003', 'Chola Kunda'),
    ('H004', 'Dina Mwale'),  ('H005', 'Evans Simbeye'), ('H006', 'Faith Kabwe');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE v_cap INTEGER;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;
    RETURN v_cap - (SELECT COUNT(*) FROM allocations
                    WHERE room_id = p_room_id AND status = 'ACTIVE');   -- ENDED ignored
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) < 1 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d) Trigger: same rules for direct SQL
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INTEGER; v_taken INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id %', NEW.room_id;
        END IF;
        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                     AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
        SELECT COUNT(*) INTO v_taken FROM allocations
        WHERE room_id = NEW.room_id AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;     -- exclude the row being updated
        IF v_taken >= v_cap THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- Seed: R101 full, R102 partly occupied, R103 empty
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 20);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 10);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)   -- history only
VALUES (6, 2, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index: partial, only ACTIVE rows (ENDED history is never counted for beds)
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);

-- DEMONSTRATION
SELECT room_id, fn_free_beds(room_id) FROM rooms ORDER BY 1;
DO $$ BEGIN PERFORM fn_free_beds(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(4, 1, CURRENT_DATE);        -- room full
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);        -- student already ACTIVE
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(4, 99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
CALL pr_allocate_room(4, 3, CURRENT_DATE);                    -- valid

-- trigger rejects direct SQL violations
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (4, 2, CURRENT_DATE, 'ACTIVE');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
UPDATE allocations SET allocated_on = allocated_on + 1 WHERE student_id = 1 AND status = 'ACTIVE';
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE student_id = 1 AND status = 'ACTIVE';
CALL pr_allocate_room(5, 1, CURRENT_DATE);

SELECT * FROM v_room_occupancy ORDER BY room_number;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;