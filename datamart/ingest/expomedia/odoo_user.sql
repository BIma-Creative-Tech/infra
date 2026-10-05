-- Hak lihat nilai = keanggotaan EFEKTIF grup (termasuk lewat implied group), dari Odoo (ADR 0016 #6).
-- plan 20 #10: nilai (harga jual) = grup cl_expomedia_sale.group_price_viewer (Finance/Direksi; AE kini anggota sales
-- tanpa harga). DB yang belum punya grup itu (sebelum upgrade cl_expomedia_sale 19.0.2.0.0) → aturan lama: grup sales.
WITH RECURSIVE implies(gid, hid) AS (
  SELECT gid, hid FROM res_groups_implied_rel
  UNION SELECT i.gid, r.hid FROM implies i JOIN res_groups_implied_rel r ON r.gid = i.hid
), grp AS (
  SELECT d.name AS xmlid, d.res_id AS gid FROM ir_model_data d
  WHERE d.model = 'res.groups' AND d.module || '.' || d.name IN
    ('sales_team.group_sale_salesman', 'project.group_project_user', 'cl_expomedia_sale.group_ae',
     'cl_expomedia_sale.group_price_viewer')
), eff AS (
  SELECT u.uid, g.xmlid FROM res_groups_users_rel u JOIN grp g ON g.gid = u.gid
  UNION SELECT u.uid, g.xmlid FROM res_groups_users_rel u JOIN implies i ON i.gid = u.gid JOIN grp g ON g.gid = i.hid
)
SELECT u.id, p.name, u.login, u.oauth_uid, u.active,
       CASE WHEN EXISTS (SELECT 1 FROM grp WHERE xmlid = 'group_price_viewer')
            THEN EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_price_viewer')
            ELSE EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_sale_salesman') END,
       EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_project_user'),
       EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_ae')
FROM res_users u JOIN res_partner p ON p.id = u.partner_id
WHERE u.share IS NOT TRUE
