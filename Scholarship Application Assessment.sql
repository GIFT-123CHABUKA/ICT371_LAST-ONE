--table and seed data
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) UNIQUE NOT NULL,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
  application_id     SERIAL PRIMARY KEY,
  student_id         INTEGER NOT NULL REFERENCES students(student_id),
  age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
  audit_id       SERIAL PRIMARY KEY,
  application_id INTEGER NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10),
  new_status     VARCHAR(10),
  changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students(student_number, full_name) VALUES
 ('S1','Alice'),('S2','Bob'),('S3','Carol'),('S4','Dave');

INSERT INTO applications(student_id, age_at_application, monthly_income,
                         average_mark, submitted_on, status) VALUES
 (1,18,3000, 70.00,'2025-01-10','PENDING'),  -- boundaries, qualifying
 (2,25,2500, 85.00,'2025-01-11','PENDING'),  -- qualifying
 (3,17,2000, 90.00,'2025-01-12','PENDING'),  -- fails age
 (3,22,3500, 90.00,'2025-01-13','PENDING'),  -- fails income
 (4,20,1000, 69.99,'2025-01-14','PENDING'),  -- fails mark
 (1,26,3000, 75.00,'2025-01-15','PENDING');  -- fails age

 --fuction
 CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
  p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Inputs must not be null';
  END IF;
  IF p_income < 0             THEN RAISE EXCEPTION 'Income must be non-negative'; END IF;
  IF p_age <= 0               THEN RAISE EXCEPTION 'Age must be positive'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be 0..100'; END IF;

  RETURN (p_age BETWEEN 18 AND 25) AND (p_income <= 3000) AND (p_mark >= 70);
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE a applications%ROWTYPE; v_ok BOOLEAN; v_new VARCHAR(10);
BEGIN
  SELECT * INTO a FROM applications
   WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application %', p_application_id; END IF;
  IF a.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % already assessed (% )', p_application_id, a.status;
  END IF;

  v_ok  := fn_scholarship_eligible(a.age_at_application, a.monthly_income, a.average_mark);
  v_new := CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END;

  UPDATE applications SET status = v_new WHERE application_id = p_


  --trigger
  CREATE OR REPLACE FUNCTION trg_decision_audit_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit_fn();

--view 
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';
-- household income deliberately not exposed

--index
CREATE INDEX idx_apps_status_submitted
  ON applications(status, submitted_on);

EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN '2025-01-01' AND '2025-01-31';

  --scheduled job
  CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id
             FROM applications
            WHERE status = 'PENDING'
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END; $$;

-- Every Monday at 08:00
SELECT cron.schedule('assess_pending', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);