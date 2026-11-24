DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer   >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAE 1001', 10000,  8000),     -- 2,000 km since service
    ('BAF 2002', 20000, 14500),     -- 5,500 km: already due
    ('BAG 3003',  1000,  1000);     -- just serviced

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- (c) Procedure: validates and inserts only; the trigger moves the odometer
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)', NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), not %', v_current, NEW.start_odometer;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer     -- the only place this happens
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- Six trips through the procedure
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10800);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10800, 11500);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 20900);
CALL pr_record_trip(3, CURRENT_DATE - 4,  1000,  1400);
CALL pr_record_trip(3, CURRENT_DATE - 1,  1400,  1900);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index: equality on vehicle_id, then a range on trip_on
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id, v.current_odometer - v.last_service_odometer, CURRENT_DATE
    FROM vehicles v WHERE fn_service_due(v.vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa WHERE NOT fn_service_due(sa.vehicle_id);   -- no longer due
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-service-alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);

-- DEMONSTRATION
SELECT vehicle_id, fn_service_due(vehicle_id) FROM vehicles ORDER BY 1;
DO $$ BEGIN PERFORM fn_service_due(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

SELECT vehicle_id, current_odometer FROM vehicles ORDER BY 1;     -- 11500, 20900, 1900

DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 1, 2);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 11500, 11500);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 11000, 11600);   -- wrong start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
            VALUES (1, CURRENT_DATE, 11500, 11400);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT current_odometer FROM vehicles WHERE vehicle_id = 1;       -- unchanged: 11500

SELECT * FROM v_service_due;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                                 -- idempotent
SELECT * FROM service_alerts;                                     -- vehicle 2 only
CALL pr_record_trip(1, CURRENT_DATE, 11500, 15500);               -- vehicle 1 now due
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                 -- vehicles 1 and 2
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                 -- vehicle 2 removed

SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;