-- Run first, on its own: alter type public.grv_status add value if not exists 'reversed';
-- 015: server-checked totals, credit notes, cash movements, day close, purchase VAT,
-- supplier accounts, expenses and profit, stock-take, audit trail, customer details.

-- ---------------------------------------------------------------- small additions
alter table public.orders add column if not exists customer_phone text, add column if not exists delivery_address text;
alter table public.modifiers add column if not exists category_ids uuid[] not null default '{}';
alter table public.stock_items add column if not exists vat_type text not null default 'standard'
  check (vat_type in ('standard','zero','exempt'));
update public.stock_items set vat_type = 'zero'
  where name in ('Milk','Cooking oil','Lettuce','Mushrooms','Onion','Tomato') and vat_type = 'standard';

-- ---------------------------------------------------------------- audit trail
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid default auth.uid(),
  table_name text not null,
  row_id text,
  action text not null,
  changes jsonb
);
create index if not exists audit_log_at on public.audit_log(at desc);
alter table public.audit_log enable row level security;
create policy audit_select on public.audit_log for select to authenticated using ((select public.my_role()) = 'admin');

create or replace function public.audit_row() returns trigger language plpgsql security definer set search_path = '' as $$
declare v jsonb; j jsonb;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value)) into v
    from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
    where n.value is distinct from o.value and n.key not in ('updated_at','qty_on_hand','avg_cost');
    if v is null then return new; end if;
    j := to_jsonb(new);
  elsif tg_op = 'INSERT' then
    j := to_jsonb(new); v := j;
  else
    j := to_jsonb(old); v := j;
  end if;
  insert into public.audit_log(table_name, row_id, action, changes)
    values (tg_table_name, coalesce(j->>'id', j->>'product_id'), lower(tg_op), v);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.audit_row() from public, anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['products','categories','modifiers','recipe_lines','stock_items','suppliers','company_settings','staff_profiles'] loop
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I for each row execute function public.audit_row()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- server-checked totals
create or replace function public.guard_order() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_items numeric; v_std numeric; v_rate numeric;
begin
  if tg_op = 'UPDATE' then
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
    -- The server works the money out again from the items, so a till cannot save a wrong total.
    select sum(qty * unit_price), sum(qty * unit_price) filter (where vat_type = 'standard')
      into v_items, v_std from public.order_items where order_id = new.id and not voided;
    if v_items is not null then
      select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
      new.total := round(greatest(v_items - new.discount, 0), 2);
      new.vat := round(new.total * (case when v_items > 0 then coalesce(v_std, 0) / v_items else 1 end) * v_rate / (100 + v_rate), 2);
      new.subtotal := new.total - new.vat;
    end if;
  else
    new.created_by := coalesce(new.created_by, auth.uid());
    if new.discount > 0 and coalesce((select public.my_role())::text, '') = 'cashier'
       and new.discount > (new.total + new.discount) * 0.10 + 0.01 then
      raise exception 'Cashiers can give up to 10%% discount. Ask a supervisor.';
    end if;
  end if;
  if new.paid and new.invoice_no is null then
    new.invoice_no := nextval('public.invoice_seq');
  end if;
  return new;
end $$;

create or replace function public.touch_order_for_item() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.orders set updated_at = now() where id = new.order_id;
  return new;
end $$;
revoke all on function public.touch_order_for_item() from public, anon, authenticated;
drop trigger if exists trg_item_recalc on public.order_items;
create trigger trg_item_recalc after insert or update of qty, unit_price, voided, vat_type on public.order_items
  for each row execute function public.touch_order_for_item();

-- A price that differs from the menu is kept (the price may have changed while the till was offline) but recorded.
create or replace function public.cost_item() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_expected numeric;
begin
  if new.unit_cost is null and new.product_id is not null then
    select coalesce(sum(u.qty * si.avg_cost), 0) into new.unit_cost
    from public.item_usage(new.product_id, new.modifier_ids, 1) u join public.stock_items si on si.id = u.stock_item_id;
  end if;
  if tg_op = 'INSERT' and new.product_id is not null then
    select p.price + coalesce((select sum(m.price_delta) from public.modifiers m where m.id = any(new.modifier_ids)), 0)
      into v_expected from public.products p where p.id = new.product_id;
    if v_expected is not null and abs(v_expected - new.unit_price) > 0.01 then
      insert into public.audit_log(table_name, row_id, action, changes)
      values ('order_items', new.id::text, 'price_differs',
        jsonb_build_object('item', new.name, 'charged', new.unit_price, 'menu_price', v_expected, 'order_id', new.order_id));
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if old.voided and not new.voided then new.voided := true; new.voided_at := old.voided_at; end if;
    new.unit_cost := coalesce(old.unit_cost, new.unit_cost);
  end if;
  if new.voided and new.voided_at is null then new.voided_at := now(); end if;
  return new;
