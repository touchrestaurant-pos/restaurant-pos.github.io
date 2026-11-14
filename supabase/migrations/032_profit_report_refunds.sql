-- Profit report: refunds on cancelled (void) orders are no longer taken off sales a second time
-- (the cancelled sale is already left out), and refund VAT follows each item's VAT type,
-- using the same split as the VAT report so the two reports agree.
create or replace function public.profit_report(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare tz text := public.app_tz(); v_from timestamptz; v_to timestamptz;
  v_sales numeric; v_net_excl numeric; v_vat_out numeric; v_cos numeric; v_waste numeric;
  v_exp numeric; v_exp_vat numeric; v_in_vat numeric; v_purch numeric; v_vr jsonb;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'The profit report is for the admin only'; end if;
  v_from := p_from::timestamp at time zone tz;
  v_to := (p_to + 1)::timestamp at time zone tz;
  select coalesce(sum(subtotal), 0) into v_sales
    from public.orders where created_at >= v_from and created_at < v_to and status <> 'void' and paid;
  v_vr := public.vat_report(v_from, v_to);   -- sales less refunds, split by VAT type
  select coalesce(sum((x->>'excl')::numeric), 0), coalesce(sum((x->>'vat')::numeric), 0)
    into v_net_excl, v_vat_out from jsonb_array_elements(v_vr) x;
  select coalesce(sum(oi.qty * coalesce(oi.unit_cost, 0)), 0) into v_cos
    from public.order_items oi join public.orders o on o.id = oi.order_id
    where o.created_at >= v_from and o.created_at < v_to and o.status <> 'void' and o.paid and not oi.voided;
  select coalesce(-sum(m.qty_change * si.avg_cost), 0) into v_waste
    from public.stock_movements m join public.stock_items si on si.id = m.stock_item_id
    where m.reason = 'waste' and m.created_at >= v_from and m.created_at < v_to;
  select coalesce(sum(amount - vat_amount), 0), coalesce(sum(vat_amount), 0) into v_exp, v_exp_vat
    from public.expenses where spent_on between p_from and p_to;
  select coalesce(sum(vat), 0), coalesce(sum(subtotal), 0) into v_in_vat, v_purch
    from public.grvs where status = 'posted' and received_on between p_from and p_to;
  return jsonb_build_object(
    'sales_excl', round(v_sales, 2),
    'refunds_excl', round(v_sales - v_net_excl, 2),
    'net_sales', round(v_net_excl, 2),
    'cost_of_sales', round(v_cos, 2),
    'waste', round(v_waste, 2),
    'gross_profit', round(v_net_excl - v_cos - v_waste, 2),
    'expenses', round(v_exp, 2),
    'net_profit', round(v_net_excl - v_cos - v_waste - v_exp, 2),
    'expense_categories', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'amount', a) order by a desc), '[]'::jsonb)
        from (select category, round(sum(amount - vat_amount), 2) a from public.expenses where spent_on between p_from and p_to group by 1) e),
    'purchases_excl', round(v_purch, 2),
    'vat_output', round(v_vat_out, 2),
    'vat_input_purchases', round(v_in_vat, 2),
    'vat_input_expenses', round(v_exp_vat, 2),
    'vat_payable', round(v_vat_out - v_in_vat - v_exp_vat, 2));
end $function$;

-- Reports > Sales "After refunds": same rule (refunds on cancelled orders are not taken off sales that were never counted).
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_report' and p.prokind = 'f';
  if d like '%rf as (select * from public.refunds where created_at >= p_from and created_at < p_to)%' then
    d := replace(d, 'rf as (select * from public.refunds where created_at >= p_from and created_at < p_to)',
      'rf as (select r.* from public.refunds r join public.orders ro on ro.id = r.order_id where r.created_at >= p_from and r.created_at < p_to and ro.status <> ''void'')');
    execute d;
  end if;
end $$;
