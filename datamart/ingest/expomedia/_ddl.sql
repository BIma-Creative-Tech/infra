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
-- plan 16: CRM + SCM (pengadaan, logistik, produksi, tagihan vendor) per SPK.
CREATE TABLE IF NOT EXISTS {{schema}}.crm_lead (id int PRIMARY KEY, name text, type text, stage text, status text,
  user_id int, partner_id int, expected_revenue numeric, create_date timestamp, date_closed timestamp, so_id int,
  is_mockup boolean, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.purchase_order (id int PRIMARY KEY, name text, state text, date_approve timestamp,
  date_planned timestamp, vendor text, so_id int, amount_untaxed numeric, amount_total numeric, receipt_status text,
  invoice_status text, effective_date timestamp, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.stock_picking (id int PRIMARY KEY, name text, picking_type text, state text,
  origin text, scheduled_date timestamp, date_done timestamp, so_id int, purchase_id int, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.mrp_production (id int PRIMARY KEY, name text, state text, origin text,
  product_qty numeric, date_start timestamp, date_finished timestamp, so_id int, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.vendor_bill (id int, purchase_id int, name text, state text, move_type text,
  invoice_date date, amount_untaxed numeric, amount_total numeric, amount_residual numeric, payment_state text,
  PRIMARY KEY (id, purchase_id));
-- 2026-10-01: detail dokumen SCM per SPK (baris PO/move/tagihan) + pembayaran ke vendor per tagihan.
CREATE TABLE IF NOT EXISTS {{schema}}.vendor_payment (payment_id int, bill_id int, name text, state text, date date,
  journal text, memo text, amount numeric, PRIMARY KEY (payment_id, bill_id));
CREATE TABLE IF NOT EXISTS {{schema}}.purchase_line (id int PRIMARY KEY, order_id int, sequence int, default_code text,
  product text, description text, qty numeric, qty_received numeric, qty_invoiced numeric, uom text,
  price_unit numeric, price_subtotal numeric);
CREATE TABLE IF NOT EXISTS {{schema}}.stock_move (id int PRIMARY KEY, picking_id int, production_id int,
  raw_material_production_id int, sequence int, default_code text, product text, qty numeric, qty_done numeric,
  uom text, state text);
CREATE TABLE IF NOT EXISTS {{schema}}.vendor_bill_line (id int PRIMARY KEY, move_id int, purchase_line_id int,
  default_code text, product text, description text, qty numeric, uom text, price_subtotal numeric);
-- plan 18 (custom_doc_trace): kunci SPK tagihan vendor (kolom di AKHIR) + isu link dokumen.
ALTER TABLE {{schema}}.vendor_bill ADD COLUMN IF NOT EXISTS so_id int;
CREATE TABLE IF NOT EXISTS {{schema}}.doc_trace_issue (id int PRIMARY KEY, rule_code text, severity text, res_model text,
  res_id int, so_id int, state text, message text, doc_no text, first_seen timestamp, last_seen timestamp,
  fixed_at timestamp, write_date timestamp);
-- plan 19: biaya produksi & margin per SPK (analitik proyek + jenis baris PO) + status BAST (custom_bast).
CREATE TABLE IF NOT EXISTS {{schema}}.analytic_line (id int PRIMARY KEY, so_id int, category text, employee_id int,
  date date, hours numeric, amount numeric, write_date timestamp);
CREATE TABLE IF NOT EXISTS {{schema}}.purchase_line_type (id int PRIMARY KEY, product_type text, is_storable boolean);
CREATE TABLE IF NOT EXISTS {{schema}}.bast (id int PRIMARY KEY, name text, kind text, state text, so_id int,
  location text, date_handover timestamp, party_from text, party_to text, from_signed_at timestamp, from_signed_by text,
  to_signed_at timestamp, to_signed_by text, gps_latitude numeric, gps_longitude numeric, gps_accuracy numeric,
  write_date timestamp);
-- plan 20 #8: SPK per lokasi dalam satu proyek — proyek SPK, nama event & lokasi; baris analitik: proyek + SPK pasti.
ALTER TABLE {{schema}}.sale_order ADD COLUMN IF NOT EXISTS project_id int;
ALTER TABLE {{schema}}.sale_order ADD COLUMN IF NOT EXISTS event_name text;
ALTER TABLE {{schema}}.sale_order ADD COLUMN IF NOT EXISTS location text;
ALTER TABLE {{schema}}.analytic_line ADD COLUMN IF NOT EXISTS project_id int;
ALTER TABLE {{schema}}.analytic_line ADD COLUMN IF NOT EXISTS so_exact boolean;
ALTER TABLE {{schema}}.analytic_line ADD COLUMN IF NOT EXISTS is_expense boolean;