end $$;

-- ---------------------------------------------------------------- credit notes
create sequence if not exists public.credit_note_seq;
alter table public.refunds add column if not exists credit_note_no bigint unique default nextval('public.credit_note_seq');

create or replace function public.admin_refunds(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Reports are for admin and supervisor only';
  end if;
  return jsonb_build_object(
    'total', coalesce((select sum(amount) from public.refunds where created_at >= p_from and created_at < p_to),0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('ref', o.order_ref, 'invoice', o.invoice_no, 'credit_note', r.credit_note_no,
        'at', r.created_at, 'amount', r.amount, 'method', r.method, 'reason', r.reason) order by r.created_at desc)
        from public.refunds r join public.orders o on o.id = r.order_id
        where r.created_at >= p_from and r.created_at < p_to), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- day close and cash movements
create table if not exists public.day_closes (
  business_date date primary key,
  closed_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  closed_at timestamptz not null default now(),
  summary jsonb not null
);
create index if not exists day_closes_closed_by on public.day_closes(closed_by);
alter table public.day_closes enable row level security;
create policy day_closes_select on public.day_closes for select to authenticated
  using ((select public.my_role()) in ('admin','supervisor'));

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  business_date date not null,
  kind text not null check (kind in ('drop','payout','tip_payout','float_in')),
  amount numeric(12,2) not null check (amount > 0),
  note text not null check (length(trim(note)) > 0),
  staff_id uuid references public.staff_profiles(id) on delete set null,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists cash_movements_date on public.cash_movements(business_date);
create index if not exists cash_movements_staff on public.cash_movements(staff_id);
create index if not exists cash_movements_created_by on public.cash_movements(created_by);
alter table public.cash_movements enable row level security;
create policy cash_movements_select on public.cash_movements for select to authenticated
  using ((select public.my_role()) in ('admin','supervisor'));
create policy cash_movements_insert on public.cash_movements for insert to authenticated
  with check ((select public.my_role()) in ('admin','supervisor'));
create policy cash_movements_delete on public.cash_movements for delete to authenticated
  using ((select public.my_role()) in ('admin','supervisor'));

create or replace function public.block_closed_day() returns trigger language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  if tg_op = 'DELETE' then d := old.business_date; else d := new.business_date; end if;
  if exists (select 1 from public.day_closes where business_date = d) then
    raise exception 'The day % is closed. An admin can reopen it.', d;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.block_closed_day() from public, anon, authenticated;
drop trigger if exists trg_closed on public.cash_movements;
create trigger trg_closed before insert or delete on public.cash_movements for each row execute function public.block_closed_day();
drop trigger if exists trg_closed on public.cash_ups;
create trigger trg_closed before insert on public.cash_ups for each row execute function public.block_closed_day();

alter table public.cash_ups add column if not exists cash_out numeric(12,2) not null default 0,
  add column if not exists cash_in numeric(12,2) not null default 0;

create or replace function public.cash_up_summary(p_date date, p_staff uuid default null)
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
  ), mv as (
    select * from public.cash_movements where business_date = p_date and (p_staff is null or staff_id = p_staff)
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
    'cash_out', coalesce((select sum(amount) from mv where kind <> 'float_in'), 0),
    'cash_in', coalesce((select sum(amount) from mv where kind = 'float_in'), 0),
    'movements', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'amount', m.amount, 'note', m.note,
          'at', m.created_at, 'by', coalesce(s.full_name, '')) order by m.created_at), '[]'::jsonb)
        from mv m left join public.staff_profiles s on s.id = m.created_by),
    'closed', exists (select 1 from public.day_closes where business_date = p_date),
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

