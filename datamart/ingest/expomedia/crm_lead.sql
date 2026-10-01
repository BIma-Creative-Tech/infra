-- Lead/opportunity CRM (plan 16): langkah pertama Quotation Tracker. Tanpa email/telepon/alamat (minimisasi data).
-- status: won (stage is_won), lost (diarsipkan dengan alasan / probabilitas 0), open. so_id = penawaran pertama.
SELECT l.id, l.name, l.type, coalesce(s.name->>'id_ID', s.name->>'en_US'),
       CASE WHEN s.is_won THEN 'won' WHEN NOT l.active AND (l.lost_reason_id IS NOT NULL OR l.probability = 0) THEN 'lost'
            WHEN NOT l.active THEN 'archived' ELSE 'open' END,
       l.user_id, l.partner_id, l.expected_revenue, l.create_date, l.date_closed,
       (SELECT min(so.id) FROM sale_order so WHERE so.opportunity_id = l.id),
       EXISTS (SELECT 1 FROM crm_tag_rel r JOIN crm_tag t ON t.id = r.tag_id
               WHERE r.lead_id = l.id AND t.name->>'en_US' = 'MOCKUP'),
       l.write_date
FROM crm_lead l LEFT JOIN crm_stage s ON s.id = l.stage_id
