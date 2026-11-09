-- Tables, enums and stock logic for the restaurant POS.
-- Applied to the Supabase project "restaurant-pos".

create type public.app_role as enum ('cashier','kitchen','stock','admin','supervisor');
create type public.order_status as enum ('new','in_progress','ready','collected','void');
create type public.order_type as enum ('eat_in','take_away','delivery');
create type public.pay_method as enum ('cash','card_manual');
create type public.move_reason as enum ('grv','sale','sale_void','adjustment','waste','stocktake');
create type public.grv_status as enum ('draft','posted');

create table public.company_settings (
  id int primary key default 1 check (id = 1),
  company_name text not null default '',
  trading_name text not null default '',
  phone text, email text, address text,
  vat_number text, reg_number text,
  currency text not null default 'ZAR',
  vat_rate numeric(5,2) not null default 15,
  receipt_footer text,
  logo_url text,
  accept_cash boolean not null default true,
  accept_card_manual boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.staff_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.app_role not null default 'cashier',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order int not null default 0,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id),
  name text not null unique,
  description text,
  price numeric(10,2) not null check (price >= 0),
  active boolean not null default true,
  sort_order int not null default 0,
  updated_at timestamptz not null default now()
);

create table public.modifiers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  price_delta numeric(10,2) not null default 0,
  active boolean not null default true
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  contact_person text, phone text, email text,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.stock_items (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  category text not null,
  unit text not null,
  qty_on_hand numeric(14,3) not null default 0,
  min_level numeric(14,3) not null default 0,
  avg_cost numeric(12,4) not null default 0,
  supplier_id uuid references public.suppliers(id) on delete set null,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.recipe_lines (
  product_id uuid not null references public.products(id) on delete cascade,
  stock_item_id uuid not null references public.stock_items(id) on delete restrict,
  qty numeric(14,3) not null check (qty > 0),
  primary key (product_id, stock_item_id)
);

create table public.grvs (
  id uuid primary key default gen_random_uuid(),
  grv_no text not null unique,
  supplier_id uuid references public.suppliers(id) on delete set null,
  delivery_note text,
  received_on date not null default current_date,
  received_by uuid references public.staff_profiles(id) on delete set null,
  status public.grv_status not null default 'draft',
  subtotal numeric(12,2) not null default 0,
  vat numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.grv_lines (
  id uuid primary key default gen_random_uuid(),
  grv_id uuid not null references public.grvs(id) on delete cascade,
  stock_item_id uuid not null references public.stock_items(id),
  ordered_qty numeric(14,3),
  received_qty numeric(14,3) not null check (received_qty >= 0),
  unit_cost numeric(12,4) not null check (unit_cost >= 0),
  expiry_date date,
  line_total numeric(12,2) generated always as (round(received_qty * unit_cost, 2)) stored
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  stock_item_id uuid not null references public.stock_items(id),
  qty_change numeric(14,3) not null,
  reason public.move_reason not null,
  ref_id uuid,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Orders get their uuid and order_ref on the device, so tills can work offline.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_ref text not null unique,
  device_name text,
  status public.order_status not null default 'new',
  order_type public.order_type not null default 'eat_in',
  table_no text,
  customer_name text,
  subtotal numeric(12,2) not null default 0,
  vat numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  paid boolean not null default false,
  void_reason text,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  started_at timestamptz,
  ready_at timestamptz,
  collected_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  qty int not null check (qty > 0),
  unit_price numeric(10,2) not null,
  notes text,
  done boolean not null default false,
  done_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  method public.pay_method not null,
  amount numeric(12,2) not null check (amount > 0),
  tendered numeric(12,2),
  change_given numeric(12,2),
  card_brand text,
  card_last4 text check (card_last4 is null or card_last4 ~ '^[0-9]{4}$'),
  slip_no text,
  created_by uuid default auth.uid() references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index on public.products(category_id);
create index on public.stock_items(supplier_id);
create index on public.recipe_lines(stock_item_id);
create index on public.grvs(supplier_id);
create index on public.grvs(received_by);
create index on public.grv_lines(grv_id);
create index on public.grv_lines(stock_item_id);
create index on public.stock_movements(stock_item_id);
create index on public.orders(status, created_at);
create index on public.orders(created_by);
create index on public.order_items(order_id);
create index on public.order_items(product_id);
create index on public.payments(order_id);
create index on public.payments(created_by);

insert into public.company_settings (id) values (1);

create function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['company_settings','staff_profiles','categories','products','suppliers','stock_items','grvs','orders','order_items'] loop
    execute format('create trigger trg_touch before update on public.%I for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- The signed-in user's role (used by the security rules)
create function public.my_role() returns public.app_role language sql stable security definer set search_path = '' as $$
  select role from public.staff_profiles where id = (select auth.uid()) and active
$$;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;

-- First user to be created becomes admin; everyone after starts as cashier.
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.staff_profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    case when not exists (select 1 from public.staff_profiles) then 'admin'::public.app_role else 'cashier'::public.app_role end
  );
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Every stock movement updates the stock on hand
create function public.apply_stock_movement() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.stock_items set qty_on_hand = qty_on_hand + new.qty_change where id = new.stock_item_id;
  return new;
end $$;
revoke all on function public.apply_stock_movement() from public, anon, authenticated;
create trigger trg_apply_movement after insert on public.stock_movements for each row execute function public.apply_stock_movement();

-- Selling an item uses up its recipe ingredients
create function public.deduct_stock_for_item() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.product_id is not null then
    insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
    select rl.stock_item_id, -(rl.qty * new.qty), 'sale'::public.move_reason, new.id
    from public.recipe_lines rl where rl.product_id = new.product_id;
  end if;
  return new;
end $$;
revoke all on function public.deduct_stock_for_item() from public, anon, authenticated;
create trigger trg_deduct_stock after insert on public.order_items for each row execute function public.deduct_stock_for_item();

-- Voiding an order puts the ingredients back
create function public.restore_stock_on_void() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
  select rl.stock_item_id, rl.qty * oi.qty, 'sale_void'::public.move_reason, oi.id
  from public.order_items oi join public.recipe_lines rl on rl.product_id = oi.product_id
  where oi.order_id = new.id;
  return new;
end $$;
revoke all on function public.restore_stock_on_void() from public, anon, authenticated;
create trigger trg_restore_on_void after update of status on public.orders
  for each row when (new.status = 'void' and old.status is distinct from 'void')
  execute function public.restore_stock_on_void();

-- Posting a GRV adds the received stock and updates the average cost
create function public.post_grv(p_grv_id uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v_status public.grv_status; v_sub numeric(12,2); v_rate numeric(5,2);
begin
  if (select public.my_role()) is null or (select public.my_role()) not in ('admin','stock','supervisor') then
    raise exception 'Not allowed to post a GRV';
  end if;
  select status into v_status from public.grvs where id = p_grv_id for update;
  if v_status is null then raise exception 'GRV not found'; end if;
  if v_status = 'posted' then raise exception 'GRV already posted'; end if;

  update public.stock_items si set avg_cost = case
      when l.received_qty > 0 then round((greatest(si.qty_on_hand, 0) * si.avg_cost + l.received_qty * l.unit_cost) / (greatest(si.qty_on_hand, 0) + l.received_qty), 4)
      else si.avg_cost end
  from public.grv_lines l where l.grv_id = p_grv_id and l.stock_item_id = si.id;

  insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id)
  select stock_item_id, received_qty, 'grv'::public.move_reason, p_grv_id
  from public.grv_lines where grv_id = p_grv_id and received_qty > 0;

  select coalesce(sum(line_total), 0) into v_sub from public.grv_lines where grv_id = p_grv_id;
  select vat_rate into v_rate from public.company_settings where id = 1;
  update public.grvs set status = 'posted', subtotal = v_sub, vat = round(v_sub * v_rate / 100, 2), total = v_sub + round(v_sub * v_rate / 100, 2) where id = p_grv_id;
end $$;
revoke all on function public.post_grv(uuid) from public, anon;
grant execute on function public.post_grv(uuid) to authenticated;
