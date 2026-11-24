CREATE TABLE vehicles (
  vehicle_id           SERIAL PRIMARY KEY,
  registration         VARCHAR(20) UNIQUE NOT NULL,
  current_odometer     NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
  CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
  trip_id        SERIAL PRIMARY KEY,
  vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
  end_odometer   NUMERIC(12,2) NOT NULL CHECK (end_odometer   >= 0),
  CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
  vehicle_id      INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service NUMERIC(12,2) NOT NULL,
  flagged_on       DATE NOT NULL
);

INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('ABC123', 12000,  5000),   -- 7000 since service → due
 ('DEF456',  8000,  7000),   -- 1000 → not due
 ('GHI789', 20000, 14000);   -- 6000 → due

 --function
 CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_cur NUMERIC; v_last NUMERIC;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
  RETURN (v_cur - v_last) >= 5000;
END; $$;


--procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
  p_vehicle_id INTEGER, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;

  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
  END IF;

  INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);  -- trigger advances odometer
END; $$;

--six trips
CALL pr_record_trip(1,'2025-02-01',12000,12100);
CALL pr_record_trip(1,'2025-02-02',12100,12300);
CALL pr_record_trip(1,'2025-02-03',12300,12400);
CALL pr_record_trip(2,'2025-02-01', 8000, 8100);
CALL pr_record_trip(2,'2025-02-02', 8100, 8300);
CALL pr_record_trip(3,'2025-02-01',20000,20100);

--trigger
CREATE OR REPLACE FUNCTION trg_trip_meter_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_cur NUMERIC;
BEGIN
  SELECT current_odometer INTO v_cur
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id; END IF;

  IF NEW.start_odometer <> v_cur THEN
    RAISE EXCEPTION 'Start % does not match current odometer %', NEW.start_odometer, v_cur;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end must exceed start';
  END IF;

  UPDATE vehicles
     SET current_odometer = NEW.end_odometer
   WHERE vehicle_id = NEW.vehicle_id;         -- advances exactly once
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_trip_meter
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_meter_fn();

--view
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

--index
CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id, trip_on);

EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN '2025-02-01' AND '2025-02-28';

--schedule job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  -- insert / refresh alerts for currently due vehicles
  INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

  -- remove alerts that are no longer due
  DELETE FROM service_alerts sa
  WHERE NOT EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer >= 5000
  );
END; $$;

-- Every Monday at 06:00
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);