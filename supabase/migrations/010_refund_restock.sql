alter table public.refunds add column if not exists restocked boolean not null default false;
drop function if exists public.issue_refund(uuid, numeric, public.pay_method, text);
create function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text, p_restock boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid boolean; v_done numeric; v_status public.order_status; v_frac numeric; v_id uuid;
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can refund';
  end if;
  select total, paid, status into v_total, v_paid, v_status from public.orders where id = p_order_id;
  if v_total is null then raise exception 'Order not found'; end if;
  if not v_paid then raise exception 'This order was never paid, nothing to refund'; end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = p_order_id;
  if p_amount <= 0 or p_amount > v_total - v_done then
    raise exception 'Refund must be more than 0 and no more than R% (still refundable)', (v_total - v_done);
  end if;
  if p_restock and v_status = 'void' then
    raise exception 'This order was cancelled, so its ingredients were already put back in stock';
  end if;
  insert into public.refunds(order_id, amount, method, reason, restocked)
    values (p_order_id, round(p_amount,2), p_method, trim(p_reason), p_restock) returning id into v_id;
  if p_restock then
    v_frac := p_amount / v_total;
    insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id, note)
    select rl.stock_item_id, round(rl.qty * oi.qty * v_frac, 3), 'sale_void'::public.move_reason, oi.id, 'Refund restock'
    from public.order_items oi join public.recipe_lines rl on rl.product_id = oi.product_id
    where oi.order_id = p_order_id and round(rl.qty * oi.qty * v_frac, 3) > 0;
  end if;
end $$;
revoke all on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean) from public, anon;
grant execute on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean) to authenticated;
