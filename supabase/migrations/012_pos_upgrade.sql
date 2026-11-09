-- 012: audit trail, cancel rules, invoice numbers, discounts, tips, extras that use stock,
-- recipe waste, buying units, purchase orders, error log, per-cashier cash-up, better reports.

-- ---------------------------------------------------------------- settings
alter table public.company_settings
  add column if not exists timezone text not null default 'Africa/Johannesburg',
  add column if not exists table_count int not null default 12 check (table_count between 0 and 200),
  add column if not exists invoice_prefix text not null default 'INV';

create or replace function public.app_tz() returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select timezone from public.company_settings where id = 1), 'Africa/Johannesburg');
$$;
grant execute on function public.app_tz() to authenticated;

-- ---------------------------------------------------------------- orders
create sequence if not exists public.invoice_seq;
alter table public.orders
  add column if not exists voided_by uuid references public.staff_profiles(id) on delete set null,
  add column if not exists discount numeric(12,2) not null default 0 check (discount >= 0),
  add column if not exists discount_reason text,
  add column if not exists invoice_no bigint unique;

-- Give already-paid orders an invoice number in date order.
with numbered as (
  select id, row_number() over (order by created_at, id) n from public.orders where paid and invoice_no is null
)
update public.orders o set invoice_no = numbered.n from numbered where numbered.id = o.id;
select setval('public.invoice_seq', greatest(coalesce((select max(invoice_no) from public.orders), 0), 1),
              coalesce((select max(invoice_no) from public.orders), 0) > 0);

create or replace function public.guard_order() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    -- An old copy from another device must never undo these.
    new.invoice_no := coalesce(new.invoice_no, old.invoice_no);
    new.created_by := coalesce(old.created_by, new.created_by);
    if old.paid and not new.paid then new.paid := true; end if;
    if old.status = 'void' then
      new.status := 'void';
      new.voided_at := old.voided_at;
      new.voided_by := old.voided_by;
      new.void_reason := coalesce(old.void_reason, new.void_reason);
    end if;
    new.cancel_ack_at := coalesce(new.cancel_ack_at, old.cancel_ack_at);
    if new.status = 'void' and old.status <> 'void' then
      if old.paid and coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
        raise exception 'Only a supervisor or admin can cancel an order that has been paid';
      end if;
      new.voided_by := coalesce(new.voided_by, auth.uid());
      new.voided_at := coalesce(new.voided_at, now());
    end if;
  else
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  if new.paid and new.invoice_no is null then
    new.invoice_no := nextval('public.invoice_seq');
  end if;
  return new;
end $$;
revoke all on function public.guard_order() from public, anon, authenticated;
drop trigger if exists trg_guard_order on public.orders;
create trigger trg_guard_order before insert or update on public.orders
  for each row execute function public.guard_order();

-- ---------------------------------------------------------------- payments: tips, mark paid on server
alter table public.payments add column if not exists tip numeric(12,2) not null default 0 check (tip >= 0);

create or replace function public.mark_order_paid() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.orders o set paid = true
  where o.id = new.order_id and not o.paid
    and (select coalesce(sum(amount), 0) from public.payments where order_id = new.order_id) >= o.total - 0.005;
  return new;
end $$;
revoke all on function public.mark_order_paid() from public, anon, authenticated;
drop trigger if exists trg_mark_paid on public.payments;
create trigger trg_mark_paid after insert on public.payments for each row execute function public.mark_order_paid();

-- ---------------------------------------------------------------- recipes, extras, buying units
alter table public.recipe_lines add column if not exists waste_pct numeric(5,2) not null default 0 check (waste_pct >= 0 and waste_pct <= 100);
alter table public.modifiers
  add column if not exists stock_item_id uuid references public.stock_items(id) on delete set null,
  add column if not exists stock_qty numeric(12,3) not null default 0;
alter table public.stock_items
  add column if not exists purchase_unit text,
  add column if not exists purchase_factor numeric(12,3) not null default 1 check (purchase_factor > 0);

