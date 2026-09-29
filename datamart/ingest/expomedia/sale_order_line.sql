SELECT l.id, l.order_id, l.name, l.price_subtotal, l.product_uom_qty, l.qty_delivered, l.qty_invoiced, l.task_id
FROM sale_order_line l WHERE l.display_type IS NULL
