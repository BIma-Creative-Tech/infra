-- Tabel raw per tenant-env (schema {{schema}} = raw_<slug>_<env>). Urutan kolom = urutan SELECT di <tabel>.sql.
-- Hanya kolom yang dibutuhkan mart (minimisasi data, ADR 0016 #1): tanpa NIK/NPWP/alamat/telepon/email.
CREATE TABLE IF NOT EXISTS {{schema}}.sale_order (id int PRIMARY KEY, name text, quotation_name text, legacy_ref text,
  state text, date_order timestamp, partner_id int, partner_invoice_id int, user_id int, amount_untaxed numeric,
  amount_total numeric, invoice_status text, is_mockup boolean, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.sale_order_line (id int PRIMARY KEY, order_id int, name text, price_subtotal numeric,
  qty numeric, qty_delivered numeric, qty_invoiced numeric, task_id int);
CREATE TABLE IF NOT EXISTS {{schema}}.project_task (id int PRIMARY KEY, name text, project_id int, stage_id int,
  sale_line_id int, sale_order_id int, date_deadline timestamp, date_last_stage_update timestamp, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.project_task_type (id int PRIMARY KEY, name text, sequence int, fold boolean);
CREATE TABLE IF NOT EXISTS {{schema}}.invoice (id int PRIMARY KEY, name text, state text, move_type text, invoice_date date,
  amount_untaxed numeric, amount_total numeric, amount_residual numeric, payment_state text);
-- plan 15: kolom baru ditambah di AKHIR (COPY tanpa daftar kolom = urutan kolom tabel; raw lama tidak di-DROP).
ALTER TABLE {{schema}}.invoice ADD COLUMN IF NOT EXISTS invoice_date_due date;
CREATE TABLE IF NOT EXISTS {{schema}}.payment (payment_id int, invoice_id int, name text, state text, date date,
  journal text, memo text, amount numeric, PRIMARY KEY (payment_id, invoice_id));
CREATE TABLE IF NOT EXISTS {{schema}}.invoice_order (invoice_id int, order_id int, PRIMARY KEY (invoice_id, order_id));
CREATE TABLE IF NOT EXISTS {{schema}}.timesheet (id int PRIMARY KEY, date date, employee_id int, task_id int, project_id int,
  order_id int, hours numeric, cost numeric, giat_type text, giat_slot text, description text, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.employee (id int PRIMARY KEY, name text);
CREATE TABLE IF NOT EXISTS {{schema}}.partner (id int PRIMARY KEY, name text, parent_id int, is_company boolean);
CREATE TABLE IF NOT EXISTS {{schema}}.odoo_user (id int PRIMARY KEY, name text, login text, keycloak_sub text,
  active boolean, can_see_value boolean, is_project_user boolean, is_ae boolean);