-- ---------------------------------------------------------------- order items: cost at sale, extras, remove item
alter table public.order_items
  add column if not exists unit_cost numeric(12,4),
  add column if not exists modifier_ids uuid[] not null default '{}',
  add column if not exists voided boolean not null default false,
  add column if not exists voided_at timestamptz,
  add column if not exists added_later boolean not null default false;

-- What one portion of a product (with its extras) takes from stock.
create or replace function public.item_usage(p_product uuid, p_modifiers uuid[], p_qty numeric)
returns table(stock_item_id uuid, qty numeric) language sql stable security definer set search_path = '' as $$
  select u.stock_item_id, sum(u.qty) from (
    select rl.stock_item_id, rl.qty * (1 + rl.waste_pct / 100) * p_qty qty
      from public.recipe_lines rl where rl.product_id = p_product
    union all
    select m.stock_item_id, m.stock_qty * p_qty
      from public.modifiers m where m.id = any(coalesce(p_modifiers, '{}')) and m.stock_item_id is not null
  ) u group by u.stock_item_id having sum(u.qty) <> 0;
$$;
revoke all on function public.item_usage(uuid, uuid[], numeric) from public, anon;

create or replace function public.cost_item() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.unit_cost is null and new.product_id is not null then
    select coalesce(sum(u.qty * si.avg_cost), 0) into new.unit_cost
    from public.item_usage(new.product_id, new.modifier_ids, 1) u join public.stock_items si on si.id = u.stock_item_id;
  end if;
  if tg_op = 'UPDATE' then
    if old.voided and not new.voided then new.voided := true; new.voided_at := old.voided_at; end if;
    new.unit_cost := coalesce(old.unit_cost, new.unit_cost);
  end if;
  if new.voided and new.voided_at is null then new.voided_at := now(); end if;
  return new;
end $$;
revoke all on function public.cost_item() from public, anon, authenticated;
drop trigger if exists trg_cost_item on public.order_items;
create trigger trg_cost_item before insert or update on public.order_items for each row execute function public.cost_item();

create or replace function public.deduct_stock_for_item() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.product_id is not null and not new.voided then
    insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
    select u.stock_item_id, -u.qty, 'sale'::public.move_reason, new.id
    from public.item_usage(new.product_id, new.modifier_ids, new.qty) u;
  end if;
  return new;
end $$;

-- Puts back exactly what is still taken out for one order item (sale minus anything already returned).
create or replace function public.return_item_stock(p_item uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
  select m.stock_item_id, -sum(m.qty_change), 'sale_void'::public.move_reason, p_item
  from public.stock_movements m
  where m.ref_id = p_item and m.reason in ('sale','sale_void')
  group by m.stock_item_id having round(sum(m.qty_change), 3) <> 0;
end $$;
revoke all on function public.return_item_stock(uuid) from public, anon, authenticated;

create or replace function public.restore_stock_on_void() returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select id from public.order_items where order_id = new.id and not voided loop
    perform public.return_item_stock(r.id);
  end loop;
  return new;
end $$;

create or replace function public.restore_stock_on_item_void() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select status from public.orders where id = new.order_id) <> 'void' then
    perform public.return_item_stock(new.id);
  end if;
  return new;
end $$;
revoke all on function public.restore_stock_on_item_void() from public, anon, authenticated;
drop trigger if exists trg_item_void on public.order_items;
create trigger trg_item_void after update of voided on public.order_items
  for each row when (new.voided and not old.voided) execute function public.restore_stock_on_item_void();

-- Refund: put back a share of what was used, never more than is still out.
drop function if exists public.issue_refund(uuid, numeric, public.pay_method, text, boolean);
create function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text, p_restock boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid boolean; v_done numeric; v_status public.order_status; v_frac numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can refund';
  end if;
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
  insert into public.refunds(order_id, amount, method, reason, restocked)
    values (p_order_id, round(p_amount,2), p_method, trim(p_reason), p_restock);
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
end $$;
revoke all on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean) from public, anon;
grant execute on function public.issue_refund(uuid, numeric, public.pay_method, text, boolean) to authenticated;

