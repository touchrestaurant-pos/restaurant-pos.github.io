-- Prices and sale times are checked on the server, not trusted from the till.
-- 1. No negative prices. Cashiers and kitchen staff can only sell menu items, at the menu price
--    and VAT type (a lower price is corrected and recorded; a menu change made after the sale is respected).
-- 2. Order, item and payment times: a time in the future, more than 72 hours old, or on a day that
--    is already closed is replaced with the upload time (and recorded). Times cannot be edited later.

alter table public.order_items drop constraint if exists order_items_price_nonneg;
alter table public.order_items add constraint order_items_price_nonneg check (unit_price >= 0);

create or replace function public.clamp_sale_time(p_ts timestamptz, p_table text, p_row text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare v timestamptz := coalesce(p_ts, now());
begin
  if v > now() + interval '5 minutes' or v < now() - interval '72 hours'
     or exists (select 1 from public.day_closes where business_date = (v at time zone public.app_tz())::date) then
    if p_ts is not null and abs(extract(epoch from (now() - p_ts))) > 300 then
      insert into public.audit_log(table_name, row_id, action, changes)
        values (p_table, p_row, 'time_corrected', jsonb_build_object('sent', p_ts, 'saved', now()));
    end if;
    v := now();
  end if;
  return v;
end $$;
revoke all on function public.clamp_sale_time(timestamptz, text, text) from public, anon, authenticated;

create or replace function public.cost_item() returns trigger
language plpgsql security definer set search_path = '' as $function$
declare v_expected numeric; v_vat text; v_changed timestamptz; v_sold timestamptz;
        v_mgr boolean := coalesce((select public.my_role())::text, '') in ('admin','supervisor');
begin
  if new.unit_cost is null and new.product_id is not null then
    select coalesce(sum(u.qty * si.avg_cost), 0) into new.unit_cost
    from public.item_usage(new.product_id, new.modifier_ids, 1) u join public.stock_items si on si.id = u.stock_item_id;
  end if;
  if tg_op = 'INSERT' then
    select created_at into v_sold from public.orders where id = new.order_id;
    new.created_at := public.clamp_sale_time(new.created_at, 'order_items', new.id::text);
    if new.product_id is null then
      if not v_mgr then raise exception 'Only menu items can be sold. Ask a supervisor for anything else.'; end if;
    else
      select p.price + coalesce((select sum(m.price_delta) from public.modifiers m where m.id = any(new.modifier_ids)), 0),
             p.vat_type, p.updated_at
        into v_expected, v_vat, v_changed from public.products p where p.id = new.product_id;
      if v_expected is not null and abs(v_expected - new.unit_price) > 0.01 then
        if not v_mgr and new.unit_price < v_expected and v_changed <= coalesce(v_sold, now()) then
          insert into public.audit_log(table_name, row_id, action, changes)
          values ('order_items', new.id::text, 'price_corrected',
            jsonb_build_object('item', new.name, 'sent', new.unit_price, 'menu_price', v_expected, 'order_id', new.order_id));
          new.unit_price := v_expected;
        else
          insert into public.audit_log(table_name, row_id, action, changes)
          values ('order_items', new.id::text, 'price_differs',
            jsonb_build_object('item', new.name, 'charged', new.unit_price, 'menu_price', v_expected, 'order_id', new.order_id));
        end if;
      end if;
      if not v_mgr and v_vat is not null and new.vat_type is distinct from v_vat and v_changed <= coalesce(v_sold, now()) then
        insert into public.audit_log(table_name, row_id, action, changes)
        values ('order_items', new.id::text, 'vat_corrected',
          jsonb_build_object('item', new.name, 'sent', new.vat_type, 'menu_vat', v_vat, 'order_id', new.order_id));
        new.vat_type := v_vat;
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    if old.voided and not new.voided then new.voided := true; new.voided_at := old.voided_at; end if;
    new.unit_cost := coalesce(old.unit_cost, new.unit_cost);
  end if;
  if new.voided and new.voided_at is null then new.voided_at := now(); end if;
  return new;
end $function$;

-- Orders: clamp on insert, freeze on update (patched in place so the rest of guard_order is unchanged).
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'guard_order' and p.prokind = 'f';
  if d not like '%clamp_sale_time%' then
    d := replace(d, '    new.invoice_no := coalesce(old.invoice_no, new.invoice_no);',
                    '    new.invoice_no := coalesce(old.invoice_no, new.invoice_no);' || chr(10) || '    new.created_at := old.created_at;');
    d := replace(d, '    new.paid := false;' || chr(10) || '    new.invoice_no := null;',
                    '    new.paid := false;' || chr(10) || '    new.invoice_no := null;' || chr(10) ||
                    '    new.created_at := public.clamp_sale_time(new.created_at, ''orders'', new.id::text);');
    if d not like '%new.created_at := old.created_at%' or d not like '%clamp_sale_time(new.created_at%' then
      raise exception 'guard_order patch did not apply';
    end if;
    execute d;
  end if;
end $$;

-- Payments: clamp on insert, freeze on update.
create or replace function public.guard_payment() returns trigger
language plpgsql security definer set search_path = '' as $function$
declare v_role text := coalesce((select public.my_role())::text, '');
begin
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    return new;
  end if;
  new.created_at := public.clamp_sale_time(new.created_at, 'payments', new.id::text);
  if v_role = 'cashier' then new.created_by := auth.uid(); end if;
  if new.method::text = 'eft' then
    if length(trim(coalesce(new.reference, ''))) = 0 then raise exception 'An EFT payment needs the bank reference'; end if;
    if v_role = 'cashier' and public.my_perm('can_take_eft') = 'false'::jsonb then
      raise exception 'You are not allowed to take EFT payments. Ask the admin.';
    end if;
    if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an EFT payment'; end if;
  end if;
  return new;
end $function$;
drop trigger if exists trg_guard_payment on public.payments;
create trigger trg_guard_payment before insert or update on public.payments
  for each row execute function public.guard_payment();