create or replace function public.save_cash_up(p_date date, p_float numeric, p_counted numeric, p_notes text, p_staff uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date, p_staff);
  v_exp := round(p_float + (s->>'cash_sales')::numeric + (s->>'cash_tips')::numeric - (s->>'cash_refunds')::numeric
           - (s->>'cash_out')::numeric + (s->>'cash_in')::numeric, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, cash_out, cash_in, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, (s->>'cash_out')::numeric, (s->>'cash_in')::numeric,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;

-- Freezes a copy of the day's figures. Sales that sync later still count in reports;
-- the day-end screen shows any difference from the frozen copy.
create or replace function public.close_day(p_date date) returns jsonb language plpgsql security definer set search_path = '' as $$
declare tz text := public.app_tz(); v_from timestamptz; v_to timestamptz; rep jsonb; s jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can close the day';
  end if;
  if exists (select 1 from public.day_closes where business_date = p_date) then
    raise exception 'This day is already closed';
  end if;
  v_from := p_date::timestamp at time zone tz;
  v_to := (p_date + 1)::timestamp at time zone tz;
  rep := public.admin_report(v_from, v_to);
  s := jsonb_build_object(
    'summary', rep->'summary', 'payments', rep->'payments', 'unpaid', rep->'unpaid', 'voided', rep->'voided',
    'by_staff', rep->'by_staff', 'vat', public.vat_report(v_from, v_to),
    'cash', public.cash_up_summary(p_date) - 'movements' - 'by_staff' - 'done',
    'cash_ups', (select coalesce(jsonb_agg(jsonb_build_object('staff_id', staff_id, 'expected', expected_cash, 'counted', counted_cash,
        'variance', variance) order by created_at), '[]'::jsonb) from public.cash_ups where business_date = p_date));
  insert into public.day_closes(business_date, summary) values (p_date, s);
  return s;
end $$;
revoke all on function public.close_day(date) from public, anon;
grant execute on function public.close_day(date) to authenticated;

create or replace function public.reopen_day(p_date date) returns void language plpgsql security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can reopen a day'; end if;
  delete from public.day_closes where business_date = p_date;
  insert into public.audit_log(table_name, row_id, action) values ('day_closes', p_date::text, 'reopened');
end $$;
revoke all on function public.reopen_day(date) from public, anon;
grant execute on function public.reopen_day(date) to authenticated;

-- ---------------------------------------------------------------- purchases: VAT per item, reversal, supplier accounts
create or replace function public.post_grv(p_grv_id uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v_status public.grv_status; v_sub numeric(12,2); v_vat numeric(12,2); v_rate numeric(5,2);
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','stock','supervisor') then
    raise exception 'Not allowed to post a GRV';
  end if;
  select status into v_status from public.grvs where id = p_grv_id for update;
  if v_status is null then raise exception 'GRV not found'; end if;
  if v_status <> 'draft' then raise exception 'GRV already %', v_status; end if;

  update public.stock_items si set avg_cost = case
      when l.received_qty > 0 then round((greatest(si.qty_on_hand, 0) * si.avg_cost + l.received_qty * l.unit_cost) / (greatest(si.qty_on_hand, 0) + l.received_qty), 4)
      else si.avg_cost end
  from public.grv_lines l where l.grv_id = p_grv_id and l.stock_item_id = si.id;

  insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
  select stock_item_id, received_qty, 'grv'::public.move_reason, p_grv_id
  from public.grv_lines where grv_id = p_grv_id and received_qty > 0;

  select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
  select coalesce(sum(l.line_total), 0),
         coalesce(round(sum(l.line_total) filter (where si.vat_type = 'standard') * v_rate / 100, 2), 0)
    into v_sub, v_vat
  from public.grv_lines l join public.stock_items si on si.id = l.stock_item_id where l.grv_id = p_grv_id;
  update public.grvs set status = 'posted', subtotal = v_sub, vat = v_vat, total = v_sub + v_vat where id = p_grv_id;
end $$;

create or replace function public.reverse_grv(p_grv_id uuid, p_reason text) returns void language plpgsql security definer set search_path = '' as $$
declare v_status public.grv_status;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can reverse a delivery';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'Give a reason'; end if;
  select status into v_status from public.grvs where id = p_grv_id for update;
  if v_status is distinct from 'posted' then raise exception 'Only a posted delivery can be reversed'; end if;
  insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id, note)
  select stock_item_id, -received_qty, 'grv'::public.move_reason, p_grv_id, 'Reversed: ' || trim(p_reason)
  from public.grv_lines where grv_id = p_grv_id and received_qty > 0;
  update public.grvs set status = 'reversed', notes = trim(coalesce(notes || ' · ', '') || 'Reversed: ' || trim(p_reason)) where id = p_grv_id;
end $$;
revoke all on function public.reverse_grv(uuid, text) from public, anon;
grant execute on function public.reverse_grv(uuid, text) to authenticated;

create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id),
  grv_id uuid references public.grvs(id) on delete set null,
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'eft' check (method in ('eft','cash','card','credit_note')),
  paid_on date not null default current_date,
  note text,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists supplier_payments_supplier on public.supplier_payments(supplier_id);