-- ---------------------------------------------------------------- purchase orders
create sequence if not exists public.po_seq;
grant usage on sequence public.po_seq to authenticated;
create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_no text not null unique default ('PO-' || lpad(nextval('public.po_seq')::text, 5, '0')),
  supplier_id uuid not null references public.suppliers(id),
  status text not null default 'draft' check (status in ('draft','sent','received','cancelled')),
  notes text,
  grv_id uuid references public.grvs(id) on delete set null,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  stock_item_id uuid not null references public.stock_items(id),
  qty numeric(12,3) not null check (qty > 0),       -- in stock units
  unit_cost numeric(12,4) not null default 0          -- per stock unit, excl. VAT
);
create index if not exists purchase_order_lines_po on public.purchase_order_lines(po_id);
create index if not exists purchase_order_lines_item on public.purchase_order_lines(stock_item_id);
create index if not exists purchase_orders_supplier on public.purchase_orders(supplier_id);
create index if not exists purchase_orders_grv on public.purchase_orders(grv_id);
create index if not exists purchase_orders_created_by on public.purchase_orders(created_by);
drop trigger if exists trg_touch on public.purchase_orders;
create trigger trg_touch before update on public.purchase_orders for each row execute function public.touch_updated_at();
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
create policy po_select on public.purchase_orders for select to authenticated
  using ((select public.my_role()) in ('admin','stock','supervisor'));
create policy po_insert on public.purchase_orders for insert to authenticated
  with check ((select public.my_role()) in ('admin','stock'));
create policy po_update on public.purchase_orders for update to authenticated
  using ((select public.my_role()) in ('admin','stock')) with check ((select public.my_role()) in ('admin','stock'));
create policy po_delete on public.purchase_orders for delete to authenticated
  using ((select public.my_role()) in ('admin','stock'));
create policy pol_select on public.purchase_order_lines for select to authenticated
  using ((select public.my_role()) in ('admin','stock','supervisor'));
create policy pol_insert on public.purchase_order_lines for insert to authenticated
  with check ((select public.my_role()) in ('admin','stock'));
create policy pol_update on public.purchase_order_lines for update to authenticated
  using ((select public.my_role()) in ('admin','stock')) with check ((select public.my_role()) in ('admin','stock'));
create policy pol_delete on public.purchase_order_lines for delete to authenticated
  using ((select public.my_role()) in ('admin','stock'));

-- Turn a purchase order into a draft delivery (GRV) so receiving it is one step.
create or replace function public.po_to_grv(p_po uuid) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_grv uuid; v_sup uuid; v_status text; v_no text;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','stock') then raise exception 'Not allowed'; end if;
  select supplier_id, status into v_sup, v_status from public.purchase_orders where id = p_po for update;
  if v_sup is null then raise exception 'Purchase order not found'; end if;
  if v_status in ('received','cancelled') then raise exception 'This purchase order is already %', v_status; end if;
  select 'GRV-' || lpad((coalesce(max(nullif(regexp_replace(grv_no, '\D', '', 'g'), '')::bigint), 0) + 1)::text, 6, '0')
    into v_no from public.grvs;
  insert into public.grvs (grv_no, supplier_id, status, notes)
    values (v_no, v_sup, 'draft', 'From ' || (select po_no from public.purchase_orders where id = p_po))
    returning id into v_grv;
  insert into public.grv_lines (grv_id, stock_item_id, ordered_qty, received_qty, unit_cost)
    select v_grv, stock_item_id, qty, qty, unit_cost from public.purchase_order_lines where po_id = p_po;
  update public.purchase_orders set status = 'received', grv_id = v_grv where id = p_po;
  return v_grv;
