--table and seed data
[11:11 PM, 11/24/2026] gifu🥰: CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
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
[11:16 PM, 11/24/2026] gifu🥰: CREATE TABLE employees (
  employee_id  SERIAL PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id  SERIAL PRIMARY KEY,
  employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL,
  net_pay     NUMERIC(12,2) NOT NULL,
  UNIQUE (employee_id, pay_month),
  CHECK (pay_month = date_trunc('month', pay_month)::date)  -- month-start only
);

CREATE TABLE salary_audit (
  audit_id    SERIAL PRIMARY KEY,
  employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2),
  new_salary  NUMERIC(12,2),
  changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice', 5000, 500,  800, TRUE),
 ('Bob',   4000, 300,  600, TRUE),
 ('Carol', 6000, 600, 1000, FALSE);

INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay) VALUES
 (1,'2025-01-01',5500,4700),
 (2,'2025-01-01',4300,3700),
 (1,'2025-02-01',5500,4700),
 (2,'2025-02-01',4300,3700);

 --function
 CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE e employees%ROWTYPE; v_net NUMERIC;
BEGIN
  SELECT * INTO e FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee %', p_employee_id; END IF;

  v_net := e.basic_salary + e.allowance - e.deduction;
  IF v_net < 0 THEN RAISE EXCEPTION 'Negative net pay for %', p_employee_id; END IF;
  RETURN v_net;
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_gross NUMERIC; v_net NUMERIC;
BEGIN
  IF p_month <> date_trunc('month', p_month)::date THEN
    RAISE EXCEPTION 'p_month must be the first day of a month';
  END IF;

  FOR r IN SELECT * FROM employees WHERE active = TRUE LOOP
    v_gross := r.basic_salary + r.allowance;
    v_net   := fn_net_pay(r.employee_id);        -- raises → whole call fails

    INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, v_gross, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- keep existing row
  END LOOP;
END; $$;

--trigger
CREATE OR REPLACE FUNCTION trg_salary_audit_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
    INSERT INTO salary_audit(employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit_fn();

--view
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;
-- no "active" filter → historic rows of now-inactive employees are included

--index
CREATE INDEX idx_payroll_month ON payroll(pay_month);

--scheduled job
-- 02:00 on the 1st of each month, previous month's first date
SELECT cron.schedule(
  'process_monthly_payroll',
  '0 2 1 * *',
  $$CALL pr_process_payroll(
       (date_trunc('month', CURRENT_DATE - INTERVAL '1 month'))::date)$$
);

-- Inspect the job and its run history:
SELECT jobid, schedule, command, active FROM cron.job;
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 20;