create index if not exists supplier_payments_grv on public.supplier_payments(grv_id);
create index if not exists supplier_payments_created_by on public.supplier_payments(created_by);
alter table public.supplier_payments enable row level security;
create policy supplier_payments_select on public.supplier_payments for select to authenticated using ((select public.my_role()) in ('admin','supervisor'));
create policy supplier_payments_insert on public.supplier_payments for insert to authenticated with check ((select public.my_role()) = 'admin');
create policy supplier_payments_delete on public.supplier_payments for delete to authenticated using ((select public.my_role()) = 'admin');

create or replace function public.supplier_accounts() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Supplier accounts are for admin and supervisor only';
  end if;
  return jsonb_build_object(
    'suppliers', (select coalesce(jsonb_agg(x order by (x->>'owing')::numeric desc, x->>'name'), '[]'::jsonb) from (
      select jsonb_build_object('id', s.id, 'name', s.name,
        'purchased', coalesce((select sum(total) from public.grvs g where g.supplier_id = s.id and g.status = 'posted'), 0),
        'paid', coalesce((select sum(amount) from public.supplier_payments p where p.supplier_id = s.id), 0),
        'owing', coalesce((select sum(total) from public.grvs g where g.supplier_id = s.id and g.status = 'posted'), 0)
               - coalesce((select sum(amount) from public.supplier_payments p where p.supplier_id = s.id), 0)) x
      from public.suppliers s) y where (x->>'purchased')::numeric <> 0 or (x->>'paid')::numeric <> 0),
    'deliveries', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'grv_no', g.grv_no, 'supplier_id', g.supplier_id,
        'received_on', g.received_on, 'delivery_note', g.delivery_note, 'total', g.total,
        'paid', coalesce((select sum(amount) from public.supplier_payments p where p.grv_id = g.id), 0)) order by g.received_on), '[]'::jsonb)
      from public.grvs g where g.status = 'posted'
        and g.total - coalesce((select sum(amount) from public.supplier_payments p where p.grv_id = g.id), 0) > 0.005),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'supplier_id', p.supplier_id, 'amount', p.amount, 'method', p.method,
        'paid_on', p.paid_on, 'note', p.note, 'grv_no', g.grv_no) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from (select * from public.supplier_payments order by created_at desc limit 100) p left join public.grvs g on g.id = p.grv_id));
end $$;
revoke all on function public.supplier_accounts() from public, anon;
grant execute on function public.supplier_accounts() to authenticated;

-- ---------------------------------------------------------------- expenses and profit
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  spent_on date not null default current_date,
  category text not null,
  description text,
  amount numeric(12,2) not null check (amount > 0),          -- including VAT
  vat_amount numeric(12,2) not null default 0 check (vat_amount >= 0),
  paid_from text not null default 'bank' check (paid_from in ('bank','cash','card')),
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists expenses_spent_on on public.expenses(spent_on);
create index if not exists expenses_created_by on public.expenses(created_by);
alter table public.expenses enable row level security;
create policy expenses_select on public.expenses for select to authenticated using ((select public.my_role()) = 'admin');
create policy expenses_insert on public.expenses for insert to authenticated with check ((select public.my_role()) = 'admin');
create policy expenses_update on public.expenses for update to authenticated using ((select public.my_role()) = 'admin') with check ((select public.my_role()) = 'admin');
create policy expenses_delete on public.expenses for delete to authenticated using ((select public.my_role()) = 'admin');

