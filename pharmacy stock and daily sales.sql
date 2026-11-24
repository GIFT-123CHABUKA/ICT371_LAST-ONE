--Tables and seed data
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INTEGER NOT NULL,
  new_qty     INTEGER NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INTEGER NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol', 5.00, 100),
 ('Amoxicillin', 12.50, 50),
 ('Ibuprofen',   8.00, 30);

 --Function
 CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine id %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END; $$;

--Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(
  p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_stock INTEGER; v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;

  SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;                        -- lock, prevents overselling race
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: have %, need %', v_stock, p_quantity;
  END IF;

  INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

  UPDATE medicines SET stock_qty = stock_qty - p_quantity
   WHERE medicine_id = p_medicine_id;   -- exactly once
END; $$;


--Trigger
CREATE OR REPLACE FUNCTION trg_stock_audit_fn() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
    INSERT INTO stock_audit(medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_stock_audit_fn();

--View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- after a sale, e.g. CALL pr_record_sale(3, 25, CURRENT_DATE);
SELECT * FROM v_low_stock;

--index
CREATE INDEX idx_sales_medicine_date ON sales(medicine_id, sold_on);

EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN '2025-01-01' AND '2025-01-31';

  --Scheduled job
  CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales(sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity),0),
         COALESCE(SUM(quantity * unit_price),0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;   -- replace, never add
END; $$;

-- Daily at 00:15 for the previous day
SELECT cron.schedule('refresh_daily_sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);