end $$;
revoke all on function public.po_to_grv(uuid) from public, anon;
grant execute on function public.po_to_grv(uuid) to authenticated;

-- ---------------------------------------------------------------- error log
create table if not exists public.app_errors (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid default auth.uid(),
  message text not null,
  details text,
  platform text,
  app_version text
);
alter table public.app_errors enable row level security;
create policy app_errors_insert on public.app_errors for insert to authenticated with check (user_id = auth.uid());
create policy app_errors_select on public.app_errors for select to authenticated using ((select public.my_role()) = 'admin');
create policy app_errors_delete on public.app_errors for delete to authenticated using ((select public.my_role()) = 'admin');

-- ---------------------------------------------------------------- cash-up per cashier, with tips
alter table public.cash_ups
  add column if not exists staff_id uuid references public.staff_profiles(id) on delete set null,
  add column if not exists cash_tips numeric(12,2) not null default 0,
  add column if not exists card_tips numeric(12,2) not null default 0;
create index if not exists cash_ups_staff on public.cash_ups(staff_id);
create index if not exists cash_ups_created_by on public.cash_ups(created_by);
create index if not exists refunds_order on public.refunds(order_id);
create index if not exists refunds_created_by on public.refunds(created_by);
create index if not exists orders_voided_by on public.orders(voided_by);
create index if not exists modifiers_stock_item on public.modifiers(stock_item_id);
create index if not exists stock_movements_ref on public.stock_movements(ref_id);

drop function if exists public.save_cash_up(date, numeric, numeric, text);
drop function if exists public.cash_up_summary(date);

create function public.cash_up_summary(p_date date, p_staff uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz(); r jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  with p as (
    select * from public.payments
    where (created_at at time zone tz)::date = p_date and (p_staff is null or created_by = p_staff)
  ), rf as (
    select * from public.refunds
    where (created_at at time zone tz)::date = p_date and (p_staff is null or created_by = p_staff)
  )
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from p where method = 'cash'), 0),
    'cash_tips', coalesce((select sum(tip) from p where method = 'cash'), 0),
    'cash_count', (select count(*) from p where method = 'cash'),
    'card_sales', coalesce((select sum(amount) from p where method = 'card_manual'), 0),
    'card_tips', coalesce((select sum(tip) from p where method = 'card_manual'), 0),
    'card_slips', (select count(*) from p where method = 'card_manual'),
    'cash_refunds', coalesce((select sum(amount) from rf where method = 'cash'), 0),
    'card_refunds', coalesce((select sum(amount) from rf where method = 'card_manual'), 0),
    'by_staff', (select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
        select jsonb_build_object('staff_id', p.created_by, 'name', coalesce(s.full_name, 'Unknown'),
          'cash', coalesce(sum(p.amount) filter (where p.method = 'cash'), 0),
          'card', coalesce(sum(p.amount) filter (where p.method = 'card_manual'), 0),
          'tips', coalesce(sum(p.tip), 0), 'payments', count(*)) x
        from p left join public.staff_profiles s on s.id = p.created_by
        group by p.created_by, s.full_name) y),
    'done', (select to_jsonb(c) from (select business_date, staff_id, opening_float, expected_cash, counted_cash, variance, notes, created_at
              from public.cash_ups where business_date = p_date and staff_id is not distinct from p_staff
              order by created_at desc limit 1) c)
  ) into r;
  return r;
end $$;
revoke all on function public.cash_up_summary(date, uuid) from public, anon;
grant execute on function public.cash_up_summary(date, uuid) to authenticated;

create function public.save_cash_up(p_date date, p_float numeric, p_counted numeric, p_notes text, p_staff uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date, p_staff);
  v_exp := round(p_float + (s->>'cash_sales')::numeric + (s->>'cash_tips')::numeric - (s->>'cash_refunds')::numeric, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, nullif(trim(coalesce(p_notes,'')),''));
end $$;
revoke all on function public.save_cash_up(date, numeric, numeric, text, uuid) from public, anon;
grant execute on function public.save_cash_up(date, numeric, numeric, text, uuid) to authenticated;

