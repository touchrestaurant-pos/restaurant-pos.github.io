-- Server-side reports so figures are exact for any date range (not just what is cached on the device).
create or replace function public.admin_report(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rate numeric;
  r jsonb;
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Reports are for admin and supervisor only';
  end if;
  select vat_rate into v_rate from public.company_settings where id = 1;
  v_rate := coalesce(v_rate, 15);

  with
  o as (select * from public.orders where created_at >= p_from and created_at < p_to),
  sold as (select * from o where status <> 'void' and paid),
  unit_cost as (
    select rl.product_id, sum(rl.qty * si.avg_cost) cost
    from public.recipe_lines rl join public.stock_items si on si.id = rl.stock_item_id group by 1),
  lines as (
    select oi.product_id, oi.name, oi.qty, oi.qty * oi.unit_price rev,
           oi.qty * oi.unit_price * v_rate / (100 + v_rate) vat,
           oi.qty * coalesce(uc.cost, 0) cost
    from public.order_items oi join sold s on s.id = oi.order_id
    left join unit_cost uc on uc.product_id = oi.product_id),
  prod as (
    select l.product_id, coalesce(p.name, l.name) name, coalesce(c.name, 'Other') category,
           sum(l.qty) qty, round(sum(l.rev),2) revenue, round(sum(l.rev - l.vat),2) net,
           round(sum(l.cost),2) cost
    from lines l left join public.products p on p.id = l.product_id
    left join public.categories c on c.id = p.category_id
    group by 1,2,3),
  mv as (
    select m.stock_item_id, m.reason, sum(m.qty_change) qty
    from public.stock_movements m where m.created_at >= p_from and m.created_at < p_to group by 1,2),
  usage14 as (
    select stock_item_id, -sum(qty_change) used
    from public.stock_movements
    where reason in ('sale','sale_void') and created_at >= now() - interval '14 days' group by 1)
  select jsonb_build_object(
    'summary', (select jsonb_build_object(
        'orders', count(*), 'gross', coalesce(round(sum(total),2),0),
        'vat', coalesce(round(sum(vat),2),0), 'net', coalesce(round(sum(subtotal),2),0),
        'avg_order', coalesce(round(avg(total),2),0)) from sold),
    'unpaid', (select jsonb_build_object('orders', count(*), 'total', coalesce(round(sum(total),2),0))
        from o where status <> 'void' and not paid),
    'voided', (select jsonb_build_object('orders', count(*), 'total', coalesce(round(sum(total),2),0))
        from o where status = 'void'),
    'by_day', (select coalesce(jsonb_agg(d order by d->>'day'), '[]') from (
        select jsonb_build_object('day', to_char((created_at at time zone 'Africa/Johannesburg')::date,'YYYY-MM-DD'),
          'orders', count(*), 'total', round(sum(total),2)) d
        from sold group by (created_at at time zone 'Africa/Johannesburg')::date) x),
    'by_hour', (select coalesce(jsonb_agg(h order by (h->>'hour')::int), '[]') from (
        select jsonb_build_object('hour', extract(hour from created_at at time zone 'Africa/Johannesburg')::int,
          'orders', count(*), 'total', round(sum(total),2)) h
        from sold group by extract(hour from created_at at time zone 'Africa/Johannesburg')::int) y),
    'by_type', (select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'orders', n, 'total', t)), '[]') from (
        select order_type, count(*) n, round(sum(total),2) t from sold group by 1) z),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', method, 'count', n, 'amount', t)), '[]') from (
        select p.method, count(*) n, round(sum(p.amount),2) t
        from public.payments p join sold s on s.id = p.order_id group by 1) w),
    'products', (select coalesce(jsonb_agg(to_jsonb(p) order by p.revenue desc), '[]') from prod p),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'qty', q, 'revenue', rv, 'net', nt, 'cost', cs) order by rv desc), '[]') from (
        select category, sum(qty) q, sum(revenue) rv, sum(net) nt, sum(cost) cs from prod group by 1) c),
    'voids', (select coalesce(jsonb_agg(jsonb_build_object('ref', order_ref, 'at', coalesce(voided_at, created_at),
        'total', total, 'paid', paid, 'reason', void_reason) order by coalesce(voided_at, created_at) desc), '[]')
        from o where status = 'void'),
    'usage', (select coalesce(jsonb_agg(jsonb_build_object('item', si.name, 'unit', si.unit, 'category', si.category,
        'sold', coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason in ('sale','sale_void')),0),
        'received', coalesce((select sum(qty) from mv where stock_item_id = si.id and reason = 'grv'),0),
        'waste', coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason = 'waste'),0),
        'adjusted', coalesce((select sum(qty) from mv where stock_item_id = si.id and reason in ('adjustment','stocktake')),0),
        'cost_used', round(coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason in ('sale','sale_void')),0) * si.avg_cost, 2))
        order by si.name), '[]') from public.stock_items si
        where exists (select 1 from mv where stock_item_id = si.id)),
    'reorder', (select coalesce(jsonb_agg(jsonb_build_object('item', si.name, 'unit', si.unit, 'category', si.category,
        'on_hand', si.qty_on_hand, 'min_level', si.min_level,
        'suggested', greatest(si.min_level * 2 - si.qty_on_hand, 0),
        'avg_cost', si.avg_cost,
        'est_cost', round(greatest(si.min_level * 2 - si.qty_on_hand, 0) * si.avg_cost, 2),
        'supplier', coalesce(sp.name, 'No supplier'),
        'daily_use', round(coalesce(u.used,0) / 14, 2),
        'days_left', case when coalesce(u.used,0) > 0 then round(si.qty_on_hand / (u.used / 14), 1) end)
        order by (si.qty_on_hand <= 0) desc, coalesce(sp.name,'zzz'), si.name), '[]')
        from public.stock_items si left join public.suppliers sp on sp.id = si.supplier_id
        left join usage14 u on u.stock_item_id = si.id
        where si.active and si.min_level > 0 and si.qty_on_hand <= si.min_level),
    'valuation', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'items', n, 'value', v) order by v desc), '[]') from (
        select coalesce(category,'Other') category, count(*) n, round(sum(qty_on_hand * avg_cost),2) v
        from public.stock_items where active group by 1) q),
    'valuation_total', (select coalesce(round(sum(qty_on_hand * avg_cost),2),0) from public.stock_items where active),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('supplier', coalesce(sp.name,'Unknown'), 'grvs', n, 'subtotal', st, 'vat', vt, 'total', t) order by t desc), '[]') from (
        select supplier_id, count(*) n, round(sum(subtotal),2) st, round(sum(vat),2) vt, round(sum(total),2) t
        from public.grvs where status = 'posted' and received_on >= (p_from at time zone 'Africa/Johannesburg')::date
          and received_on < (p_to at time zone 'Africa/Johannesburg')::date + 1 group by 1) g
        left join public.suppliers sp on sp.id = g.supplier_id),
    'vat_rate', v_rate
  ) into r;
  return r;
end $$;
revoke all on function public.admin_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_report(timestamptz, timestamptz) to authenticated;
