--table and seed data
CREATE TABLE Students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) UNIQUE NOT NULL,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE Payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INTEGER NOT NULL REFERENCES Students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   SERIAL PRIMARY KEY,
  payment_id INTEGER NOT NULL REFERENCES Payments(payment_id),
  student_id INTEGER NOT NULL REFERENCES Students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INTEGER NOT NULL DEFAULT 0,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO Students(student_number, full_name, fee_due) VALUES
 ('S001','Alice Banda', 5000.00),
 ('S002','Bob Phiri',   7000.00),
 ('S003','Carol Mwale', 4000.00);   -- initially no payments

INSERT INTO Payments(student_id, amount, paid_on) VALUES
 (1, 2000, '2025-02-01'),
 (1, 1000, '2025-02-05'),
 (1,  500, '2025-02-10'),
 (2, 3000, '2025-02-01'),
 (2, 2000, '2025-02-12'),
 (2, 1000, '2025-02-15');

 --function
 CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
  SELECT fee_due INTO v_due FROM Students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
  SELECT COALESCE(SUM(amount),0) INTO v_paid
    FROM Payments WHERE student_id = p_student_id;
  RETURN v_due - v_paid;      -- full fee if no payments (SUM → 0)
END; $$;

--Pocedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
  p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;
  v_balance := fn_fee_balance(p_student_id);   -- also rejects unknown student
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO Payments(student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);   -- fee_due untouched
END; $$;

--Trigger
CREATE OR REPLACE FUNCTION trg_payment_audit_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON Payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit_fn();

--View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM Students s
LEFT JOIN Payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount),0) > 0;   -- exclude fully settled

--Index
CREATE INDEX idx_payments_student_date ON Payments(student_id, paid_on);

EXPLAIN
SELECT * FROM Payments
WHERE student_id = 2 AND paid_on BETWEEN '2025-02-01' AND '2025-02-28';

--Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections(collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount),0)
  FROM Payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END; $$;

SELECT cron.schedule('refresh_daily_collections', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
					 

 