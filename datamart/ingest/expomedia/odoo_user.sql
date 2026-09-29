-- Hak lihat nilai = keanggotaan EFEKTIF grup sales (termasuk lewat implied group), dari Odoo (ADR 0016 #6).
WITH RECURSIVE implies(gid, hid) AS (
  SELECT gid, hid FROM res_groups_implied_rel
  UNION SELECT i.gid, r.hid FROM implies i JOIN res_groups_implied_rel r ON r.gid = i.hid
), grp AS (
  SELECT d.name AS xmlid, d.res_id AS gid FROM ir_model_data d
  WHERE d.model = 'res.groups' AND d.module || '.' || d.name IN
    ('sales_team.group_sale_salesman', 'project.group_project_user', 'cl_expomedia_sale.group_ae')
), eff AS (
  SELECT u.uid, g.xmlid FROM res_groups_users_rel u JOIN grp g ON g.gid = u.gid
  UNION SELECT u.uid, g.xmlid FROM res_groups_users_rel u JOIN implies i ON i.gid = u.gid JOIN grp g ON g.gid = i.hid
)
SELECT u.id, p.name, u.login, u.oauth_uid, u.active,
       EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_sale_salesman'),
       EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_project_user'),
       EXISTS (SELECT 1 FROM eff WHERE eff.uid = u.id AND eff.xmlid = 'group_ae')
FROM res_users u JOIN res_partner p ON p.id = u.partner_id
WHERE u.share IS NOT TRUE
