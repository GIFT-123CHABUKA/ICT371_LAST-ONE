--table and seed data
CREATE TABLE Books (
  book_id SERIAL PRIMARY KEY,
  title   VARCHAR(200) NOT NULL
);

CREATE TABLE Loans (
  loan_id       SERIAL PRIMARY KEY,
  book_id       INTEGER NOT NULL REFERENCES Books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0,
  CHECK (due_on >= borrowed_on),
  CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
  audit_id        SERIAL PRIMARY KEY,
  loan_id         INTEGER NOT NULL REFERENCES Loans(loan_id),
  old_returned_on DATE,
  new_returned_on DATE,
  changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INTEGER NOT NULL DEFAULT 0,
  total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO Books(title) VALUES
 ('Intro to SQL'), ('Database Systems'), ('Algorithms');

INSERT INTO Loans(book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
 (1,'Alice','2024-12-01','2024-12-15', NULL,         0),   -- open overdue
 (2,'Bob',  '2024-12-01','2024-12-20','2024-12-15', 0),   -- on time
 (3,'Carol','2024-12-01','2024-12-10','2024-12-20', 20),  -- returned late
 (1,'Dave', '2024-12-05','2025-01-05', NULL,         0),
 (2,'Eve',  '2024-12-10','2025-01-10', NULL,         0),
 (3,'Frank','2024-12-15','2025-01-15', NULL,         0);

 --function
 CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_returned DATE; v_end DATE; v_days INTEGER;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_returned
    FROM Loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;

  v_end  := LEAST(p_as_of, COALESCE(v_returned, p_as_of));  -- earlier of the two
  v_days := v_end - v_due;
  IF v_days < 0 THEN v_days := 0; END IF;
  RETURN v_days * 2;
END; $$;

--procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE; v_fine NUMERIC;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM Loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;
  IF v_returned IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % already returned', p_loan_id;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date before borrowed date';
  END IF;

  v_fine := fn_loan_fine(p_loan_id, p_returned_on);   -- returned_on still NULL here
  UPDATE Loans
     SET returned_on = p_returned_on,
         fine_amount = v_fine
   WHERE loan_id = p_loan_id;                        -- one atomic update
END; $$;

--tigger
CREATE OR REPLACE FUNCTION trg_loan_audit_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
    INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON Loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit_fn();

--view
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine
FROM Loans l
JOIN Books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

  --index
  -- Partial index: only unreturned loans need to be searched
CREATE INDEX idx_loans_book_unreturned
  ON Loans(book_id) WHERE returned_on IS NULL;

EXPLAIN
SELECT * FROM Loans
WHERE book_id = 1 AND returned_on IS NULL;

--Schedule job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
  SELECT p_as_of,
         COUNT(*),
         COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)),0)
  FROM Loans
  WHERE returned_on IS NULL
    AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END; $$;

SELECT cron.schedule('refresh_overdue', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

					 