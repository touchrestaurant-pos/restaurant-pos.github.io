-- Refunds: safe to retry, paid back the way they were paid, and taken off the VAT report.

-- 1. issue_refund takes an optional id so a retry after a bad connection cannot refund twice,
--    and cash / card refunds cannot be more than was paid that way.
drop function if exists public.issue_refund(uuid, numeric, public.pay_method, text, boolean);
create or replace function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text,
                                               p_restock boolean default false, p_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $function$
declare v_total numeric; v_paid boolean; v_done numeric; v_status public.order_status; v_frac numeric;
        v_acct_paid numeric; v_acct_back numeric; v_acct uuid; v_accts int; v_rid uuid;
        v_m_paid numeric; v_m_back numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can refund';
  end if;
  if p_id is not null and exists (select 1 from public.refunds where id = p_id) then return; end if;
  select total, paid, status into v_total, v_paid, v_status from public.orders where id = p_order_id;
  if v_total is null then raise exception 'Order not found'; end if;
  if not v_paid then raise exception 'This order was never paid, nothing to refund'; end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = p_order_id;
  if p_amount <= 0 or p_amount > v_total - v_done + 0.001 then
    raise exception 'Refund must be more than 0 and no more than R% (still refundable)', (v_total - v_done);
  end if;
  if p_restock and v_status = 'void' then
    raise exception 'This order was cancelled, so its ingredients were already put back in stock';
  end if;
  select coalesce(sum(amount),0), min(account_id::text)::uuid, count(distinct account_id)
    into v_acct_paid, v_acct, v_accts from public.payments where order_id = p_order_id and method::text = 'account';
  select coalesce(sum(amount),0) into v_acct_back from public.refunds where order_id = p_order_id and method::text = 'account';
  if p_method::text = 'account' then
    if v_acct_paid <= 0 then raise exception 'This order was not paid on an account'; end if;
    if v_accts > 1 then raise exception 'This order was paid on more than one account. Ask the admin.'; end if;
    if p_amount > v_acct_paid - v_acct_back + 0.001 then
      raise exception 'Only R% of this order is still on the account.', (v_acct_paid - v_acct_back);
    end if;
  else
    select coalesce(sum(amount),0) into v_m_paid from public.payments where order_id = p_order_id and method = p_method;
    select coalesce(sum(amount),0) into v_m_back from public.refunds where order_id = p_order_id and method = p_method;
    if p_amount > v_m_paid - v_m_back + 0.001 then
      raise exception 'Only R% of this order was paid that way (%). Refund it the way it was paid.',
        to_char(greatest(v_m_paid - v_m_back, 0), 'FM999999990.00'),
        case p_method::text when 'cash' then 'cash' when 'card_manual' then 'card' else p_method::text end;
    end if;
    if v_acct_paid > 0 and p_amount > (v_total - v_acct_paid) - (v_done - v_acct_back) + 0.001 then
      raise exception 'Only R% of this order was paid with cash or card. Refund the rest to the account.',
        ((v_total - v_acct_paid) - (v_done - v_acct_back));
    end if;
  end if;
  insert into public.refunds(id, order_id, amount, method, reason, restocked)
    values (coalesce(p_id, gen_random_uuid()), p_order_id, round(p_amount,2), p_method, trim(p_reason), p_restock)
    returning id into v_rid;
  if p_method::text = 'account' then
    insert into public.account_transactions(account_id, kind, amount, order_id, refund_id, note, business_date)
    values (v_acct, 'credit_note', -round(p_amount, 2), p_order_id, v_rid, trim(p_reason),
            (now() at time zone public.app_tz())::date);
  end if;
  if p_restock and v_total > 0 then
    v_frac := least(p_amount / v_total, 1);
    insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id, note)
    select x.stock_item_id, round(least(x.used * v_frac, x.used - x.back), 3), 'sale_void'::public.move_reason, x.ref_id, 'Refund restock'
    from (
      select m.ref_id, m.stock_item_id,
             -sum(m.qty_change) filter (where m.reason = 'sale') used,
             coalesce(sum(m.qty_change) filter (where m.reason = 'sale_void'), 0) back
      from public.stock_movements m join public.order_items oi on oi.id = m.ref_id
      where oi.order_id = p_order_id and not oi.voided and m.reason in ('sale','sale_void')
      group by m.ref_id, m.stock_item_id
    ) x
    where x.used > 0 and round(least(x.used * v_frac, x.used - x.back), 3) > 0;
  end if;
end $function$;
revoke execute on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean, uuid) from public, anon;
grant execute on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean, uuid) to authenticated;

-- 2. The VAT report takes refunds (credit notes) off, split across the order's VAT types, in the period the refund was given.
create or replace function public.vat_report(p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $function$
declare v_rate numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Reports are for admin and supervisor only';
  end if;
  select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
  return (
    with sold as (
      select * from public.orders where created_at >= p_from and created_at < p_to and status <> 'void' and paid
    ), li as (
      select oi.order_id, oi.vat_type, oi.qty * oi.unit_price line from public.order_items oi
      join sold s on s.id = oi.order_id where not oi.voided
    ), tot as (select order_id, sum(line) items from li group by order_id),
    alloc as (
      select li.vat_type, li.line * coalesce(s.total / nullif(t.items, 0), 1) sales
      from li join sold s on s.id = li.order_id join tot t on t.order_id = li.order_id
    ),
    refs as (
      select r.order_id, r.amount from public.refunds r join public.orders o on o.id = r.order_id
      where r.created_at >= p_from and r.created_at < p_to and o.status <> 'void' and o.paid
    ), li_r as (
      select oi.order_id, oi.vat_type, oi.qty * oi.unit_price line from public.order_items oi
      where not oi.voided and oi.order_id in (select order_id from refs)
    ), tot_r as (select order_id, sum(line) items from li_r group by order_id),
    alloc_r as (
      select l.vat_type, -(rf.amount * l.line / nullif(t.items, 0)) sales
      from refs rf join li_r l on l.order_id = rf.order_id join tot_r t on t.order_id = rf.order_id
    ), all_a as (
      select vat_type, sales from alloc union all select vat_type, sales from alloc_r
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'vat_type', vat_type,
        'sales', round(sales, 2),
        'vat', round(case when vat_type = 'standard' then sales * v_rate / (100 + v_rate) else 0 end, 2),
        'excl', round(sales - case when vat_type = 'standard' then sales * v_rate / (100 + v_rate) else 0 end, 2))
      order by vat_type desc), '[]'::jsonb)
    from (select vat_type, sum(sales) sales from all_a group by vat_type) x
  );
end $function$;
