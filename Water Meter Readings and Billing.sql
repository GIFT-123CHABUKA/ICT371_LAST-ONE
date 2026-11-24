--tables and seed data
CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
  reading_id       SERIAL PRIMARY KEY,
  customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL,
  previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
  UNIQUE (customer_id, reading_month),
  CHECK (current_reading >= previous_reading)
);

CREATE TABLE bills (
  bill_id     SERIAL PRIMARY KEY,
  reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO customers(full_name) VALUES ('Cust A'),('Cust B'),('Cust C');

-- consumption = current - previous
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1,'2025-01-01',100,100),   -- 0 units
 (1,'2025-02-01',100,110),   -- exactly 10
 (2,'2025-01-01', 50, 75),   -- 25 units (>10)
 (2,'2025-02-01', 75, 80),   -- 5 units
 (3,'2025-01-01',200,210),   -- 10 units
 (3,'2025-02-01',210,230);   -- 20 units

 --function
 CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v NUMERIC;
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Consumption must be non-negative';
  END IF;
  IF p_units <= 10 THEN
    v := p_units * 5;
  ELSE
    v := 10 * 5 + (p_units - 10) * 8;     -- first 10 @5, rest @8
  END IF;
  RETURN ROUND(v, 2);
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE r readings%ROWTYPE; v_units NUMERIC; v_charge NUMERIC;
BEGIN
  SELECT * INTO r FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading %', p_reading_id; END IF;

  PERFORM 1 FROM bills WHERE reading_id = p_reading_id;
  IF FOUND THEN
    RAISE EXCEPTION 'Bill already exists for reading %', p_reading_id;
  END IF;

  v_units  := r.current_reading - r.previous_reading;
  v_charge := fn_water_charge(v_units);

  INSERT INTO bills(reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, v_charge, 0, p_due_on);
END; $$;

--tigger
CREATE OR REPLACE FUNCTION trg_reading_check_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading % below previous_reading %',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check_fn();

--view
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on,
       (b.charge - b.amount_paid) AS outstanding
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

  --index
  CREATE INDEX idx_bills_due_unpaid
  ON bills(due_on) WHERE amount_paid < charge;

EXPLAIN
SELECT * FROM bills
WHERE due_on < CURRENT_DATE AND amount_paid < charge;

--scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot(snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid),0)
  FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END; $$;

SELECT cron.schedule('refresh_receivables', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);

