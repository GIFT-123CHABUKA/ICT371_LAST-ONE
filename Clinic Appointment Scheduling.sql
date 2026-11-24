--tavle and seed data
CREATE TABLE Patients (
  patient_id SERIAL PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE Doctors (
  doctor_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
  appointment_id SERIAL PRIMARY KEY,
  patient_id     INTEGER NOT NULL REFERENCES Patients(patient_id),
  doctor_id      INTEGER NOT NULL REFERENCES Doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time      TIME NOT NULL
                 CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  status         VARCHAR(10) NOT NULL
                 CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INTEGER NOT NULL DEFAULT 0,
  attended_count  INTEGER NOT NULL DEFAULT 0,
  cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO Patients(full_name) VALUES ('P1'),('P2'),('P3');
INSERT INTO Doctors(full_name)  VALUES ('Dr A'),('Dr B'),('Dr C');

INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1,1,'2025-03-01','09:00','BOOKED'),
 (2,1,'2025-03-01','10:00','BOOKED'),
 (3,2,'2025-03-01','09:00','BOOKED'),
 (1,2,'2025-03-01','11:00','ATTENDED'),
 (2,3,'2025-03-02','09:00','BOOKED'),
 (3,3,'2025-03-02','12:00','CANCELLED');

 --function
 CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM 1 FROM Doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;

  SELECT COUNT(*) INTO v_count
  FROM appointments
  WHERE doctor_id = p_doctor_id
    AND appointment_day = p_day
    AND status <> 'CANCELLED';
  RETURN v_count;     -- 0 when no bookings
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
  p_patient_id INTEGER, p_doctor_id INTEGER, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM Patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient %', p_patient_id; END IF;

  PERFORM 1 FROM Doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;

  IF p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Cannot book a past date';
  END IF;
  IF p_slot NOT IN ('09:00'::TIME,'10:00'::TIME,'11:00'::TIME,'12:00'::TIME) THEN
    RAISE EXCEPTION 'Unsupported slot %', p_slot;
  END IF;

  INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END; $$;

--trigger
CREATE OR REPLACE FUNCTION trg_appt_clash_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_cnt INTEGER;
BEGIN
  IF NEW.status = 'CANCELLED' THEN
    RETURN NEW;                                  -- cancelled never blocks
  END IF;

  SELECT COUNT(*) INTO v_cnt
  FROM appointments
  WHERE doctor_id       = NEW.doctor_id
    AND appointment_day = NEW.appointment_day
    AND slot_time       = NEW.slot_time
    AND status <> 'CANCELLED'
    AND appointment_id <> COALESCE(NEW.appointment_id, -1);  -- exclude self on UPDATE
  IF v_cnt > 0 THEN
    RAISE EXCEPTION 'Slot clash for doctor % on % at %',
      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_appt_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appt_clash_fn();

--view
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN Patients p ON p.patient_id = a.patient_id
JOIN Doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

  --index
  CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day, doctor_id);

EXPLAIN
SELECT * FROM appointments
WHERE appointment_day = '2025-03-01' AND doctor_id = 1;

--scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status='BOOKED'),
         COUNT(*) FILTER (WHERE status='ATTENDED'),
         COUNT(*) FILTER (WHERE status='CANCELLED')
  FROM appointments
  WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END; $$;

SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);



