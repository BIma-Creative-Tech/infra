SELECT m.id, m.name, m.state, m.move_type, m.invoice_date, m.amount_untaxed, m.amount_total, m.amount_residual,
       m.payment_state, m.invoice_date_due
FROM account_move m WHERE m.move_type IN ('out_invoice', 'out_refund')