create or replace function public.profit_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz(); v_from timestamptz; v_to timestamptz; v_rate numeric;
  v_sales numeric; v_vat_out numeric; v_refunds numeric; v_cos numeric; v_waste numeric; v_exp numeric; v_exp_vat numeric; v_in_vat numeric; v_purch numeric;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'The profit report is for the admin only'; end if;
  v_from := p_from::timestamp at time zone tz;
  v_to := (p_to + 1)::timestamp at time zone tz;
  select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
  select coalesce(sum(subtotal), 0), coalesce(sum(vat), 0) into v_sales, v_vat_out
    from public.orders where created_at >= v_from and created_at < v_to and status <> 'void' and paid;
  select coalesce(sum(amount), 0) into v_refunds from public.refunds where created_at >= v_from and created_at < v_to;
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
    'refunds_excl', round(v_refunds * 100 / (100 + v_rate), 2),
    'net_sales', round(v_sales - v_refunds * 100 / (100 + v_rate), 2),
    'cost_of_sales', round(v_cos, 2),
    'waste', round(v_waste, 2),
    'gross_profit', round(v_sales - v_refunds * 100 / (100 + v_rate) - v_cos - v_waste, 2),
    'expenses', round(v_exp, 2),
    'net_profit', round(v_sales - v_refunds * 100 / (100 + v_rate) - v_cos - v_waste - v_exp, 2),
    'expense_categories', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'amount', a) order by a desc), '[]'::jsonb)
        from (select category, round(sum(amount - vat_amount), 2) a from public.expenses where spent_on between p_from and p_to group by 1) e),
    'purchases_excl', round(v_purch, 2),
    'vat_output', round(v_vat_out - v_refunds * v_rate / (100 + v_rate), 2),
    'vat_input_purchases', round(v_in_vat, 2),
    'vat_input_expenses', round(v_exp_vat, 2),
    'vat_payable', round(v_vat_out - v_refunds * v_rate / (100 + v_rate) - v_in_vat - v_exp_vat, 2));
end $$;
revoke all on function public.profit_report(date, date) from public, anon;
grant execute on function public.profit_report(date, date) to authenticated;

-- ---------------------------------------------------------------- stock-take
create table if not exists public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  taken_on date not null default current_date,
  status text not null default 'draft' check (status in ('draft','posted')),
  note text,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_at timestamptz
);
create index if not exists stocktakes_created_by on public.stocktakes(created_by);
create table if not exists public.stocktake_lines (
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  stock_item_id uuid not null references public.stock_items(id),
  expected_qty numeric(12,3) not null,
  counted_qty numeric(12,3),
  unit_cost numeric(12,4) not null default 0,
  primary key (stocktake_id, stock_item_id)
);
create index if not exists stocktake_lines_item on public.stocktake_lines(stock_item_id);
alter table public.stocktakes enable row level security;
alter table public.stocktake_lines enable row level security;
create policy stocktakes_select on public.stocktakes for select to authenticated using ((select public.my_role()) in ('admin','stock','supervisor'));
create policy stocktakes_delete on public.stocktakes for delete to authenticated using ((select public.my_role()) in ('admin','stock') and status = 'draft');
create policy stocktake_lines_select on public.stocktake_lines for select to authenticated using ((select public.my_role()) in ('admin','stock','supervisor'));
create policy stocktake_lines_update on public.stocktake_lines for update to authenticated
  using ((select public.my_role()) in ('admin','stock') and exists (select 1 from public.stocktakes t where t.id = stocktake_id and t.status = 'draft'))
  with check ((select public.my_role()) in ('admin','stock'));

create or replace function public.start_stocktake(p_note text default null) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','stock') then raise exception 'Not allowed'; end if;
  insert into public.stocktakes(note) values (nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  insert into public.stocktake_lines(stocktake_id, stock_item_id, expected_qty, unit_cost)
    select v_id, id, qty_on_hand, avg_cost from public.stock_items where active;
  return v_id;
end $$;
revoke all on function public.start_stocktake(text) from public, anon;
grant execute on function public.start_stocktake(text) to authenticated;

-- Compares each count with what the system has at this moment and corrects the stock.
create or replace function public.post_stocktake(p_id uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','stock') then raise exception 'Not allowed'; end if;
  if (select status from public.stocktakes where id = p_id for update) is distinct from 'draft' then
    raise exception 'This stock-take is not open';
  end if;
  update public.stocktake_lines l set expected_qty = si.qty_on_hand, unit_cost = si.avg_cost
    from public.stock_items si where si.id = l.stock_item_id and l.stocktake_id = p_id;
  insert into public.stock_movements(stock_item_id, qty_change, reason, ref_id, note)
    select stock_item_id, counted_qty - expected_qty, 'stocktake'::public.move_reason, p_id, 'Stock-take'
    from public.stocktake_lines where stocktake_id = p_id and counted_qty is not null and counted_qty <> expected_qty;
  update public.stocktakes set status = 'posted', posted_at = now() where id = p_id;
end $$;
revoke all on function public.post_stocktake(uuid) from public, anon;
grant execute on function public.post_stocktake(uuid) to authenticated;