-- ---------------------------------------------------------------- clear test sales before going live
create or replace function public.clear_test_sales(p_confirm text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare n_orders int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can clear sales'; end if;
  if p_confirm is distinct from 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  select count(*) into n_orders from public.orders;
  -- undo what sales took from stock, then remove those movements
  update public.stock_items si set qty_on_hand = si.qty_on_hand - x.q
  from (select stock_item_id, sum(qty_change) q from public.stock_movements where reason in ('sale','sale_void') group by 1) x
  where x.stock_item_id = si.id;
  delete from public.stock_movements where reason in ('sale','sale_void');
  delete from public.refunds;
  delete from public.cash_ups;
  delete from public.payments;
  delete from public.order_items;
  delete from public.orders;
  perform setval('public.invoice_seq', 1, false);
  return jsonb_build_object('orders_removed', n_orders);
end $$;
revoke all on function public.clear_test_sales(text) from public, anon;
grant execute on function public.clear_test_sales(text) to authenticated;

-- ---------------------------------------------------------------- reports
drop function if exists public.admin_report(timestamptz, timestamptz);
create function public.admin_report(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rate numeric; tz text := public.app_tz(); r jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Reports are for admin and supervisor only';
  end if;
  select vat_rate into v_rate from public.company_settings where id = 1;
  v_rate := coalesce(v_rate, 15);

  with
  o as (select * from public.orders where created_at >= p_from and created_at < p_to),
  sold as (select * from o where status <> 'void' and paid),
  live_items as (select oi.* from public.order_items oi join sold s on s.id = oi.order_id where not oi.voided),
  order_lines as (select order_id, sum(qty * unit_price) items_total from live_items group by order_id),
  unit_cost as (
    select rl.product_id, sum(rl.qty * (1 + rl.waste_pct / 100) * si.avg_cost) cost
    from public.recipe_lines rl join public.stock_items si on si.id = rl.stock_item_id group by 1),
  lines as (
    -- discounts are shared across the order's items so product sales add up to the till total
    select li.product_id, li.name, li.qty,
           li.qty * li.unit_price * coalesce(s.total / nullif(ol.items_total, 0), 1) rev,
           li.qty * coalesce(li.unit_cost, uc.cost, 0) cost
    from live_items li join sold s on s.id = li.order_id
    join order_lines ol on ol.order_id = li.order_id
    left join unit_cost uc on uc.product_id = li.product_id),
  prod as (
    select l.product_id, coalesce(p.name, l.name) name, coalesce(c.name, 'Other') category,
           sum(l.qty) qty, round(sum(l.rev),2) revenue, round(sum(l.rev) * 100 / (100 + v_rate),2) net,
           round(sum(l.cost),2) cost
    from lines l left join public.products p on p.id = l.product_id
    left join public.categories c on c.id = p.category_id
    group by 1,2,3),
  rf as (select * from public.refunds where created_at >= p_from and created_at < p_to),
  pay as (select p.* from public.payments p join sold s on s.id = p.order_id),
  mv as (
    select m.stock_item_id, m.reason, sum(m.qty_change) qty
    from public.stock_movements m where m.created_at >= p_from and m.created_at < p_to group by 1,2),
  usage14 as (
    select stock_item_id, -sum(qty_change) used
    from public.stock_movements
    where reason in ('sale','sale_void') and created_at >= now() - interval '14 days' group by 1)
  select jsonb_build_object(
    'summary', (select jsonb_build_object(
        'orders', count(*),
        'before_discount', coalesce(round(sum(total + discount),2),0),
        'discounts', coalesce(round(sum(discount),2),0),
        'gross', coalesce(round(sum(total),2),0),
        'vat', coalesce(round(sum(vat),2),0), 'net', coalesce(round(sum(subtotal),2),0),
        'avg_order', coalesce(round(avg(total),2),0),
        'refunds', coalesce((select round(sum(amount),2) from rf),0),
        'after_refunds', coalesce(round(sum(total),2),0) - coalesce((select round(sum(amount),2) from rf),0),
        'tips', coalesce((select round(sum(tip),2) from pay),0)) from sold),
    'unpaid', (select jsonb_build_object('orders', count(*), 'total', coalesce(round(sum(total),2),0))
        from o where status <> 'void' and not paid),
    'voided', (select jsonb_build_object('orders', count(*), 'total', coalesce(round(sum(total),2),0))
        from o where status = 'void'),
    'by_day', (select coalesce(jsonb_agg(d order by d->>'day'), '[]') from (
        select jsonb_build_object('day', to_char((created_at at time zone tz)::date,'YYYY-MM-DD'),
          'orders', count(*), 'total', round(sum(total),2)) d
        from sold group by (created_at at time zone tz)::date) x),
    'by_hour', (select coalesce(jsonb_agg(h order by (h->>'hour')::int), '[]') from (
        select jsonb_build_object('hour', extract(hour from created_at at time zone tz)::int,
          'orders', count(*), 'total', round(sum(total),2)) h
        from sold group by extract(hour from created_at at time zone tz)::int) y),
    'by_type', (select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'orders', n, 'total', t)), '[]') from (
        select order_type, count(*) n, round(sum(total),2) t from sold group by 1) z),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', method, 'count', n, 'amount', t, 'tips', tp)), '[]') from (
        select method, count(*) n, round(sum(amount),2) t, round(sum(tip),2) tp from pay group by 1) w),
    'by_staff', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'orders', n, 'total', t, 'avg', a,
          'discounts', dsc, 'cancelled', vc) order by t desc), '[]') from (
        select coalesce(st.full_name, 'Unknown') name, count(s.id) n, round(coalesce(sum(s.total),0),2) t,
               round(coalesce(avg(s.total),0),2) a, round(coalesce(sum(s.discount),0),2) dsc,
               (select count(*) from o v where v.status = 'void' and v.voided_by = st.id) vc
        from public.staff_profiles st left join sold s on s.created_by = st.id
        group by st.id, st.full_name
        having count(s.id) > 0 or (select count(*) from o v where v.status = 'void' and v.voided_by = st.id) > 0) b),
    'products', (select coalesce(jsonb_agg(to_jsonb(p) order by p.revenue desc), '[]') from prod p),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'qty', q, 'revenue', rv, 'net', nt, 'cost', cs) order by rv desc), '[]') from (
        select category, sum(qty) q, sum(revenue) rv, sum(net) nt, sum(cost) cs from prod group by 1) c),
    'discount_list', (select coalesce(jsonb_agg(jsonb_build_object('ref', s.order_ref, 'invoice', s.invoice_no, 'at', s.created_at,
        'discount', s.discount, 'reason', s.discount_reason, 'by', coalesce(st.full_name, 'Unknown')) order by s.created_at desc), '[]')
        from sold s left join public.staff_profiles st on st.id = s.created_by where s.discount > 0),
    'voids', (select coalesce(jsonb_agg(jsonb_build_object('ref', v.order_ref, 'at', coalesce(v.voided_at, v.created_at),
        'total', v.total, 'paid', v.paid, 'reason', v.void_reason, 'by', coalesce(st.full_name, ''))
        order by coalesce(v.voided_at, v.created_at) desc), '[]')
        from o v left join public.staff_profiles st on st.id = v.voided_by where v.status = 'void'),
    'usage', (select coalesce(jsonb_agg(jsonb_build_object('item', si.name, 'unit', si.unit, 'category', si.category,
        'sold', coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason in ('sale','sale_void')),0),
        'received', coalesce((select sum(qty) from mv where stock_item_id = si.id and reason = 'grv'),0),
        'waste', coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason = 'waste'),0),
        'adjusted', coalesce((select sum(qty) from mv where stock_item_id = si.id and reason in ('adjustment','stocktake')),0),
        'cost_used', round(coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason in ('sale','sale_void')),0) * si.avg_cost, 2),
        'waste_cost', round(coalesce(-(select sum(qty) from mv where stock_item_id = si.id and reason = 'waste'),0) * si.avg_cost, 2))
        order by si.name), '[]') from public.stock_items si
        where exists (select 1 from mv where stock_item_id = si.id)),
    'reorder', (select coalesce(jsonb_agg(jsonb_build_object('item_id', si.id, 'item', si.name, 'unit', si.unit, 'category', si.category,
        'on_hand', si.qty_on_hand, 'min_level', si.min_level,
        'suggested', greatest(si.min_level * 2 - si.qty_on_hand, 0),
        'purchase_unit', si.purchase_unit, 'purchase_factor', si.purchase_factor,
        'suggested_packs', case when si.purchase_factor > 1 then ceil(greatest(si.min_level * 2 - si.qty_on_hand, 0) / si.purchase_factor) end,
        'avg_cost', si.avg_cost,
        'est_cost', round(greatest(si.min_level * 2 - si.qty_on_hand, 0) * si.avg_cost, 2),
        'supplier_id', si.supplier_id, 'supplier', coalesce(sp.name, 'No supplier'),
        'daily_use', round(coalesce(u.used,0) / 14, 2),
        'days_left', case when coalesce(u.used,0) > 0 then round(greatest(si.qty_on_hand,0) / (u.used / 14), 1) end)
        order by (si.qty_on_hand <= 0) desc, coalesce(sp.name,'zzz'), si.name), '[]')
        from public.stock_items si left join public.suppliers sp on sp.id = si.supplier_id
        left join usage14 u on u.stock_item_id = si.id
        where si.active and si.min_level > 0 and si.qty_on_hand <= si.min_level),
    'negative', (select coalesce(jsonb_agg(jsonb_build_object('item', name, 'unit', unit, 'on_hand', qty_on_hand) order by qty_on_hand), '[]')
        from public.stock_items where active and qty_on_hand < 0),
    'expiring', (select coalesce(jsonb_agg(jsonb_build_object('item', si.name, 'unit', si.unit, 'expiry', gl.expiry_date,
        'received', gl.received_qty, 'grv', g.grv_no, 'on_hand', si.qty_on_hand) order by gl.expiry_date), '[]')
        from public.grv_lines gl join public.grvs g on g.id = gl.grv_id join public.stock_items si on si.id = gl.stock_item_id
        where g.status = 'posted' and si.qty_on_hand > 0 and gl.expiry_date is not null
          and gl.expiry_date <= (now() at time zone tz)::date + 3 and gl.expiry_date >= (now() at time zone tz)::date - 7),
    'valuation', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'items', n, 'value', v) order by v desc), '[]') from (
        select coalesce(category,'Other') category, count(*) n, round(sum(greatest(qty_on_hand,0) * avg_cost),2) v
        from public.stock_items where active group by 1) q),
    'valuation_total', (select coalesce(round(sum(greatest(qty_on_hand,0) * avg_cost),2),0) from public.stock_items where active),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('supplier', coalesce(sp.name,'Unknown'), 'grvs', n, 'subtotal', st, 'vat', vt, 'total', t) order by t desc), '[]') from (
        select supplier_id, count(*) n, round(sum(subtotal),2) st, round(sum(vat),2) vt, round(sum(total),2) t
        from public.grvs where status = 'posted' and received_on >= (p_from at time zone tz)::date
          and received_on < (p_to at time zone tz)::date + 1 group by 1) g
        left join public.suppliers sp on sp.id = g.supplier_id),
    'vat_rate', v_rate,
    'timezone', tz
  ) into r;
  return r;
end $$;
revoke all on function public.admin_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_report(timestamptz, timestamptz) to authenticated;

-- live updates for the new kitchen fields come through order_items already; purchase orders do not need realtime.
