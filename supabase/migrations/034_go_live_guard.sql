-- Go-live switch. Before going live the admin may clear test sales (and test cash-ups, day closes
-- and till payouts). Once the admin presses Go live, clearing sales is refused for good, so real
-- invoices and their numbers can never be wiped or reused.
alter table public.company_settings add column if not exists live_since timestamptz;

create or replace function public.go_live() returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare v timestamptz;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can do this'; end if;
  update public.company_settings set live_since = coalesce(live_since, now()) where id = 1 returning live_since into v;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('company_settings', '1', 'go_live', jsonb_build_object('live_since', v));
  return v;
end $$;
revoke all on function public.go_live() from public, anon;
grant execute on function public.go_live() to authenticated;

-- company_settings.live_since may only be set through go_live().
create or replace function public.guard_live_since() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then new.live_since := old.live_since; end if;
  return new;
end $$;
drop trigger if exists trg_guard_live_since on public.company_settings;
create trigger trg_guard_live_since before update on public.company_settings
  for each row execute function public.guard_live_since();

create or replace function public.clear_test_sales(p_confirm text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare n_orders int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can clear sales'; end if;
  if (select live_since from public.company_settings where id = 1) is not null then
    raise exception 'The business is live, so sales can no longer be cleared. Real invoices must be kept for five years.';
  end if;
  if p_confirm is distinct from 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  select count(*) into n_orders from public.orders;
  perform set_config('pos.clearing', 'on', true);
  delete from public.account_transactions;
  update public.customer_accounts set balance = 0;
  perform setval('public.account_receipt_seq', 1, false);
  perform set_config('pos.clearing', 'off', true);
  update public.stock_items si set qty_on_hand = si.qty_on_hand - x.q
  from (select stock_item_id, sum(qty_change) q from public.stock_movements where reason in ('sale','sale_void') group by 1) x
  where x.stock_item_id = si.id;
  delete from public.stock_movements where reason in ('sale','sale_void');
  delete from public.refunds;
  delete from public.cash_ups;
  delete from public.day_closes;
  delete from public.cash_movements;
  delete from public.payments;
  delete from public.order_items;
  delete from public.orders;
  perform setval('public.invoice_seq', 1, false);
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('orders', 'all', 'test_sales_cleared', jsonb_build_object('orders_removed', n_orders));
  return jsonb_build_object('orders_removed', n_orders);
end $function$;
