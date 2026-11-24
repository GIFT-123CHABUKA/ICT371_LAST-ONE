--tables and seed data
CREATE TABLE Students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) UNIQUE NOT NULL,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE Rooms (
  room_id     SERIAL PRIMARY KEY,
  room_number VARCHAR(10) UNIQUE NOT NULL,
  capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE Allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id    INTEGER NOT NULL REFERENCES Students(student_id),
  room_id       INTEGER NOT NULL REFERENCES Rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  -- status/release consistency
  CHECK ((status='ACTIVE' AND released_on IS NULL)
      OR (status='ENDED'  AND released_on IS NOT NULL))
);

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INTEGER NOT NULL REFERENCES Rooms(room_id),
  occupied_beds INTEGER NOT NULL DEFAULT 0,
  free_beds     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO Students(student_number, full_name) VALUES
 ('ST1','Alice'),('ST2','Bob'),('ST3','Carol'),('ST4','Dave'),('ST5','Eve');

INSERT INTO Rooms(room_number, capacity) VALUES
 ('R1', 2),   -- will be full
 ('R2', 3),   -- partial
 ('R3', 2);   -- empty

INSERT INTO Allocations(student_id, room_id, allocated_on, released_on, status) VALUES
 (1,1,'2025-01-01', NULL,         'ACTIVE'),  -- R1 (full: 2/2)
 (2,1,'2025-01-01', NULL,         'ACTIVE'),
 (3,2,'2025-01-01', NULL,         'ACTIVE'),  -- R2 (partial: 1/3)
 (4,2,'2024-06-01','2024-12-31',  'ENDED'),   -- history, doesn't count
 (5,2,'2025-01-01','2025-01-10',  'ENDED');   -- history
-- R3 has no allocation at all (empty room)

--function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_cap INTEGER; v_active INTEGER;
BEGIN
  SELECT capacity INTO v_cap FROM Rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;

  SELECT COUNT(*) INTO v_active
  FROM Allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';   -- ENDED ignored
  RETURN v_cap - v_active;
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
  p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM Students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;

  PERFORM 1 FROM Rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;

  PERFORM 1 FROM Allocations
   WHERE student_id = p_student_id AND status='ACTIVE';
  IF FOUND THEN RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id; END IF;

  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;

  INSERT INTO Allocations(student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END; $$;

--trigger
CREATE OR REPLACE FUNCTION trg_alloc_guard_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_cap INTEGER; v_others INTEGER; v_stud_others INTEGER;
BEGIN
  IF NEW.status <> 'ACTIVE' THEN
    RETURN NEW;                     -- ENDED rows never occupy a bed
  END IF;

  SELECT capacity INTO v_cap FROM Rooms WHERE room_id = NEW.room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', NEW.room_id; END IF;

  SELECT COUNT(*) INTO v_others
  FROM Allocations
  WHERE room_id = NEW.room_id AND status='ACTIVE'
    AND allocation_id <> COALESCE(NEW.allocation_id, -1);   -- exclude self
  IF v_others + 1 > v_cap THEN
    RAISE EXCEPTION 'Room % capacity % exceeded', NEW.room_id, v_cap;
  END IF;

  SELECT COUNT(*) INTO v_stud_others
  FROM Allocations
  WHERE student_id = NEW.student_id AND status='ACTIVE'
    AND allocation_id <> COALESCE(NEW.allocation_id, -1);
  IF v_stud_others > 0 THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
  END IF;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_alloc_guard
BEFORE INSERT OR UPDATE ON Allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_guard_fn();

--view
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number,
       r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS free_beds
FROM Rooms r
LEFT JOIN Allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

--index
CREATE INDEX idx_alloc_active_room
  ON Allocations(room_id) WHERE status = 'ACTIVE';

EXPLAIN
SELECT * FROM Allocations
WHERE room_id = 2 AND status = 'ACTIVE';

--scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id,
         COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE'),
         r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE')
  FROM Rooms r
  LEFT JOIN Allocations a ON a.room_id = r.room_id
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END; $$;

SELECT cron.schedule('refresh_occupancy', '55 23 * * *',
                     $$CALL pr_refresh_occupancy()$$);



					 