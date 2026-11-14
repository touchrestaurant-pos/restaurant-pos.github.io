-- ===== BOOTSTRAP =====
-- ============================================================
-- LOCAL POSTGRES BOOTSTRAP
-- Sets up auth stubs and Supabase-compatibility layer so the
-- existing migration files run unmodified against a plain
-- PostgreSQL 17 instance.
-- ============================================================

-- 1. Roles that Supabase creates automatically
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;

-- Grant basic privileges so policies/grants referencing these roles don't error
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated, service_role;

-- 2. Auth schema (minimal Supabase-compatible stub)
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE,
  encrypted_password text,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- auth.uid() returns the current session user id (set via SET LOCAL)
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid
$$;

-- auth.jwt() returns a dummy JWT payload
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'sub', current_setting('app.current_user_id', true),
    'role', 'authenticated'
  )
$$;

-- 3. Storage schema (stub — no file storage locally, but tables are referenced)
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL,
  public boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text REFERENCES storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Enable RLS on storage stubs so policies can be created
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- 4. Realtime publication stub (Supabase uses this; we create it so ALTER doesn't fail)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;

-- 5. Extensions that the app may use
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Done — now run the migration files in order.


-- ===== MIGRATION: 001_schema_and_stock_logic.sql =====
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


-- ===== MIGRATION: 002_security_rules_storage_realtime.sql =====
-- Row level security: what each role may read and change.
-- cashier, kitchen, stock, admin, supervisor

-- Generic tables: (table, roles that can read (null = any signed-in user), roles that can write)
do $$ declare r record; begin
  for r in select * from (values
    ('categories',   null::text[],                       array['admin']),
    ('products',     null::text[],                       array['admin']),
    ('modifiers',    null::text[],                       array['admin']),
    ('recipe_lines', null::text[],                       array['admin']),
    ('stock_items',  null::text[],                       array['admin','stock']),
    ('suppliers',    array['admin','supervisor','stock'], array['admin','stock']),
    ('grvs',         array['admin','supervisor','stock'], array['admin','stock']),
    ('grv_lines',    array['admin','supervisor','stock'], array['admin','stock'])
  ) as v(t, sel, wr) loop
    execute format('alter table public.%I enable row level security', r.t);
    if r.sel is null then
      execute format('create policy %I on public.%I for select to authenticated using (true)', r.t || '_select', r.t);
    else
      execute format('create policy %I on public.%I for select to authenticated using ((select public.my_role())::text = any(%L::text[]))', r.t || '_select', r.t, r.sel);
    end if;
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.my_role())::text = any(%L::text[]))', r.t || '_insert', r.t, r.wr);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.my_role())::text = any(%L::text[])) with check ((select public.my_role())::text = any(%L::text[]))', r.t || '_update', r.t, r.wr, r.wr);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.my_role())::text = any(%L::text[]))', r.t || '_delete', r.t, r.wr);
  end loop;
end $$;

-- Company settings: anyone can read (login screen shows name and logo); only admin edits
alter table public.company_settings enable row level security;
create policy company_select on public.company_settings for select to anon, authenticated using (true);
create policy company_update on public.company_settings for update to authenticated
  using ((select public.my_role()) = 'admin') with check ((select public.my_role()) = 'admin');

-- Staff: everyone signed in can see names and roles; only admin changes them
alter table public.staff_profiles enable row level security;
create policy staff_select on public.staff_profiles for select to authenticated using (true);
create policy staff_update on public.staff_profiles for update to authenticated
  using ((select public.my_role()) = 'admin') with check ((select public.my_role()) = 'admin');
create policy staff_delete on public.staff_profiles for delete to authenticated using ((select public.my_role()) = 'admin');

-- Stock movements: only stock, supervisor and admin; manual entries limited to adjustments, waste and stock takes
alter table public.stock_movements enable row level security;
create policy movements_select on public.stock_movements for select to authenticated
  using ((select public.my_role()) in ('admin','supervisor','stock'));
create policy movements_insert on public.stock_movements for insert to authenticated
  with check ((select public.my_role()) in ('admin','supervisor','stock') and reason in ('adjustment','waste','stocktake'));

-- Orders and order items
alter table public.orders enable row level security;
create policy orders_select on public.orders for select to authenticated using (true);
create policy orders_insert on public.orders for insert to authenticated
  with check ((select public.my_role()) in ('admin','cashier','supervisor'));
create policy orders_update on public.orders for update to authenticated
  using ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'))
  with check ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'));

alter table public.order_items enable row level security;
create policy order_items_select on public.order_items for select to authenticated using (true);
create policy order_items_insert on public.order_items for insert to authenticated
  with check ((select public.my_role()) in ('admin','cashier','supervisor'));
create policy order_items_update on public.order_items for update to authenticated
  using ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'))
  with check ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'));

-- Payments: kitchen and stock never see them
alter table public.payments enable row level security;
create policy payments_select on public.payments for select to authenticated
  using ((select public.my_role()) in ('admin','cashier','supervisor'));
create policy payments_insert on public.payments for insert to authenticated
  with check ((select public.my_role()) in ('admin','cashier','supervisor'));

-- Live updates for the kitchen queue and stock levels
alter publication supabase_realtime add table public.orders, public.order_items, public.stock_items;

-- Logo storage: public read of files, admin-only upload
insert into storage.buckets (id, name, public) values ('company-assets', 'company-assets', true) on conflict (id) do nothing;
create policy company_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'company-assets' and (select public.my_role()) = 'admin');
create policy company_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'company-assets' and (select public.my_role()) = 'admin')
  with check (bucket_id = 'company-assets' and (select public.my_role()) = 'admin');
create policy company_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'company-assets' and (select public.my_role()) = 'admin');


-- ===== MIGRATION: 003_sample_restaurant_data.sql =====
-- Sample fast-food restaurant data in Rands (VAT 15%, prices include VAT).
-- Replace with your real menu, stock and suppliers from the admin screens.

update public.company_settings set
  company_name = 'Grill House (Pty) Ltd', trading_name = 'Grill House',
  phone = '012 345 6789', email = 'info@grillhouse.example',
  address = '123 Church Street, Pretoria, 0002',
  vat_number = '4012345678', reg_number = '2020/123456/07',
  receipt_footer = 'Thank you for dining with us!'
where id = 1;

insert into public.suppliers (name, contact_person, phone, email) values
 ('Metro Foods Wholesale','Lerato Dlamini','012 555 0101','orders@metrofoods.example'),
 ('Fresh Fowl Poultry','Pieter van Wyk','012 555 0102','sales@freshfowl.example'),
 ('Prime Beef Supplies','Thabo Nkosi','012 555 0103','orders@primebeef.example'),
 ('Daily Bread Bakery','Aisha Patel','012 555 0104','orders@dailybread.example'),
 ('Valley Produce','Johan Botha','012 555 0105','sales@valleyproduce.example'),
 ('CoolDrinks Distribution','Mandla Khumalo','012 555 0106','orders@cooldrinks.example'),
 ('PackRight Packaging','Sarah Jacobs','012 555 0107','sales@packright.example');

insert into public.stock_items (name, category, unit, qty_on_hand, min_level, avg_cost, supplier_id)
select v.name, v.cat, v.unit, v.qty, v.minl, v.cost, s.id
from (values
 ('Chicken breast fillet (spicy)','Proteins','pc',148,80,12.40,'Fresh Fowl Poultry'),
 ('Chicken breast fillet (plain)','Proteins','pc',210,100,11.60,'Fresh Fowl Poultry'),
 ('Chicken wings','Proteins','pc',320,150,2.60,'Fresh Fowl Poultry'),
 ('Chicken strips','Proteins','pc',300,100,3.20,'Fresh Fowl Poultry'),
 ('Chicken quarter','Proteins','pc',44,30,14.00,'Fresh Fowl Poultry'),
 ('Beef patty','Proteins','pc',22,60,9.80,'Prime Beef Supplies'),
 ('Bacon rashers','Proteins','pc',160,60,2.60,'Prime Beef Supplies'),
 ('Hake fillet','Proteins','pc',0,30,11.50,'Metro Foods Wholesale'),
 ('Veggie patty','Proteins','pc',40,20,8.20,'Metro Foods Wholesale'),
 ('Burger bun (sesame)','Bakery','pc',96,100,2.60,'Daily Bread Bakery'),
 ('Kids bun','Bakery','pc',58,30,1.90,'Daily Bread Bakery'),
 ('Wrap tortilla','Bakery','pc',120,60,2.40,'Daily Bread Bakery'),
 ('Brownie (frozen)','Bakery','pc',45,20,8.50,'Daily Bread Bakery'),
 ('Cheddar cheese slice','Dairy','pc',310,120,1.35,'Metro Foods Wholesale'),
 ('Soft serve mix','Dairy','L',24,10,38.00,'Metro Foods Wholesale'),
 ('Milk','Dairy','L',30,12,14.50,'Metro Foods Wholesale'),
 ('Milkshake syrup - vanilla','Dairy','ml',3000,1000,0.040,'Metro Foods Wholesale'),
 ('Chocolate syrup','Dairy','ml',3000,1000,0.045,'Metro Foods Wholesale'),
 ('Lettuce','Produce','g',1800,800,0.037,'Valley Produce'),
 ('Tomato','Produce','g',3200,1000,0.028,'Valley Produce'),
 ('Onion','Produce','g',4500,1500,0.014,'Valley Produce'),
 ('Pickle slices','Produce','pc',540,200,0.13,'Valley Produce'),
 ('Mushrooms','Produce','g',2500,800,0.060,'Valley Produce'),
 ('Coleslaw mix','Produce','g',5000,1500,0.030,'Valley Produce'),
 ('Frozen chips','Frozen','g',38000,12000,0.026,'Metro Foods Wholesale'),
 ('Onion rings (frozen)','Frozen','g',6000,2000,0.055,'Metro Foods Wholesale'),
 ('Mayonnaise','Sauces','g',4200,1500,0.040,'Metro Foods Wholesale'),
 ('Peri-peri sauce','Sauces','ml',3000,1000,0.060,'Metro Foods Wholesale'),
 ('BBQ sauce','Sauces','ml',3500,1000,0.045,'Metro Foods Wholesale'),
 ('Burger sauce','Sauces','ml',2800,1000,0.050,'Metro Foods Wholesale'),
 ('Tartare sauce','Sauces','ml',1500,500,0.070,'Metro Foods Wholesale'),
 ('Tomato sauce sachet','Sauces','pc',900,300,0.45,'Metro Foods Wholesale'),
 ('Hot sauce (wings)','Sauces','ml',2000,600,0.070,'Metro Foods Wholesale'),
 ('Mushroom sauce','Sauces','ml',1800,600,0.060,'Metro Foods Wholesale'),
 ('Cooking oil','Dry goods','L',18,20,38.00,'Metro Foods Wholesale'),
 ('Spice coating mix','Dry goods','g',8000,2500,0.060,'Metro Foods Wholesale'),
 ('Salt','Dry goods','g',3000,1000,0.010,'Metro Foods Wholesale'),
 ('Cooldrink can 440ml','Drinks','pc',288,96,5.50,'CoolDrinks Distribution'),
 ('Bottled water 500ml','Drinks','pc',144,48,4.20,'CoolDrinks Distribution'),
 ('Iced tea bottle','Drinks','pc',72,24,6.50,'CoolDrinks Distribution'),
 ('Coffee beans','Drinks','g',3000,1000,0.250,'CoolDrinks Distribution'),
 ('Burger wrap paper','Packaging','pc',310,150,0.35,'PackRight Packaging'),
 ('Chip box (regular)','Packaging','pc',420,150,0.60,'PackRight Packaging'),
 ('Chip box (large)','Packaging','pc',330,100,0.85,'PackRight Packaging'),
 ('Wings box','Packaging','pc',250,80,1.10,'PackRight Packaging'),
 ('Milkshake cup','Packaging','pc',260,100,1.40,'PackRight Packaging'),
 ('Takeaway bag','Packaging','pc',400,150,0.70,'PackRight Packaging')
) as v(name, cat, unit, qty, minl, cost, sup)
join public.suppliers s on s.name = v.sup;

insert into public.categories (name, sort_order) values
 ('Burgers',1),('Chicken',2),('Wraps',3),('Sides',4),('Drinks',5),('Desserts',6),('Combos',7);

insert into public.products (category_id, name, description, price, sort_order)
select c.id, v.name, v.descr, v.price, v.sort
from (values
 ('Burgers','Chicken Burger','Crumbed fillet, mayo, lettuce, tomato',49.90,1),
 ('Burgers','Spicy Chicken Burger','Spicy fillet, mayo, lettuce, pickles',54.90,2),
 ('Burgers','Beef Burger','Beef patty, onion, tomato, burger sauce',52.90,3),
 ('Burgers','Double Beef Burger','Two patties, cheese, burger sauce',79.90,4),
 ('Burgers','Cheese Burger','Beef patty, cheddar, pickles',56.90,5),
 ('Burgers','Bacon Cheese Burger','Beef patty, bacon, cheddar',64.90,6),
 ('Burgers','BBQ Chicken Burger','Crumbed fillet, BBQ sauce, onion',57.90,7),
 ('Burgers','Peri-Peri Chicken Burger','Grilled fillet, peri-peri sauce',58.90,8),
 ('Burgers','Veggie Burger','Veggie patty, lettuce, tomato',49.90,9),
 ('Burgers','Fish Burger','Hake fillet, tartare sauce',54.90,10),
 ('Burgers','Mushroom Beef Burger','Beef patty, mushroom sauce',62.90,11),
 ('Burgers','Kids Burger','Small patty, plain bun',39.90,12),
 ('Chicken','6pc Wings','Six wings in hot sauce',69.90,1),
 ('Chicken','12pc Wings','Twelve wings in hot sauce',129.90,2),
 ('Chicken','Chicken Strips (5pc)','Five crumbed strips with burger sauce',64.90,3),
 ('Chicken','Quarter Chicken and Chips','Quarter chicken with regular chips',74.90,4),
 ('Chicken','Half Chicken and Chips','Half chicken with large chips',119.90,5),
 ('Wraps','Chicken Wrap','Fillet, lettuce, tomato, mayo',47.90,1),
 ('Wraps','Beef Wrap','Beef patty, onion, tomato, burger sauce',49.90,2),
 ('Wraps','Veggie Wrap','Veggie patty, lettuce, tomato, mayo',42.90,3),
 ('Sides','Regular Chips','Regular box',24.00,1),
 ('Sides','Large Chips','Large box',32.00,2),
 ('Sides','Onion Rings','Crumbed onion rings',28.00,3),
 ('Sides','Coleslaw','Creamy coleslaw',18.00,4),
 ('Sides','Garden Salad','Lettuce, tomato, onion',29.00,5),
 ('Drinks','Cooldrink 440ml','Can',18.00,1),
 ('Drinks','Bottled Water 500ml','Still water',14.00,2),
 ('Drinks','Iced Tea','Bottle',20.00,3),
 ('Drinks','Vanilla Milkshake','Thick vanilla shake',36.00,4),
 ('Drinks','Chocolate Milkshake','Thick chocolate shake',36.00,5),
 ('Drinks','Coffee','Fresh brewed with milk',24.00,6),
 ('Desserts','Soft Serve Cone','Vanilla soft serve',15.00,1),
 ('Desserts','Ice Cream Sundae','Soft serve with chocolate syrup',32.00,2),
 ('Desserts','Brownie','Warm chocolate brownie',28.00,3),
 ('Combos','Chicken Burger Combo','Chicken burger, regular chips, cooldrink',84.90,1),
 ('Combos','Spicy Chicken Burger Combo','Spicy burger, regular chips, cooldrink',89.90,2),
 ('Combos','Combo Meal - Beef','Beef burger, regular chips, cooldrink',87.90,3),
 ('Combos','Wings Combo','6pc wings, regular chips, cooldrink',104.90,4)
) as v(cat, name, descr, price, sort)
join public.categories c on c.name = v.cat;

insert into public.modifiers (name, price_delta) values
 ('No onion',0),('No mayo',0),('No pickles',0),('No sauce',0),('No tomato',0),('No salt',0),
 ('Extra cheese',8),('Extra hot sauce',3),('Extra bacon',12),('Well done',0),('Allergy - see note',0);

insert into public.recipe_lines (product_id, stock_item_id, qty)
select p.id, s.id, v.qty
from (values
 ('Chicken Burger','Chicken breast fillet (plain)',1),('Chicken Burger','Burger bun (sesame)',1),('Chicken Burger','Mayonnaise',20),('Chicken Burger','Lettuce',15),('Chicken Burger','Tomato',20),('Chicken Burger','Burger wrap paper',1),
 ('Spicy Chicken Burger','Chicken breast fillet (spicy)',1),('Spicy Chicken Burger','Burger bun (sesame)',1),('Spicy Chicken Burger','Mayonnaise',20),('Spicy Chicken Burger','Lettuce',15),('Spicy Chicken Burger','Pickle slices',3),('Spicy Chicken Burger','Burger wrap paper',1),
 ('Beef Burger','Beef patty',1),('Beef Burger','Burger bun (sesame)',1),('Beef Burger','Onion',15),('Beef Burger','Tomato',20),('Beef Burger','Burger sauce',20),('Beef Burger','Burger wrap paper',1),
 ('Double Beef Burger','Beef patty',2),('Double Beef Burger','Burger bun (sesame)',1),('Double Beef Burger','Cheddar cheese slice',2),('Double Beef Burger','Burger sauce',20),('Double Beef Burger','Burger wrap paper',1),
 ('Cheese Burger','Beef patty',1),('Cheese Burger','Burger bun (sesame)',1),('Cheese Burger','Cheddar cheese slice',1),('Cheese Burger','Pickle slices',3),('Cheese Burger','Burger sauce',15),('Cheese Burger','Burger wrap paper',1),
 ('Bacon Cheese Burger','Beef patty',1),('Bacon Cheese Burger','Burger bun (sesame)',1),('Bacon Cheese Burger','Cheddar cheese slice',1),('Bacon Cheese Burger','Bacon rashers',2),('Bacon Cheese Burger','Burger sauce',15),('Bacon Cheese Burger','Burger wrap paper',1),
 ('BBQ Chicken Burger','Chicken breast fillet (plain)',1),('BBQ Chicken Burger','Burger bun (sesame)',1),('BBQ Chicken Burger','BBQ sauce',25),('BBQ Chicken Burger','Onion',15),('BBQ Chicken Burger','Burger wrap paper',1),
 ('Peri-Peri Chicken Burger','Chicken breast fillet (plain)',1),('Peri-Peri Chicken Burger','Burger bun (sesame)',1),('Peri-Peri Chicken Burger','Peri-peri sauce',25),('Peri-Peri Chicken Burger','Lettuce',15),('Peri-Peri Chicken Burger','Burger wrap paper',1),
 ('Veggie Burger','Veggie patty',1),('Veggie Burger','Burger bun (sesame)',1),('Veggie Burger','Lettuce',15),('Veggie Burger','Tomato',20),('Veggie Burger','Mayonnaise',15),('Veggie Burger','Burger wrap paper',1),
 ('Fish Burger','Hake fillet',1),('Fish Burger','Burger bun (sesame)',1),('Fish Burger','Tartare sauce',20),('Fish Burger','Lettuce',15),('Fish Burger','Burger wrap paper',1),
 ('Mushroom Beef Burger','Beef patty',1),('Mushroom Beef Burger','Burger bun (sesame)',1),('Mushroom Beef Burger','Mushrooms',40),('Mushroom Beef Burger','Mushroom sauce',25),('Mushroom Beef Burger','Burger wrap paper',1),
 ('Kids Burger','Beef patty',1),('Kids Burger','Kids bun',1),('Kids Burger','Tomato sauce sachet',1),('Kids Burger','Burger wrap paper',1),
 ('6pc Wings','Chicken wings',6),('6pc Wings','Spice coating mix',30),('6pc Wings','Cooking oil',0.06),('6pc Wings','Hot sauce (wings)',20),('6pc Wings','Wings box',1),
 ('12pc Wings','Chicken wings',12),('12pc Wings','Spice coating mix',60),('12pc Wings','Cooking oil',0.12),('12pc Wings','Hot sauce (wings)',40),('12pc Wings','Wings box',1),
 ('Chicken Strips (5pc)','Chicken strips',5),('Chicken Strips (5pc)','Spice coating mix',25),('Chicken Strips (5pc)','Cooking oil',0.05),('Chicken Strips (5pc)','Burger sauce',30),('Chicken Strips (5pc)','Wings box',1),
 ('Quarter Chicken and Chips','Chicken quarter',1),('Quarter Chicken and Chips','Frozen chips',200),('Quarter Chicken and Chips','Cooking oil',0.08),('Quarter Chicken and Chips','Spice coating mix',20),('Quarter Chicken and Chips','Salt',3),('Quarter Chicken and Chips','Chip box (large)',1),
 ('Half Chicken and Chips','Chicken quarter',2),('Half Chicken and Chips','Frozen chips',250),('Half Chicken and Chips','Cooking oil',0.10),('Half Chicken and Chips','Spice coating mix',40),('Half Chicken and Chips','Salt',3),('Half Chicken and Chips','Chip box (large)',1),
 ('Chicken Wrap','Wrap tortilla',1),('Chicken Wrap','Chicken breast fillet (plain)',1),('Chicken Wrap','Lettuce',15),('Chicken Wrap','Tomato',20),('Chicken Wrap','Mayonnaise',20),('Chicken Wrap','Burger wrap paper',1),
 ('Beef Wrap','Wrap tortilla',1),('Beef Wrap','Beef patty',1),('Beef Wrap','Onion',15),('Beef Wrap','Tomato',20),('Beef Wrap','Burger sauce',20),('Beef Wrap','Burger wrap paper',1),
 ('Veggie Wrap','Wrap tortilla',1),('Veggie Wrap','Veggie patty',1),('Veggie Wrap','Lettuce',20),('Veggie Wrap','Tomato',20),('Veggie Wrap','Mayonnaise',15),('Veggie Wrap','Burger wrap paper',1),
 ('Regular Chips','Frozen chips',150),('Regular Chips','Cooking oil',0.04),('Regular Chips','Salt',2),('Regular Chips','Chip box (regular)',1),
 ('Large Chips','Frozen chips',250),('Large Chips','Cooking oil',0.06),('Large Chips','Salt',3),('Large Chips','Chip box (large)',1),
 ('Onion Rings','Onion rings (frozen)',120),('Onion Rings','Cooking oil',0.04),('Onion Rings','Chip box (regular)',1),
 ('Coleslaw','Coleslaw mix',100),('Coleslaw','Mayonnaise',15),
 ('Garden Salad','Lettuce',80),('Garden Salad','Tomato',60),('Garden Salad','Onion',20),
 ('Cooldrink 440ml','Cooldrink can 440ml',1),
 ('Bottled Water 500ml','Bottled water 500ml',1),
 ('Iced Tea','Iced tea bottle',1),
 ('Vanilla Milkshake','Soft serve mix',0.12),('Vanilla Milkshake','Milk',0.2),('Vanilla Milkshake','Milkshake syrup - vanilla',30),('Vanilla Milkshake','Milkshake cup',1),
 ('Chocolate Milkshake','Soft serve mix',0.12),('Chocolate Milkshake','Milk',0.2),('Chocolate Milkshake','Chocolate syrup',30),('Chocolate Milkshake','Milkshake cup',1),
 ('Coffee','Coffee beans',18),('Coffee','Milk',0.1),('Coffee','Milkshake cup',1),
 ('Soft Serve Cone','Soft serve mix',0.1),
 ('Ice Cream Sundae','Soft serve mix',0.15),('Ice Cream Sundae','Chocolate syrup',25),('Ice Cream Sundae','Milkshake cup',1),
 ('Brownie','Brownie (frozen)',1)
) as v(prod, stock, qty)
join public.products p on p.name = v.prod
join public.stock_items s on s.name = v.stock;

-- Combos are made from the recipes of their parts
insert into public.recipe_lines (product_id, stock_item_id, qty)
select cp.id, rl.stock_item_id, sum(rl.qty)
from (values
 ('Chicken Burger Combo','Chicken Burger'),('Chicken Burger Combo','Regular Chips'),('Chicken Burger Combo','Cooldrink 440ml'),
 ('Spicy Chicken Burger Combo','Spicy Chicken Burger'),('Spicy Chicken Burger Combo','Regular Chips'),('Spicy Chicken Burger Combo','Cooldrink 440ml'),
 ('Combo Meal - Beef','Beef Burger'),('Combo Meal - Beef','Regular Chips'),('Combo Meal - Beef','Cooldrink 440ml'),
 ('Wings Combo','6pc Wings'),('Wings Combo','Regular Chips'),('Wings Combo','Cooldrink 440ml')
) as v(combo, part)
join public.products cp on cp.name = v.combo
join public.products pp on pp.name = v.part
join public.recipe_lines rl on rl.product_id = pp.id
group by cp.id, rl.stock_item_id;

-- A sample draft GRV, ready to be posted from the stock screen
insert into public.grvs (grv_no, supplier_id, delivery_note, received_on, status, notes)
select 'GRV-000231', id, 'DN-20931', date '2026-11-09', 'draft', 'Sample draft GRV' from public.suppliers where name = 'Metro Foods Wholesale';

insert into public.grv_lines (grv_id, stock_item_id, ordered_qty, received_qty, unit_cost, expiry_date)
select g.id, s.id, v.ord, v.rec, v.cost, v.exp
from (values
 ('Chicken breast fillet (spicy)', 200, 200, 12.40, date '2026-11-20'),
 ('Beef patty', 120, 120, 9.80, date '2026-11-25'),
 ('Burger bun (sesame)', 240, 240, 2.60, date '2026-11-14')
) as v(item, ord, rec, cost, exp)
join public.stock_items s on s.name = v.item
join public.grvs g on g.grv_no = 'GRV-000231';


-- ===== MIGRATION: 004_staff_username.sql =====
-- Staff sign in with a username. Each username maps to a hidden internal email
-- (username@<staff login domain>) because Supabase logins need an email.

alter table public.staff_profiles add column username text;
create unique index staff_profiles_username_key on public.staff_profiles (lower(username)) where username is not null;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.staff_profiles (id, full_name, username, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    nullif(lower(new.raw_user_meta_data->>'username'), ''),
    case when not exists (select 1 from public.staff_profiles) then 'admin'::public.app_role else 'cashier'::public.app_role end
  );
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;


-- ===== MIGRATION: 005_order_cancel_time.sql =====
alter table public.orders add column if not exists voided_at timestamptz;


-- ===== MIGRATION: 006_company_assets_select.sql =====
create policy company_assets_select on storage.objects for select to authenticated using (bucket_id = 'company-assets');


-- ===== MIGRATION: 006b_company_settings_insert_policy.sql =====
-- Was applied to the live database on 2026-11-09 without a file here.
drop policy if exists company_insert on public.company_settings;
create policy company_insert on public.company_settings for insert to authenticated with check ((select public.my_role()) = 'admin');


-- ===== MIGRATION: 007_allow_upsert_inserts.sql =====
-- The app saves changes as "insert or update", so roles that may update a table also need the insert rule.
create policy company_insert on public.company_settings for insert to authenticated with check ((select public.my_role()) = 'admin');
drop policy orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'));
drop policy order_items_insert on public.order_items;
create policy order_items_insert on public.order_items for insert to authenticated
  with check ((select public.my_role()) in ('admin','cashier','kitchen','supervisor'));
create policy staff_insert on public.staff_profiles for insert to authenticated
  with check ((select public.my_role()) = 'admin');


-- ===== MIGRATION: 008_admin_report.sql =====
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


-- ===== MIGRATION: 009_refunds_cashup.sql =====
-- Refunds and end-of-day cash-ups (supervisor / admin)
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  method public.pay_method not null,
  reason text not null check (length(trim(reason)) > 0),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table public.cash_ups (
  id uuid primary key default gen_random_uuid(),
  business_date date not null,
  opening_float numeric(12,2) not null default 0,
  cash_sales numeric(12,2) not null,
  cash_refunds numeric(12,2) not null,
  expected_cash numeric(12,2) not null,
  counted_cash numeric(12,2) not null,
  variance numeric(12,2) not null,
  card_sales numeric(12,2) not null,
  card_refunds numeric(12,2) not null,
  card_slips integer not null,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.refunds enable row level security;
alter table public.cash_ups enable row level security;
create policy refunds_select on public.refunds for select to authenticated
  using ((select public.my_role()) in ('admin','supervisor'));
create policy cash_ups_select on public.cash_ups for select to authenticated
  using ((select public.my_role()) in ('admin','supervisor'));
-- Writes only through the functions below so the figures are checked on the server.

create function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid boolean; v_done numeric;
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can refund';
  end if;
  select total, paid into v_total, v_paid from public.orders where id = p_order_id;
  if v_total is null then raise exception 'Order not found'; end if;
  if not v_paid then raise exception 'This order was never paid, nothing to refund'; end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = p_order_id;
  if p_amount <= 0 or p_amount > v_total - v_done then
    raise exception 'Refund must be more than 0 and no more than R% (still refundable)', (v_total - v_done);
  end if;
  insert into public.refunds(order_id, amount, method, reason) values (p_order_id, round(p_amount,2), p_method, trim(p_reason));
end $$;
revoke all on function public.issue_refund(uuid, numeric, public.pay_method, text) from public, anon;
grant execute on function public.issue_refund(uuid, numeric, public.pay_method, text) to authenticated;

create function public.cash_up_summary(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from public.payments where method = 'cash' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),0),
    'cash_count', (select count(*) from public.payments where method = 'cash' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),
    'card_sales', coalesce((select sum(amount) from public.payments where method = 'card_manual' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),0),
    'card_slips', (select count(*) from public.payments where method = 'card_manual' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),
    'cash_refunds', coalesce((select sum(amount) from public.refunds where method = 'cash' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),0),
    'card_refunds', coalesce((select sum(amount) from public.refunds where method = 'card_manual' and (created_at at time zone 'Africa/Johannesburg')::date = p_date),0),
    'done', (select to_jsonb(c) from (select business_date, opening_float, expected_cash, counted_cash, variance, notes, created_at
              from public.cash_ups where business_date = p_date order by created_at desc limit 1) c)
  ) into r;
  return r;
end $$;
revoke all on function public.cash_up_summary(date) from public, anon;
grant execute on function public.cash_up_summary(date) to authenticated;

create function public.save_cash_up(p_date date, p_float numeric, p_counted numeric, p_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric;
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date);
  v_exp := round(p_float + (s->>'cash_sales')::numeric - (s->>'cash_refunds')::numeric, 2);
  insert into public.cash_ups(business_date, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, notes)
  values (p_date, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;
revoke all on function public.save_cash_up(date, numeric, numeric, text) from public, anon;
grant execute on function public.save_cash_up(date, numeric, numeric, text) to authenticated;

create function public.admin_refunds(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select public.my_role()) not in ('admin','supervisor') then
    raise exception 'Reports are for admin and supervisor only';
  end if;
  return jsonb_build_object(
    'total', coalesce((select sum(amount) from public.refunds where created_at >= p_from and created_at < p_to),0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('ref', o.order_ref, 'at', r.created_at, 'amount', r.amount,
        'method', r.method, 'reason', r.reason) order by r.created_at desc)
        from public.refunds r join public.orders o on o.id = r.order_id
        where r.created_at >= p_from and r.created_at < p_to), '[]'::jsonb));
end $$;
revoke all on function public.admin_refunds(timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_refunds(timestamptz, timestamptz) to authenticated;


-- ===== MIGRATION: 010_refund_restock.sql =====
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


-- ===== MIGRATION: 011_cancel_ack.sql =====
alter table public.orders add column if not exists cancel_ack_at timestamptz;
update public.orders set cancel_ack_at = now() where status = 'void' and cancel_ack_at is null;


-- ===== MIGRATION: 012_pos_upgrade.sql =====
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


-- ===== MIGRATION: 013_lock_internal_helpers.sql =====
-- Internal helpers used only inside other database functions.
revoke execute on function public.app_tz() from public, anon, authenticated;
revoke execute on function public.item_usage(uuid, uuid[], numeric) from public, anon, authenticated;


-- ===== MIGRATION: 014_vat_per_item.sql =====
alter table public.products add column if not exists vat_type text not null default 'standard'
  check (vat_type in ('standard','zero','exempt'));
alter table public.order_items add column if not exists vat_type text not null default 'standard'
  check (vat_type in ('standard','zero','exempt'));

create or replace function public.vat_report(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'vat_type', vat_type,
        'sales', round(sales, 2),
        'vat', round(case when vat_type = 'standard' then sales * v_rate / (100 + v_rate) else 0 end, 2),
        'excl', round(sales - case when vat_type = 'standard' then sales * v_rate / (100 + v_rate) else 0 end, 2))
      order by vat_type desc), '[]'::jsonb)
    from (select vat_type, sum(sales) sales from alloc group by vat_type) x
  );
end $$;
revoke all on function public.vat_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.vat_report(timestamptz, timestamptz) to authenticated;


-- ===== MIGRATION: 015_financials.sql =====
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


-- ===== MIGRATION: 016_note.sql =====
-- 015_financials.sql was applied to the live project in three parts on 2026-11-10
-- (financials_1_audit_totals_credit_notes, financials_2_day_close_cash_movements,
-- financials_3_purchases_expenses_stocktake) after grv_status gained the value 'reversed':
--   alter type public.grv_status add value if not exists 'reversed';


-- ===== MIGRATION: 017_account_tender_enum.sql =====
-- Customer accounts, step 1: a new way to pay. Kept on its own because a new enum
-- value cannot be used in the same transaction that adds it.
alter type public.pay_method add value if not exists 'account';


-- ===== MIGRATION: 018_customer_accounts.sql =====
-- Customer accounts (sales on account) with a full ledger.
--
-- Rules built in:
--  * No interest and no fees are ever added. Only sales, payments, credit notes
--    and documented write-offs touch an account. (Under the National Credit Act a
--    deferred payment only becomes a credit agreement when interest or fees are
--    charged, so this keeps accounts outside it.)
--  * The ledger is append-only. Nothing is edited or deleted; mistakes are
--    corrected with a new entry. Records are kept (tax records: 5 years).
--  * Only an admin creates accounts, sets limits and changes status. The server
--    checks status, limit, per-sale cap, overdue amounts and whether the cashier
--    may use the account, on every sale, whatever the app shows.
--  * Customer details are kept only with a recorded consent (POPIA).

create sequence if not exists public.account_no_seq;
create sequence if not exists public.account_receipt_seq;

alter table public.company_settings
  add column if not exists accounts_enabled boolean not null default false,
  add column if not exists account_grace_days integer not null default 7 check (account_grace_days between 0 and 60),
  add column if not exists account_block_overdue boolean not null default true;

create table public.customer_accounts (
  id uuid primary key default gen_random_uuid(),
  account_no text not null unique,
  name text not null check (length(trim(name)) > 0),
  contact_name text,
  phone text,
  email text,
  billing_address text,
  vat_no text,
  credit_limit numeric(12,2) not null default 0 check (credit_limit >= 0),
  max_sale numeric(12,2) check (max_sale is null or max_sale > 0),
  terms_days integer not null default 30 check (terms_days between 0 and 120),
  status text not null default 'active' check (status in ('active','blocked','stopped')),
  status_reason text,
  cashier_visible boolean not null default false,
  consent_at timestamptz,
  consent_note text,
  balance numeric(12,2) not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_touch before update on public.customer_accounts
  for each row execute function public.touch_updated_at();

create table public.account_transactions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.customer_accounts(id),
  kind text not null check (kind in ('sale','payment','credit_note','writeoff','writeoff_reversal')),
  amount numeric(12,2) not null,
  order_id uuid references public.orders(id),
  payment_id uuid unique,
  refund_id uuid unique,
  method text check (method is null or method in ('cash','card','eft')),
  reference text,
  note text,
  receipt_no bigint unique,
  business_date date not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint ledger_sign check (
    (kind in ('sale','writeoff_reversal') and amount > 0) or
    (kind in ('payment','credit_note','writeoff') and amount < 0))
);
create index account_transactions_account_idx on public.account_transactions(account_id, business_date, created_at);

alter table public.customer_accounts enable row level security;
alter table public.account_transactions enable row level security;
-- Reads for admin and supervisor only. There are no write policies at all:
-- every change goes through the functions below.
create policy accounts_select on public.customer_accounts for select to authenticated
  using ((select public.my_role())::text in ('admin','supervisor'));
create policy ledger_select on public.account_transactions for select to authenticated
  using ((select public.my_role())::text in ('admin','supervisor'));

create or replace function public.ledger_immutable() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and current_setting('pos.clearing', true) = 'on' then return old; end if;
  raise exception 'Account entries cannot be changed or deleted. Post a correcting entry instead.';
end $$;
create trigger trg_ledger_immutable before update or delete on public.account_transactions
  for each row execute function public.ledger_immutable();

create or replace function public.ledger_apply() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.customer_accounts set balance = balance + new.amount where id = new.account_id;
  return new;
end $$;
create trigger trg_ledger_apply after insert on public.account_transactions
  for each row execute function public.ledger_apply();

-- Audit trail for account details (balance changes are in the ledger itself).
create or replace function public.audit_account() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value)) into v
    from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
    where n.value is distinct from o.value and n.key not in ('updated_at','balance');
    if v is null then return new; end if;
  else
    v := to_jsonb(new);
  end if;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('customer_accounts', new.id::text, lower(tg_op), v);
  return new;
end $$;
create trigger trg_audit after insert or update on public.customer_accounts
  for each row execute function public.audit_account();

-- ---- paying an order on account -------------------------------------------------

alter table public.payments
  add column if not exists account_id uuid references public.customer_accounts(id),
  add column if not exists account_no text,
  add column if not exists account_name text,
  add column if not exists account_vat_no text,
  add column if not exists account_address text;
alter table public.payments add constraint payments_account_chk
  check ((method::text = 'account') = (account_id is not null));

-- Copies the customer's name and number onto the payment, so the tax invoice can
-- show who was charged (name, address and VAT number of the customer).
create or replace function public.account_snapshot() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts;
begin
  if new.method::text = 'account' then
    select * into a from public.customer_accounts where id = new.account_id;
    if found then
      new.account_no := a.account_no;
      new.account_name := a.name;
      new.account_vat_no := a.vat_no;
      new.account_address := a.billing_address;
    end if;
  else
    new.account_no := null; new.account_name := null; new.account_vat_no := null; new.account_address := null;
  end if;
  return new;
end $$;
create trigger trg_account_snapshot before insert on public.payments
  for each row execute function public.account_snapshot();

-- Runs after the payment row is accepted (so a safe retry of the same payment
-- does nothing twice) and refuses the sale if any rule is broken.
create or replace function public.account_charge() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a public.customer_accounts; cs public.company_settings;
  v_role text := coalesce((select public.my_role())::text, '');
  v_total numeric; v_paid numeric; v_ref text; v_od numeric;
begin
  if new.method::text <> 'account' then return new; end if;
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed to sell on account'; end if;
  select * into a from public.customer_accounts where id = new.account_id for update;
  if not found then raise exception 'Account not found'; end if;
  if a.status <> 'active' then
    raise exception 'Account % (%) is %. No new sales can be put on it.', a.account_no, a.name, a.status;
  end if;
  if v_role = 'cashier' and not a.cashier_visible then
    raise exception 'Account % is not available at the till.', a.account_no;
  end if;
  if a.consent_at is null then raise exception 'Account % has not been activated (no consent recorded).', a.account_no; end if;
  if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an account.'; end if;
  if a.credit_limit <= 0 then raise exception 'Account % has no credit limit.', a.account_no; end if;
  if a.balance + new.amount > a.credit_limit + 0.001 then
    raise exception 'Over the credit limit on account %. Available: R%.', a.account_no,
      to_char(greatest(a.credit_limit - a.balance, 0), 'FM999999990.00');
  end if;
  if a.max_sale is not null and new.amount > a.max_sale + 0.001 then
    raise exception 'The most allowed on account % in one sale is R%.', a.account_no, to_char(a.max_sale, 'FM999999990.00');
  end if;
  select * into cs from public.company_settings where id = 1;
  if cs.account_block_overdue then
    v_od := public.account_overdue(a.id);
    if v_od > 0 then
      raise exception 'Account % has R% overdue. Payment is needed before more credit.', a.account_no, to_char(v_od, 'FM999999990.00');
    end if;
  end if;
  select total, order_ref into v_total, v_ref from public.orders where id = new.order_id;
  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = new.order_id and id <> new.id;
  if new.amount > v_total - v_paid + 0.005 then
    raise exception 'The account amount is more than what is still owed on the order.';
  end if;
  insert into public.account_transactions(account_id, kind, amount, order_id, payment_id, reference, business_date, created_by)
  values (a.id, 'sale', round(new.amount, 2), new.order_id, new.id, v_ref,
          (now() at time zone public.app_tz())::date, coalesce(new.created_by, auth.uid()));
  return new;
end $$;
create trigger trg_account_charge after insert on public.payments
  for each row execute function public.account_charge();

-- A cancelled order puts its account amount back (a credit note on the account).
create or replace function public.account_on_void() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v_net numeric;
begin
  for r in select account_id, sum(amount) amt from public.payments
           where order_id = new.id and method::text = 'account' group by account_id loop
    select r.amt + coalesce(sum(amount), 0) into v_net from public.account_transactions
      where order_id = new.id and account_id = r.account_id and kind = 'credit_note';
    if v_net > 0 then
      insert into public.account_transactions(account_id, kind, amount, order_id, note, business_date)
      values (r.account_id, 'credit_note', -round(v_net, 2), new.id, 'Order cancelled',
              (now() at time zone public.app_tz())::date);
    end if;
  end loop;
  return new;
end $$;
create trigger trg_account_void after update on public.orders
  for each row when (new.status = 'void' and old.status <> 'void')
  execute function public.account_on_void();

-- ---- ageing helpers (oldest invoices are treated as paid first) --------------------

create or replace function public.account_open_items(p_account uuid)
returns table(txn_id uuid, txn_date date, kind text, charged numeric, outstanding numeric)
language sql stable security definer set search_path = '' as $$
  with ch as (
    select id, business_date, kind, amount,
           sum(amount) over (order by business_date, created_at, id) cum
    from public.account_transactions where account_id = p_account and amount > 0
  ), cr as (
    select coalesce(-sum(amount), 0) total from public.account_transactions where account_id = p_account and amount < 0
  )
  select ch.id, ch.business_date, ch.kind, ch.amount,
         round(least(ch.amount, greatest(0, ch.cum - cr.total)), 2)
  from ch cross join cr
$$;

create or replace function public.account_overdue(p_account uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(oi.outstanding), 0)
  from public.account_open_items(p_account) oi
  join public.customer_accounts a on a.id = p_account
  cross join (select account_grace_days g from public.company_settings where id = 1) cs
  where oi.outstanding > 0
    and (now() at time zone public.app_tz())::date - oi.txn_date > a.terms_days + cs.g
$$;

-- ---- functions the app calls ----------------------------------------------------------

-- Admin only: create or change an account's details. Status changes have their own function.
create or replace function public.save_account(p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid; v_name text := trim(coalesce(p->>'name', ''));
  v_limit numeric := coalesce(nullif(p->>'credit_limit', '')::numeric, 0);
  v_max numeric := nullif(p->>'max_sale', '')::numeric;
  v_terms int := coalesce(nullif(p->>'terms_days', '')::int, 30);
  v_vat text := nullif(trim(coalesce(p->>'vat_no', '')), '');
  v_email text := nullif(trim(coalesce(p->>'email', '')), '');
  v_phone text := nullif(trim(coalesce(p->>'phone', '')), '');
  v_vis boolean := coalesce((p->>'cashier_visible')::boolean, false);
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can manage accounts'; end if;
  if v_name = '' then raise exception 'The account needs a name'; end if;
  if v_limit < 0 or v_limit > 10000000 then raise exception 'Credit limit must be between R0 and R10 000 000'; end if;
  if v_max is not null and (v_max <= 0 or v_max > v_limit) then raise exception 'The most per sale must be more than R0 and not more than the credit limit'; end if;
  if v_terms < 0 or v_terms > 120 then raise exception 'Payment terms must be 0 to 120 days'; end if;
  if v_vat is not null and v_vat !~ '^[0-9]{10}$' then raise exception 'A VAT number has 10 digits'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right'; end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'That phone number is too short'; end if;
  if v_id is null then
    if coalesce((p->>'consent')::boolean, false) is not true then
      raise exception 'Tick that the customer agreed to the account terms and to us keeping their details';
    end if;
    insert into public.customer_accounts(account_no, name, contact_name, phone, email, billing_address, vat_no,
        credit_limit, max_sale, terms_days, cashier_visible, consent_at, consent_note)
    values ('ACC' || lpad(nextval('public.account_no_seq')::text, 4, '0'), v_name,
        nullif(trim(coalesce(p->>'contact_name', '')), ''), v_phone, v_email,
        nullif(trim(coalesce(p->>'billing_address', '')), ''), v_vat,
        round(v_limit, 2), round(v_max, 2), v_terms, v_vis, now(),
        nullif(trim(coalesce(p->>'consent_note', '')), ''))
    returning id into v_id;
  else
    update public.customer_accounts set name = v_name,
        contact_name = nullif(trim(coalesce(p->>'contact_name', '')), ''), phone = v_phone, email = v_email,
        billing_address = nullif(trim(coalesce(p->>'billing_address', '')), ''), vat_no = v_vat,
        credit_limit = round(v_limit, 2), max_sale = round(v_max, 2), terms_days = v_terms, cashier_visible = v_vis
    where id = v_id;
    if not found then raise exception 'Account not found'; end if;
  end if;
  return v_id;
end $$;

-- Admin only: allow (active), block (temporary) or stop (closed) an account.
create or replace function public.set_account_status(p_id uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can change an account''s status'; end if;
  if p_status not in ('active','blocked','stopped') then raise exception 'Unknown status'; end if;
  select * into a from public.customer_accounts where id = p_id for update;
  if not found then raise exception 'Account not found'; end if;
  if p_status in ('blocked','stopped') and length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Give a reason (at least 5 letters)';
  end if;
  if p_status = 'stopped' and abs(a.balance) > 0.005 then
    raise exception 'The account still has a balance of R%. Collect it or write it off before stopping the account.', a.balance;
  end if;
  update public.customer_accounts set status = p_status,
      status_reason = case when p_status = 'active' then null else trim(p_reason) end
  where id = p_id;
end $$;

-- What the till may offer. Cashiers see only accounts marked visible to them, and only
-- name, number, whether a sale is allowed and how much is available.
create or replace function public.till_accounts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); cs public.company_settings; out jsonb;
begin
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed'; end if;
  select * into cs from public.company_settings where id = 1;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into out from (
    select jsonb_build_object(
      'id', a.id, 'account_no', a.account_no, 'name', a.name, 'status', a.status,
      'billing_address', a.billing_address, 'vat_no', a.vat_no,
      'can_charge', r.reason is null,
      'reason', r.reason,
      'available', case when r.reason is null
          then least(greatest(a.credit_limit - a.balance, 0), coalesce(a.max_sale, greatest(a.credit_limit - a.balance, 0)))
          else 0 end) x
    from public.customer_accounts a
    cross join lateral (select case
        when a.status = 'blocked' then 'Blocked'
        when a.consent_at is null then 'Not activated'
        when a.credit_limit <= 0 then 'No credit limit'
        when a.balance >= a.credit_limit - 0.005 then 'At credit limit'
        when cs.account_block_overdue and public.account_overdue(a.id) > 0 then 'Overdue, payment needed'
        else null end reason) r
    where a.status <> 'stopped' and (v_role <> 'cashier' or a.cashier_visible)
  ) y;
  return out;
end $$;

-- Admin and supervisor: record money received from an account customer.
create or replace function public.record_account_payment(
  p_account uuid, p_amount numeric, p_method text, p_reference text, p_note text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_day date := (now() at time zone public.app_tz())::date;
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_no bigint; t public.account_transactions;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can record an account payment';
  end if;
  if p_method not in ('cash','card','eft') then raise exception 'Choose cash, card or EFT'; end if;
  select * into t from public.account_transactions where id = v_id;
  if found then
    select * into a from public.customer_accounts where id = t.account_id;
    return jsonb_build_object('receipt_no', t.receipt_no, 'balance', a.balance, 'account_no', a.account_no,
        'name', a.name, 'amount', -t.amount, 'method', t.method, 'date', t.business_date, 'repeat', true);
  end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if a.status = 'stopped' then raise exception 'This account is stopped'; end if;
  if a.balance <= 0.005 then raise exception 'Nothing is owing on this account'; end if;
  if v_amt > a.balance + 0.001 then raise exception 'The payment is more than the balance of R%.', a.balance; end if;
  if exists (select 1 from public.day_closes where business_date = v_day) then
    raise exception 'Today (%) is closed. An admin can reopen it.', v_day;
  end if;
  v_no := nextval('public.account_receipt_seq');
  insert into public.account_transactions(id, account_id, kind, amount, method, reference, note, receipt_no, business_date)
  values (v_id, a.id, 'payment', -v_amt, p_method, nullif(trim(coalesce(p_reference, '')), ''),
          nullif(trim(coalesce(p_note, '')), ''), v_no, v_day);
  select * into a from public.customer_accounts where id = a.id;
  return jsonb_build_object('receipt_no', v_no, 'balance', a.balance, 'account_no', a.account_no,
      'name', a.name, 'amount', v_amt, 'method', p_method, 'date', v_day, 'repeat', false);
end $$;

-- Admin only: write off an amount that cannot be collected. Needs a written reason.
-- The VAT treatment of a bad debt is for the accountant to decide.
create or replace function public.account_writeoff(p_account uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can write off a debt'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Write the reason for the write-off (at least 10 letters)'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if v_amt <= 0 or v_amt > a.balance + 0.001 then raise exception 'The write-off must be more than R0 and not more than the balance of R%.', a.balance; end if;
  insert into public.account_transactions(account_id, kind, amount, note, business_date)
  values (a.id, 'writeoff', -v_amt, trim(p_reason), (now() at time zone public.app_tz())::date);
end $$;

-- Admin only: put back a written-off amount (for example when the customer pays after all).
create or replace function public.account_reinstate(p_account uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_off numeric;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can reinstate a written-off debt'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Write the reason (at least 10 letters)'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  select coalesce(-sum(amount) filter (where kind = 'writeoff'), 0) - coalesce(sum(amount) filter (where kind = 'writeoff_reversal'), 0)
    into v_off from public.account_transactions where account_id = a.id;
  if v_amt <= 0 or v_amt > v_off + 0.001 then raise exception 'Only R% has been written off and not yet reinstated.', v_off; end if;
  insert into public.account_transactions(account_id, kind, amount, note, business_date)
  values (a.id, 'writeoff_reversal', v_amt, trim(p_reason), (now() at time zone public.app_tz())::date);
end $$;

-- Admin and supervisor: all accounts with balances and ageing.
create or replace function public.account_ageing() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone public.app_tz())::date; v_g int; out jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then raise exception 'Not allowed'; end if;
  select account_grace_days into v_g from public.company_settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'account_no', a.account_no, 'name', a.name, 'status', a.status, 'status_reason', a.status_reason,
      'contact_name', a.contact_name, 'phone', a.phone, 'email', a.email, 'billing_address', a.billing_address, 'vat_no', a.vat_no,
      'credit_limit', a.credit_limit, 'max_sale', a.max_sale, 'terms_days', a.terms_days,
      'cashier_visible', a.cashier_visible, 'consent_at', a.consent_at, 'balance', a.balance,
      'available', greatest(a.credit_limit - a.balance, 0),
      'current', coalesce(o.b1, 0), 'd31', coalesce(o.b2, 0), 'd61', coalesce(o.b3, 0), 'd90', coalesce(o.b4, 0),
      'overdue', coalesce(o.od, 0),
      'last_payment', (select max(t.business_date) from public.account_transactions t where t.account_id = a.id and t.kind = 'payment')
    ) order by a.name), '[]'::jsonb) into out
  from public.customer_accounts a
  left join lateral (
    select sum(oi.outstanding) filter (where v_today - oi.txn_date <= 30) b1,
           sum(oi.outstanding) filter (where v_today - oi.txn_date between 31 and 60) b2,
           sum(oi.outstanding) filter (where v_today - oi.txn_date between 61 and 90) b3,
           sum(oi.outstanding) filter (where v_today - oi.txn_date > 90) b4,
           sum(oi.outstanding) filter (where v_today - oi.txn_date > a.terms_days + v_g) od
    from public.account_open_items(a.id) oi where oi.outstanding > 0) o on true;
  return out;
end $$;

-- Admin and supervisor: a statement for one account between two dates.
create or replace function public.account_statement(p_account uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a public.customer_accounts; v_open numeric; v_lines jsonb; v_today date := (now() at time zone public.app_tz())::date; v_age jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then raise exception 'Not allowed'; end if;
  select * into a from public.customer_accounts where id = p_account;
  if not found then raise exception 'Account not found'; end if;
  select coalesce(sum(amount), 0) into v_open from public.account_transactions where account_id = p_account and business_date < p_from;
  select coalesce(jsonb_agg(jsonb_build_object(
      'date', l.business_date, 'kind', l.kind, 'amount', l.amount, 'running', l.running,
      'ref', l.ref, 'invoice_no', l.invoice_no, 'credit_note_no', l.credit_note_no,
      'method', l.method, 'reference', l.reference, 'note', l.note) order by l.business_date, l.created_at, l.id), '[]'::jsonb)
    into v_lines
  from (
    select t.id, t.business_date, t.created_at, t.kind, t.amount, t.method, t.reference, t.note,
           case when t.kind = 'payment' then 'ARC' || lpad(t.receipt_no::text, 5, '0') else o.order_ref end ref,
           o.invoice_no, r.credit_note_no,
           v_open + sum(t.amount) over (order by t.business_date, t.created_at, t.id) running
    from public.account_transactions t
    left join public.orders o on o.id = t.order_id
    left join public.refunds r on r.id = t.refund_id
    where t.account_id = p_account and t.business_date between p_from and p_to
  ) l;
  select jsonb_build_object(
      'current', coalesce(sum(outstanding) filter (where v_today - txn_date <= 30), 0),
      'd31', coalesce(sum(outstanding) filter (where v_today - txn_date between 31 and 60), 0),
      'd61', coalesce(sum(outstanding) filter (where v_today - txn_date between 61 and 90), 0),
      'd90', coalesce(sum(outstanding) filter (where v_today - txn_date > 90), 0))
    into v_age from public.account_open_items(p_account) where outstanding > 0;
  return jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'account_no', a.account_no, 'name', a.name, 'contact_name', a.contact_name,
        'phone', a.phone, 'email', a.email, 'billing_address', a.billing_address, 'vat_no', a.vat_no,
        'credit_limit', a.credit_limit, 'terms_days', a.terms_days, 'status', a.status, 'balance', a.balance),
    'from', p_from, 'to', p_to, 'opening', v_open, 'lines', v_lines,
    'closing', coalesce((select sum(amount) from public.account_transactions where account_id = p_account and business_date <= p_to), 0),
    'ageing', v_age, 'as_at', v_today);
end $$;

-- ---- refunds: put an account sale back on the account ---------------------------------

create or replace function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text, p_restock boolean default false)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid boolean; v_done numeric; v_status public.order_status; v_frac numeric;
        v_acct_paid numeric; v_acct_back numeric; v_acct uuid; v_accts int; v_rid uuid;
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
  select coalesce(sum(amount),0), min(account_id::text)::uuid, count(distinct account_id)
    into v_acct_paid, v_acct, v_accts from public.payments where order_id = p_order_id and method::text = 'account';
  select coalesce(sum(amount),0) into v_acct_back from public.refunds where order_id = p_order_id and method::text = 'account';
  if p_method::text = 'account' then
    if v_acct_paid <= 0 then raise exception 'This order was not paid on an account'; end if;
    if v_accts > 1 then raise exception 'This order was paid on more than one account. Ask the admin.'; end if;
    if p_amount > v_acct_paid - v_acct_back + 0.001 then
      raise exception 'Only R% of this order is still on the account.', (v_acct_paid - v_acct_back);
    end if;
  elsif v_acct_paid > 0 then
    if p_amount > (v_total - v_acct_paid) - (v_done - v_acct_back) + 0.001 then
      raise exception 'Only R% of this order was paid with cash or card. Refund the rest to the account.',
        ((v_total - v_acct_paid) - (v_done - v_acct_back));
    end if;
  end if;
  insert into public.refunds(order_id, amount, method, reason, restocked)
    values (p_order_id, round(p_amount,2), p_method, trim(p_reason), p_restock)
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
end $$;

-- ---- cash-up: account sales are not cash; cash received on accounts is ----------------

create or replace function public.cash_up_summary(p_date date, p_staff uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
  ), ar as (
    select * from public.account_transactions
    where kind = 'payment' and business_date = p_date and (p_staff is null or created_by = p_staff)
  )
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from p where method = 'cash'), 0),
    'cash_tips', coalesce((select sum(tip) from p where method = 'cash'), 0),
    'cash_count', (select count(*) from p where method = 'cash'),
    'card_sales', coalesce((select sum(amount) from p where method = 'card_manual'), 0),
    'card_tips', coalesce((select sum(tip) from p where method = 'card_manual'), 0),
    'card_slips', (select count(*) from p where method = 'card_manual'),
    'account_sales', coalesce((select sum(amount) from p where method::text = 'account'), 0),
    'acct_cash', coalesce((select -sum(amount) from ar where method = 'cash'), 0),
    'acct_card', coalesce((select -sum(amount) from ar where method = 'card'), 0),
    'acct_eft', coalesce((select -sum(amount) from ar where method = 'eft'), 0),
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
returns void
language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric; v_in numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date, p_staff);
  -- cash received from account customers goes into the drawer like any other cash in
  v_in := (s->>'cash_in')::numeric + (s->>'acct_cash')::numeric;
  v_exp := round(p_float + (s->>'cash_sales')::numeric + (s->>'cash_tips')::numeric - (s->>'cash_refunds')::numeric
           - (s->>'cash_out')::numeric + v_in, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, cash_out, cash_in, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, (s->>'cash_out')::numeric, v_in,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;

-- ---- clearing test sales also clears the test account entries ---------------------------

create or replace function public.clear_test_sales(p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n_orders int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can clear sales'; end if;
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
  delete from public.payments;
  delete from public.order_items;
  delete from public.orders;
  perform setval('public.invoice_seq', 1, false);
  return jsonb_build_object('orders_removed', n_orders);
end $$;

-- ---- who may call what -------------------------------------------------------------------

revoke execute on function public.ledger_immutable() from public, anon, authenticated;
revoke execute on function public.ledger_apply() from public, anon, authenticated;
revoke execute on function public.audit_account() from public, anon, authenticated;
revoke execute on function public.account_snapshot() from public, anon, authenticated;
revoke execute on function public.account_charge() from public, anon, authenticated;
revoke execute on function public.account_on_void() from public, anon, authenticated;
revoke execute on function public.account_open_items(uuid) from public, anon, authenticated;
revoke execute on function public.account_overdue(uuid) from public, anon, authenticated;

revoke execute on function public.save_account(jsonb) from public, anon;
revoke execute on function public.set_account_status(uuid, text, text) from public, anon;
revoke execute on function public.till_accounts() from public, anon;
revoke execute on function public.record_account_payment(uuid, numeric, text, text, text, uuid) from public, anon;
revoke execute on function public.account_writeoff(uuid, numeric, text) from public, anon;
revoke execute on function public.account_reinstate(uuid, numeric, text) from public, anon;
revoke execute on function public.account_ageing() from public, anon;
revoke execute on function public.account_statement(uuid, date, date) from public, anon;
grant execute on function public.save_account(jsonb) to authenticated;
grant execute on function public.set_account_status(uuid, text, text) to authenticated;
grant execute on function public.till_accounts() to authenticated;
grant execute on function public.record_account_payment(uuid, numeric, text, text, text, uuid) to authenticated;
grant execute on function public.account_writeoff(uuid, numeric, text) to authenticated;
grant execute on function public.account_reinstate(uuid, numeric, text) to authenticated;
grant execute on function public.account_ageing() to authenticated;
grant execute on function public.account_statement(uuid, date, date) to authenticated;


-- ===== MIGRATION: 019_account_credit_refund.sql =====
-- 019: give a customer's credit back (cash, card or EFT). Admin only, recorded in the ledger.
alter table public.account_transactions drop constraint account_transactions_kind_check;
alter table public.account_transactions add constraint account_transactions_kind_check
  check (kind in ('sale','payment','credit_note','writeoff','writeoff_reversal','credit_refund'));
alter table public.account_transactions drop constraint ledger_sign;
alter table public.account_transactions add constraint ledger_sign check (
  (kind in ('sale','writeoff_reversal','credit_refund') and amount > 0) or
  (kind in ('payment','credit_note','writeoff') and amount < 0));

-- Ageing: a credit refund is not a new charge; it takes back credit that was applied.
create or replace function public.account_open_items(p_account uuid)
returns table(txn_id uuid, txn_date date, kind text, charged numeric, outstanding numeric)
language sql stable security definer set search_path = '' as $$
  with ch as (
    select id, business_date, kind, amount,
           sum(amount) over (order by business_date, created_at, id) cum
    from public.account_transactions where account_id = p_account and kind in ('sale','writeoff_reversal')
  ), cr as (
    select coalesce(-sum(amount) filter (where amount < 0), 0) - coalesce(sum(amount) filter (where kind = 'credit_refund'), 0) total
    from public.account_transactions where account_id = p_account
  )
  select ch.id, ch.business_date, ch.kind, ch.amount,
         round(least(ch.amount, greatest(0, ch.cum - cr.total)), 2)
  from ch cross join cr
$$;

create or replace function public.refund_account_credit(
  p_account uuid, p_amount numeric, p_method text, p_reference text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_day date := (now() at time zone public.app_tz())::date;
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_no bigint; t public.account_transactions;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can pay out an account credit'; end if;
  if p_method not in ('cash','card','eft') then raise exception 'Choose cash, card or EFT'; end if;
  select * into t from public.account_transactions where id = v_id;
  if found then
    select * into a from public.customer_accounts where id = t.account_id;
    return jsonb_build_object('receipt_no', t.receipt_no, 'balance', a.balance, 'account_no', a.account_no,
        'name', a.name, 'amount', t.amount, 'method', t.method, 'date', t.business_date, 'repeat', true);
  end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if a.balance >= -0.005 then raise exception 'This account has no credit to pay out'; end if;
  if v_amt > -a.balance + 0.001 then raise exception 'The customer is only owed R%.', -a.balance; end if;
  if exists (select 1 from public.day_closes where business_date = v_day) then
    raise exception 'Today (%) is closed. An admin can reopen it.', v_day;
  end if;
  v_no := nextval('public.account_receipt_seq');
  insert into public.account_transactions(id, account_id, kind, amount, method, reference, note, receipt_no, business_date)
  values (v_id, a.id, 'credit_refund', v_amt, p_method, nullif(trim(coalesce(p_reference, '')), ''), 'Credit paid back to customer', v_no, v_day);
  select * into a from public.customer_accounts where id = a.id;
  return jsonb_build_object('receipt_no', v_no, 'balance', a.balance, 'account_no', a.account_no,
      'name', a.name, 'amount', v_amt, 'method', p_method, 'date', v_day, 'repeat', false);
end $$;
revoke execute on function public.refund_account_credit(uuid, numeric, text, text, uuid) from public, anon;
grant execute on function public.refund_account_credit(uuid, numeric, text, text, uuid) to authenticated;

create or replace function public.cash_up_summary(p_date date, p_staff uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
  ), ab as (
    select * from public.account_transactions
    where kind = 'credit_refund' and business_date = p_date and (p_staff is null or created_by = p_staff)
  ), ar as (
    select * from public.account_transactions
    where kind = 'payment' and business_date = p_date and (p_staff is null or created_by = p_staff)
  )
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from p where method = 'cash'), 0),
    'cash_tips', coalesce((select sum(tip) from p where method = 'cash'), 0),
    'cash_count', (select count(*) from p where method = 'cash'),
    'card_sales', coalesce((select sum(amount) from p where method = 'card_manual'), 0),
    'card_tips', coalesce((select sum(tip) from p where method = 'card_manual'), 0),
    'card_slips', (select count(*) from p where method = 'card_manual'),
    'account_sales', coalesce((select sum(amount) from p where method::text = 'account'), 0),
    'acct_cash', coalesce((select -sum(amount) from ar where method = 'cash'), 0),
    'acct_cash_back', coalesce((select sum(amount) from ab where method = 'cash'), 0),
    'acct_card', coalesce((select -sum(amount) from ar where method = 'card'), 0),
    'acct_eft', coalesce((select -sum(amount) from ar where method = 'eft'), 0),
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
returns void
language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric; v_in numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date, p_staff);
  -- cash received from account customers goes into the drawer like any other cash in
  v_in := (s->>'cash_in')::numeric + (s->>'acct_cash')::numeric;
  v_exp := round(p_float + (s->>'cash_sales')::numeric + (s->>'cash_tips')::numeric - (s->>'cash_refunds')::numeric
           - (s->>'cash_out')::numeric - (s->>'acct_cash_back')::numeric + v_in, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, cash_out, cash_in, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, (s->>'cash_out')::numeric + (s->>'acct_cash_back')::numeric, v_in,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;


-- ===== MIGRATION: 020_slip_options.sql =====
alter table public.company_settings
  add column if not exists show_vat_on_slip boolean not null default true,
  add column if not exists show_notes_on_slip boolean not null default false;


-- ===== MIGRATION: 021_till_disbursements.sql =====
-- 021: till disbursements (money taken out of the till, with category and reference), daily summary, disbursement report.
alter table public.cash_movements add column if not exists category text, add column if not exists reference text;
alter table public.company_settings
  add column if not exists disbursement_limit numeric(12,2) not null default 0 check (disbursement_limit >= 0),
  add column if not exists chart_style text not null default 'auto' check (chart_style in ('auto','bars','line','pie','ranked'));

create or replace function public.till_payout(p_amount numeric, p_category text, p_reference text, p_note text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_amt numeric := round(coalesce(p_amount, 0), 2);
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_day date := (now() at time zone public.app_tz())::date;
        v_lim numeric; v_kind text; m public.cash_movements;
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'You cannot take money from the till'; end if;
  select * into m from public.cash_movements where id = v_id;
  if found then return to_jsonb(m); end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  if length(trim(coalesce(p_category, ''))) = 0 then raise exception 'Choose what the money is for'; end if;
  if length(trim(coalesce(p_reference, ''))) = 0 then raise exception 'Enter a reference, such as a slip, invoice or receipt number'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what the money was used for'; end if;
  select disbursement_limit into v_lim from public.company_settings where id = 1;
  if v_role = 'cashier' and coalesce(v_lim, 0) > 0 and v_amt > v_lim then
    raise exception 'A cashier can take at most R% at a time. Ask a supervisor for more.', v_lim;
  end if;
  v_kind := case trim(p_category) when 'Cash drop to safe' then 'drop' when 'Tips paid out' then 'tip_payout' else 'payout' end;
  insert into public.cash_movements(id, business_date, kind, amount, note, staff_id, created_by, category, reference)
  values (v_id, v_day, v_kind, v_amt, trim(p_note), auth.uid(), auth.uid(), trim(p_category), trim(p_reference))
  returning * into m;
  return to_jsonb(m);
end $$;
revoke execute on function public.till_payout(numeric, text, text, text, uuid) from public, anon;
grant execute on function public.till_payout(numeric, text, text, text, uuid) to authenticated;

-- What a till user may see: their own pay-outs for the day, nothing about sales.
create or replace function public.my_payouts(p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_day date := coalesce(p_date, (now() at time zone public.app_tz())::date);
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'Not allowed'; end if;
  return jsonb_build_object('date', v_day,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.created_at, 'kind', m.kind, 'category', m.category,
          'reference', m.reference, 'note', m.note, 'amount', m.amount, 'by', coalesce(s.full_name, '')) order by m.created_at desc), '[]'::jsonb)
        from public.cash_movements m left join public.staff_profiles s on s.id = m.created_by
        where m.business_date = v_day and m.kind <> 'float_in' and (v_role <> 'cashier' or m.staff_id = auth.uid())),
    'total', (select coalesce(sum(amount), 0) from public.cash_movements m
        where m.business_date = v_day and m.kind <> 'float_in' and (v_role <> 'cashier' or m.staff_id = auth.uid())),
    'limit', (select disbursement_limit from public.company_settings where id = 1),
    'closed', exists (select 1 from public.day_closes where business_date = v_day));
end $$;
revoke execute on function public.my_payouts(date) from public, anon;
grant execute on function public.my_payouts(date) to authenticated;

create or replace function public.daily_summary(p_date date)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz(); v_from timestamptz := p_date::timestamp at time zone tz; v_to timestamptz := (p_date + 1)::timestamp at time zone tz;
        rep jsonb; cu jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'The daily summary is for supervisor and admin only';
  end if;
  rep := public.admin_report(v_from, v_to);
  cu := public.cash_up_summary(p_date);
  return jsonb_build_object(
    'date', p_date,
    'summary', rep->'summary', 'payments', rep->'payments', 'unpaid', rep->'unpaid', 'voided', rep->'voided',
    'by_staff', rep->'by_staff', 'vat', public.vat_report(v_from, v_to),
    'cash', cu - 'by_staff' - 'done',
    'cash_ups', (select coalesce(jsonb_agg(jsonb_build_object('staff', coalesce(s.full_name, 'Whole day'), 'float', c.opening_float,
        'expected', c.expected_cash, 'counted', c.counted_cash, 'variance', c.variance, 'notes', c.notes) order by c.created_at), '[]'::jsonb)
        from public.cash_ups c left join public.staff_profiles s on s.id = c.staff_id where c.business_date = p_date),
    'account_owed', coalesce((select sum(balance) from public.customer_accounts where balance > 0), 0),
    'closed', cu->'closed');
end $$;
revoke execute on function public.daily_summary(date) from public, anon;
grant execute on function public.daily_summary(date) to authenticated;

create or replace function public.disbursement_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz();
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'This report is for supervisor and admin only';
  end if;
  if p_to < p_from then raise exception 'The end date is before the start date'; end if;
  if p_to - p_from > 400 then raise exception 'Choose a period of 400 days or less'; end if;
  return (
    with mv as (
      select m.*, coalesce(m.category, case m.kind when 'drop' then 'Cash drop to safe' when 'tip_payout' then 'Tips paid out' else 'Other' end) cat
      from public.cash_movements m where m.business_date between p_from and p_to and m.kind <> 'float_in'
    ), days as (select d::date d from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'total', coalesce((select sum(amount) from mv), 0),
      'count', (select count(*) from mv),
      'float_in', coalesce((select sum(amount) from public.cash_movements where business_date between p_from and p_to and kind = 'float_in'), 0),
      'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'total', t, 'count', c) order by t desc), '[]'::jsonb)
          from (select cat, sum(amount) t, count(*) c from mv group by cat) q),
      'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d.d, 'total', coalesce(x.t, 0), 'count', coalesce(x.c, 0)) order by d.d), '[]'::jsonb)
          from days d left join (select business_date, sum(amount) t, count(*) c from mv group by business_date) x on x.business_date = d.d),
      'by_staff', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'total', t, 'count', c) order by t desc), '[]'::jsonb)
          from (select coalesce(s.full_name, 'Unknown') nm, sum(mv.amount) t, count(*) c
                from mv left join public.staff_profiles s on s.id = mv.staff_id group by 1) q),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('day', mv.business_date, 'at', mv.created_at, 'category', mv.cat, 'reference', mv.reference,
            'note', mv.note, 'amount', mv.amount, 'by', coalesce(s.full_name, '')) order by mv.created_at desc), '[]'::jsonb)
          from mv left join public.staff_profiles s on s.id = mv.staff_id),
      'cash_flow', (select coalesce(jsonb_agg(jsonb_build_object('day', d.d,
            'sales', coalesce((select sum(p.amount + p.tip) from public.payments p where p.method = 'cash' and (p.created_at at time zone tz)::date = d.d), 0),
            'accounts', coalesce((select -sum(t.amount) from public.account_transactions t where t.kind = 'payment' and t.method = 'cash' and t.business_date = d.d), 0),
            'float_in', coalesce((select sum(m.amount) from public.cash_movements m where m.kind = 'float_in' and m.business_date = d.d), 0),
            'refunds', coalesce((select sum(r.amount) from public.refunds r where r.method = 'cash' and (r.created_at at time zone tz)::date = d.d), 0),
            'credit_back', coalesce((select sum(t.amount) from public.account_transactions t where t.kind = 'credit_refund' and t.method = 'cash' and t.business_date = d.d), 0),
            'payouts', coalesce((select sum(m.amount) from public.cash_movements m where m.kind <> 'float_in' and m.business_date = d.d), 0)
          ) order by d.d), '[]'::jsonb) from days d)
    )
  );
end $$;
revoke execute on function public.disbursement_report(date, date) from public, anon;
grant execute on function public.disbursement_report(date, date) to authenticated;

create or replace function public.cash_up_summary(p_date date, p_staff uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
  ), ab as (
    select * from public.account_transactions
    where kind = 'credit_refund' and business_date = p_date and (p_staff is null or created_by = p_staff)
  ), ar as (
    select * from public.account_transactions
    where kind = 'payment' and business_date = p_date and (p_staff is null or created_by = p_staff)
  )
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from p where method = 'cash'), 0),
    'cash_tips', coalesce((select sum(tip) from p where method = 'cash'), 0),
    'cash_count', (select count(*) from p where method = 'cash'),
    'card_sales', coalesce((select sum(amount) from p where method = 'card_manual'), 0),
    'card_tips', coalesce((select sum(tip) from p where method = 'card_manual'), 0),
    'card_slips', (select count(*) from p where method = 'card_manual'),
    'account_sales', coalesce((select sum(amount) from p where method::text = 'account'), 0),
    'acct_cash', coalesce((select -sum(amount) from ar where method = 'cash'), 0),
    'acct_cash_back', coalesce((select sum(amount) from ab where method = 'cash'), 0),
    'acct_card', coalesce((select -sum(amount) from ar where method = 'card'), 0),
    'acct_eft', coalesce((select -sum(amount) from ar where method = 'eft'), 0),
    'cash_refunds', coalesce((select sum(amount) from rf where method = 'cash'), 0),
    'card_refunds', coalesce((select sum(amount) from rf where method = 'card_manual'), 0),
    'cash_out', coalesce((select sum(amount) from mv where kind <> 'float_in'), 0),
    'cash_in', coalesce((select sum(amount) from mv where kind = 'float_in'), 0),
    'movements', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'amount', m.amount, 'note', m.note,
          'at', m.created_at, 'by', coalesce(s.full_name, ''), 'reference', m.reference, 'category', m.category) order by m.created_at), '[]'::jsonb)
        from mv m left join public.staff_profiles s on s.id = m.created_by),
    'out_by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'total', total) order by total desc), '[]'::jsonb)
        from (select coalesce(category, case kind when 'drop' then 'Cash drop to safe' when 'tip_payout' then 'Tips paid out' else 'Other' end) category,
                     sum(amount) total from mv where kind <> 'float_in' group by 1) q),
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


-- ===== MIGRATION: 022_delete_stock_item.sql =====
-- Was applied to the live database on 2026-11-12 without a file here.
create or replace function public.delete_stock_item(p_id uuid)
returns text
language plpgsql security definer set search_path = '' as $$
declare v_names text; v_item public.stock_items;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then
    raise exception 'Only an admin can delete a stock item';
  end if;
  select * into v_item from public.stock_items where id = p_id for update;
  if not found then raise exception 'Stock item not found'; end if;
  select string_agg(distinct p.name, ', ') into v_names
    from public.recipe_lines rl join public.products p on p.id = rl.product_id where rl.stock_item_id = p_id;
  if v_names is not null then
    raise exception 'It is used in the recipe for: %. Take it out of those recipes first.', v_names;
  end if;
  select string_agg(distinct m.name, ', ') into v_names from public.modifiers m where m.stock_item_id = p_id;
  if v_names is not null then
    raise exception 'It is used by the special request: %. Change that request first.', v_names;
  end if;
  begin
    delete from public.stock_items where id = p_id;
    return 'deleted';
  exception when foreign_key_violation then
    -- It has history (deliveries, movements, orders). History is never erased, so the item is hidden instead.
    update public.stock_items set active = false, updated_at = now() where id = p_id;
    return 'archived';
  end;
end $$;
revoke execute on function public.delete_stock_item(uuid) from public, anon;
grant execute on function public.delete_stock_item(uuid) to authenticated;


-- ===== MIGRATION: 023_audit_and_manager_pin.sql =====
-- More of the money and stock events go into the change history.
do $$ declare t text; begin
  foreach t in array array['cash_movements','cash_ups','refunds','grvs','purchase_orders','supplier_payments','day_closes','expenses','stocktakes'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists trg_audit on public.%I', t);
      execute format('create trigger trg_audit after insert or update or delete on public.%I for each row execute function public.audit_row()', t);
    end if;
  end loop;
end $$;

-- Manager approval PIN. Only the hash is kept, in a table nobody can read directly.
create table if not exists public.manager_pins (
  staff_id uuid primary key references public.staff_profiles(id) on delete cascade,
  salt text not null,
  pin_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.manager_pins enable row level security;
revoke all on public.manager_pins from public, anon, authenticated;

create or replace function public.set_approval_pin(p_pin text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_salt text := gen_random_uuid()::text;
begin
  if coalesce((select public.my_role())::text,'') not in ('admin','supervisor') then raise exception 'Only an admin or supervisor can set an approval PIN'; end if;
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'The PIN must be 4 to 6 digits'; end if;
  insert into public.manager_pins(staff_id, salt, pin_hash)
  values (auth.uid(), v_salt, encode(sha256(convert_to(v_salt||p_pin,'UTF8')),'hex'))
  on conflict (staff_id) do update set salt = excluded.salt, pin_hash = excluded.pin_hash, updated_at = now();
  insert into public.audit_log(table_name,row_id,action) values ('manager_pins', auth.uid()::text, 'pin_set');
end $$;

create or replace function public.has_approval_pin() returns boolean
language sql security definer set search_path = '' stable as $$
  select exists(select 1 from public.manager_pins where staff_id = auth.uid())
$$;

-- A cashier asks a manager to approve something. Five wrong PINs in 10 minutes locks the till user out for 10 minutes.
create or replace function public.approve_with_pin(p_pin text, p_what text, p_detail text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare v_fail int; v_name text; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select count(*) into v_fail from public.audit_log
    where table_name='approval' and action='failed' and user_id = auth.uid() and at > now() - interval '10 minutes';
  if v_fail >= 5 then raise exception 'Too many wrong PINs. Wait 10 minutes or ask the manager to log in.'; end if;
  select mp.staff_id, sp.full_name into v_id, v_name
    from public.manager_pins mp join public.staff_profiles sp on sp.id = mp.staff_id
    where sp.role::text in ('admin','supervisor') and coalesce(sp.active,true)
      and mp.pin_hash = encode(sha256(convert_to(mp.salt||p_pin,'UTF8')),'hex')
    limit 1;
  if v_id is null then
    -- Recorded and returned (not raised) so the failed attempt is kept and counts toward the lock-out.
    insert into public.audit_log(table_name,row_id,action,changes) values ('approval', null, 'failed', jsonb_build_object('what', p_what));
    return null;
  end if;
  insert into public.audit_log(table_name,row_id,action,changes)
    values ('approval', v_id::text, 'approved', jsonb_build_object('what', p_what, 'detail', p_detail, 'approved_by', v_name));
  return v_name;
end $$;

revoke execute on function public.set_approval_pin(text), public.has_approval_pin(), public.approve_with_pin(text,text,text) from public, anon;
grant execute on function public.set_approval_pin(text), public.has_approval_pin(), public.approve_with_pin(text,text,text) to authenticated;


-- ===== MIGRATION: 024_staff_permissions.sql =====
-- Per-user permission settings (set by the admin on the Staff screen). A missing key means "use the default".
alter table public.staff_profiles add column if not exists perms jsonb not null default '{}'::jsonb;

create or replace function public.my_perm(k text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select perms -> k from public.staff_profiles where id = auth.uid()
$$;
revoke execute on function public.my_perm(text) from public, anon;
grant execute on function public.my_perm(text) to authenticated;

-- Till pay-outs: a cashier can be switched off, and can have their own limit (blank = the company limit, 0 = no limit).
create or replace function public.till_payout(p_amount numeric, p_category text, p_reference text, p_note text, p_id uuid DEFAULT NULL::uuid)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_role text := coalesce((select public.my_role())::text, ''); v_amt numeric := round(coalesce(p_amount, 0), 2);
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_day date := (now() at time zone public.app_tz())::date;
        v_lim numeric; v_kind text; m public.cash_movements; v_pl jsonb;
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'You cannot take money from the till'; end if;
  if v_role = 'cashier' and public.my_perm('can_payout') = 'false'::jsonb then raise exception 'You are not allowed to take money from the till. Ask the admin.'; end if;
  select * into m from public.cash_movements where id = v_id;
  if found then return to_jsonb(m); end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  if length(trim(coalesce(p_category, ''))) = 0 then raise exception 'Choose what the money is for'; end if;
  if length(trim(coalesce(p_reference, ''))) = 0 then raise exception 'Enter a reference, such as a slip, invoice or receipt number'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what the money was used for'; end if;
  select disbursement_limit into v_lim from public.company_settings where id = 1;
  v_pl := public.my_perm('payout_limit');
  if v_pl is not null and jsonb_typeof(v_pl) = 'number' then v_lim := (v_pl #>> '{}')::numeric; end if;
  if v_role = 'cashier' and coalesce(v_lim, 0) > 0 and v_amt > v_lim then
    raise exception 'You can take at most R% at a time. Ask a supervisor for more.', v_lim;
  end if;
  v_kind := case trim(p_category) when 'Cash drop to safe' then 'drop' when 'Tips paid out' then 'tip_payout' else 'payout' end;
  insert into public.cash_movements(id, business_date, kind, amount, note, staff_id, created_by, category, reference)
  values (v_id, v_day, v_kind, v_amt, trim(p_note), auth.uid(), auth.uid(), trim(p_category), trim(p_reference))
  returning * into m;
  return to_jsonb(m);
end $function$;

-- Account sales: a cashier can be switched off from selling on account.
create or replace function public.account_charge() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a public.customer_accounts; cs public.company_settings;
  v_role text := coalesce((select public.my_role())::text, '');
  v_total numeric; v_paid numeric; v_ref text; v_od numeric;
begin
  if new.method::text <> 'account' then return new; end if;
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed to sell on account'; end if;
  if v_role = 'cashier' and public.my_perm('can_account_sale') = 'false'::jsonb then
    raise exception 'You are not allowed to sell on account. Ask the admin.';
  end if;
  select * into a from public.customer_accounts where id = new.account_id for update;
  if not found then raise exception 'Account not found'; end if;
  if a.status <> 'active' then
    raise exception 'Account % (%) is %. No new sales can be put on it.', a.account_no, a.name, a.status;
  end if;
  if v_role = 'cashier' and not a.cashier_visible then
    raise exception 'Account % is not available at the till.', a.account_no;
  end if;
  if a.consent_at is null then raise exception 'Account % has not been activated (no consent recorded).', a.account_no; end if;
  if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an account.'; end if;
  if a.credit_limit <= 0 then raise exception 'Account % has no credit limit.', a.account_no; end if;
  if a.balance + new.amount > a.credit_limit + 0.001 then
    raise exception 'Over the credit limit on account %. Available: R%.', a.account_no,
      to_char(greatest(a.credit_limit - a.balance, 0), 'FM999999990.00');
  end if;
  if a.max_sale is not null and new.amount > a.max_sale + 0.001 then
    raise exception 'The most allowed on account % in one sale is R%.', a.account_no, to_char(a.max_sale, 'FM999999990.00');
  end if;
  select * into cs from public.company_settings where id = 1;
  if cs.account_block_overdue then
    v_od := public.account_overdue(a.id);
    if v_od > 0 then
      raise exception 'Account % has R% overdue. Payment is needed before more credit.', a.account_no, to_char(v_od, 'FM999999990.00');
    end if;
  end if;
  select total, order_ref into v_total, v_ref from public.orders where id = new.order_id;
  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = new.order_id and id <> new.id;
  if new.amount > v_total - v_paid + 0.005 then
    raise exception 'The account amount is more than what is still owed on the order.';
  end if;
  insert into public.account_transactions(account_id, kind, amount, order_id, payment_id, reference, business_date, created_by)
  values (a.id, 'sale', round(new.amount, 2), new.order_id, new.id, v_ref,
          (now() at time zone public.app_tz())::date, coalesce(new.created_by, auth.uid()));
  return new;
end $$;

-- Every kitchen reprint is recorded: who, which order, when.
create or replace function public.log_reprint(p_order uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_ref text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select order_ref into v_ref from public.orders where id = p_order;
  insert into public.audit_log(table_name, row_id, action, changes)
  values ('orders', p_order::text, 'kitchen_reprint', jsonb_build_object('order_ref', v_ref));
end $$;
revoke execute on function public.log_reprint(uuid) from public, anon;
grant execute on function public.log_reprint(uuid) to authenticated;


-- ===== MIGRATION: 025_sales_integrity.sql =====
-- Sales integrity. The till works exactly as before (orders, items and payments are still saved on the device and
-- synced). The server now stops a modified app from changing money fields it should not.
--  * "paid" and the invoice number come only from payments the server has seen
--  * a cashier cannot raise a discount, change a price or quantity, or void items on a paid order
--  * a discount over the cashier's limit needs a one-time manager approval; without it the discount is cut back
--    to the limit and logged (the sale is never lost)
--  * a cashier's own name is always put on the orders and payments they create

alter table public.orders add column if not exists discount_approval uuid;

create table if not exists public.discount_approvals (
  id uuid primary key default gen_random_uuid(),
  cashier uuid not null,
  approver uuid not null,
  amount numeric(12,2) not null,
  detail text,
  created_at timestamptz not null default now(),
  used_order uuid
);
alter table public.discount_approvals enable row level security;
revoke all on public.discount_approvals from public, anon, authenticated;

-- Manager approves one discount. Returns {id, by}, or null when the PIN is wrong (the failed try is kept and counts toward the lock-out).
create or replace function public.approve_discount(p_pin text, p_amount numeric, p_detail text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fail int; v_name text; v_id uuid; v_ap uuid;
begin
  if coalesce((select public.my_role())::text, '') <> 'cashier' then raise exception 'Only a cashier asks for a discount approval'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the discount first'; end if;
  select count(*) into v_fail from public.audit_log
    where table_name = 'approval' and action = 'failed' and user_id = auth.uid() and at > now() - interval '10 minutes';
  if v_fail >= 5 then raise exception 'Too many wrong PINs. Wait 10 minutes or ask the manager to log in.'; end if;
  select mp.staff_id, sp.full_name into v_id, v_name
    from public.manager_pins mp join public.staff_profiles sp on sp.id = mp.staff_id
    where sp.role::text in ('admin','supervisor') and coalesce(sp.active, true)
      and mp.pin_hash = encode(sha256(convert_to(mp.salt || p_pin, 'UTF8')), 'hex')
    limit 1;
  if v_id is null then
    insert into public.audit_log(table_name, row_id, action, changes) values ('approval', null, 'failed', jsonb_build_object('what', 'discount'));
    return null;
  end if;
  insert into public.discount_approvals(cashier, approver, amount, detail) values (auth.uid(), v_id, round(p_amount, 2), p_detail) returning id into v_ap;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('approval', v_id::text, 'approved', jsonb_build_object('what', 'discount', 'detail', p_detail, 'approved_by', v_name, 'amount', p_amount));
  return jsonb_build_object('id', v_ap, 'by', v_name);
end $$;
revoke execute on function public.approve_discount(text, numeric, text) from public, anon;
grant execute on function public.approve_discount(text, numeric, text) to authenticated;

-- Orders
create or replace function public.guard_order() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_role text := coalesce((select public.my_role())::text, '');
  v_mgr boolean := coalesce((select public.my_role())::text, '') in ('admin','supervisor');
  v_items numeric; v_std numeric; v_rate numeric; v_pj jsonb; v_lim numeric; v_gross numeric; v_found int;
begin
  if tg_op = 'UPDATE' then
    new.invoice_no := coalesce(old.invoice_no, new.invoice_no);
    new.created_by := coalesce(old.created_by, new.created_by);
    -- Only a payment the server has seen can make an order paid.
    if new.paid and not old.paid and coalesce(current_setting('pos.paying', true), '') <> '1' then new.paid := false; end if;
    if old.paid and not new.paid then new.paid := true; end if;
    if new.invoice_no is distinct from old.invoice_no and old.invoice_no is not null then new.invoice_no := old.invoice_no; end if;
    new.discount_approval := old.discount_approval;
    if not v_mgr and new.discount > old.discount + 0.005 then
      insert into public.audit_log(table_name, row_id, action, changes)
        values ('orders', new.id::text, 'blocked_change', jsonb_build_object('what', 'discount raised', 'from', old.discount, 'to', new.discount, 'order_ref', new.order_ref));
      new.discount := old.discount; new.discount_reason := old.discount_reason;
    end if;
    if old.status = 'void' then
      new.status := 'void';
      new.voided_at := old.voided_at;
      new.voided_by := old.voided_by;
      new.void_reason := coalesce(old.void_reason, new.void_reason);
    end if;
    new.cancel_ack_at := coalesce(new.cancel_ack_at, old.cancel_ack_at);
    if new.status = 'void' and old.status <> 'void' then
      if old.paid and not v_mgr then
        raise exception 'Only a supervisor or admin can cancel an order that has been paid';
      end if;
      if v_role = 'cashier' and not old.paid and public.my_perm('can_cancel_unpaid') = 'false'::jsonb then
        raise exception 'You are not allowed to cancel orders. Ask a supervisor.';
      end if;
      new.voided_by := coalesce(new.voided_by, auth.uid());
      new.voided_at := coalesce(new.voided_at, now());
    end if;
    select sum(qty * unit_price), sum(qty * unit_price) filter (where vat_type = 'standard')
      into v_items, v_std from public.order_items where order_id = new.id and not voided;
    if v_items is not null then
      select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
      new.total := round(greatest(v_items - new.discount, 0), 2);
      new.vat := round(new.total * (case when v_items > 0 then coalesce(v_std, 0) / v_items else 1 end) * v_rate / (100 + v_rate), 2);
      new.subtotal := new.total - new.vat;
    end if;
  else
    -- A new order is never paid until its payments arrive; the invoice number is given then.
    new.paid := false;
    new.invoice_no := null;
    new.created_by := case when v_role = 'cashier' then auth.uid() else coalesce(new.created_by, auth.uid()) end;
    if new.discount > 0 and not v_mgr then
      v_gross := new.total + new.discount;
      v_pj := public.my_perm('max_discount_pct');
      v_lim := case when jsonb_typeof(v_pj) = 'number' then (v_pj #>> '{}')::numeric else 10 end;
      if new.discount > v_gross * v_lim / 100 + 0.01 then
        update public.discount_approvals set used_order = new.id
          where id = new.discount_approval and cashier = auth.uid() and used_order is null
            and amount >= new.discount - 0.01
            and created_at > coalesce(new.created_at, now()) - interval '3 hours'
            and created_at < coalesce(new.created_at, now()) + interval '30 minutes';
        get diagnostics v_found = row_count;
        if v_found > 0 then
          insert into public.audit_log(table_name, row_id, action, changes)
            values ('orders', new.id::text, 'discount_approved', jsonb_build_object('discount', new.discount, 'order_ref', new.order_ref));
        else
          insert into public.audit_log(table_name, row_id, action, changes)
            values ('orders', new.id::text, 'discount_cut_back', jsonb_build_object('asked', new.discount, 'allowed', round(v_gross * v_lim / 100, 2), 'order_ref', new.order_ref));
          new.discount := round(v_gross * v_lim / 100, 2);
          new.total := round(v_gross - new.discount, 2);
        end if;
      end if;
    end if;
  end if;
  if new.paid and new.invoice_no is null then
    new.invoice_no := nextval('public.invoice_seq');
  end if;
  return new;
end $$;

-- A payment is what makes an order paid.
create or replace function public.mark_order_paid() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('pos.paying', '1', true);
  update public.orders o set paid = true
  where o.id = new.order_id and not o.paid
    and (select coalesce(sum(amount), 0) from public.payments where order_id = new.order_id) >= o.total - 0.005;
  perform set_config('pos.paying', '', true);
  return new;
end $$;

-- Items: a cashier or kitchen user cannot change what was sold or for how much.
create or replace function public.guard_order_item() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_paid boolean;
begin
  if v_role in ('admin','supervisor') then return new; end if;
  if new.unit_price is distinct from old.unit_price or new.qty is distinct from old.qty
     or new.vat_type is distinct from old.vat_type or new.product_id is distinct from old.product_id then
    insert into public.audit_log(table_name, row_id, action, changes)
      values ('order_items', new.id::text, 'blocked_change', jsonb_build_object('what', 'price or quantity', 'item', old.name,
        'price', jsonb_build_array(old.unit_price, new.unit_price), 'qty', jsonb_build_array(old.qty, new.qty)));
    new.unit_price := old.unit_price; new.qty := old.qty; new.vat_type := old.vat_type; new.product_id := old.product_id;
  end if;
  if new.voided and not old.voided then
    select paid into v_paid from public.orders where id = new.order_id;
    if coalesce(v_paid, false)
       or (old.done and v_role = 'cashier' and coalesce(public.my_perm('can_remove_sent'), 'false'::jsonb) <> 'true'::jsonb) then
      insert into public.audit_log(table_name, row_id, action, changes)
        values ('order_items', new.id::text, 'blocked_change', jsonb_build_object('what', 'item removed', 'item', old.name, 'order_paid', coalesce(v_paid, false)));
      new.voided := false; new.voided_at := old.voided_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_item on public.order_items;
create trigger trg_guard_item before update on public.order_items for each row execute function public.guard_order_item();

-- A cashier's payments always carry their own name.
create or replace function public.guard_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') = 'cashier' then new.created_by := auth.uid(); end if;
  return new;
end $$;
drop trigger if exists trg_guard_payment on public.payments;
create trigger trg_guard_payment before insert on public.payments for each row execute function public.guard_payment();

revoke execute on function public.guard_order(), public.mark_order_paid(), public.guard_order_item(), public.guard_payment() from public, anon, authenticated;


-- ===== MIGRATION: 026_refund_vat_tender.sql =====
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


-- ===== MIGRATION: 027_eft_enum.sql =====
-- EFT / bank transfer as a payment type (applied on its own so the new value can be used by 028).
alter type public.pay_method add value if not exists 'eft';


-- ===== MIGRATION: 028_eft_payments.sql =====
-- EFT / bank transfer payments: a required bank reference, an on/off switch, banking details for the cashier,
-- a separate line in the cash-up (it is not cash in the drawer), and a per-cashier permission.
alter table public.payments add column if not exists reference text;
alter table public.company_settings add column if not exists accept_eft boolean not null default false;
alter table public.company_settings add column if not exists eft_details text;

-- Cash-up: add EFT figures next to the card figures (patched in place so the rest of the function is untouched).
do $$ declare d text; begin
  d := pg_get_functiondef('public.cash_up_summary(date,uuid)'::regprocedure);
  if d not like '%eft_sales%' then
    d := replace(d, '''account_sales'', coalesce(',
      '''eft_sales'', coalesce((select sum(amount) from p where method::text = ''eft''), 0), ''eft_count'', (select count(*) from p where method::text = ''eft''), ''eft_refunds'', coalesce((select sum(amount) from rf where method::text = ''eft''), 0), ''account_sales'', coalesce(');
    d := replace(d, '''card'', coalesce(sum(p.amount) filter (where p.method = ''card_manual''), 0),',
      '''card'', coalesce(sum(p.amount) filter (where p.method = ''card_manual''), 0), ''eft'', coalesce(sum(p.amount) filter (where p.method::text = ''eft''), 0),');
    execute d;
  end if;
end $$;

-- Payments: EFT needs a reference, and a cashier can be switched off from taking it.
create or replace function public.guard_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, '');
begin
  if v_role = 'cashier' then new.created_by := auth.uid(); end if;
  if new.method::text = 'eft' then
    if length(trim(coalesce(new.reference, ''))) = 0 then raise exception 'An EFT payment needs the bank reference'; end if;
    if v_role = 'cashier' and public.my_perm('can_take_eft') = 'false'::jsonb then
      raise exception 'You are not allowed to take EFT payments. Ask the admin.';
    end if;
    if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an EFT payment'; end if;
  end if;
  return new;
end $$;


-- ===== MIGRATION: 029_receipt_style.sql =====
-- Receipt layout the owner can style (font size, logo size/hide, which header lines show, divider style).
-- One flexible column so new options need no further migration. Footer text stays in receipt_footer.
alter table public.company_settings add column if not exists receipt_style jsonb not null default '{}'::jsonb;


-- ===== MIGRATION: 030_suppliers_creditors.sql =====
-- Creditors: more supplier details, and a safe delete.
alter table public.suppliers add column if not exists address text;
alter table public.suppliers add column if not exists vat_no text;
alter table public.suppliers add column if not exists account_ref text;     -- our account number at the supplier
alter table public.suppliers add column if not exists terms_days int;       -- days we have to pay
alter table public.suppliers add column if not exists bank_details text;
alter table public.suppliers add column if not exists notes text;

-- Only the admin may delete a supplier, and never one with history: deleting would
-- unlink its deliveries (they would stop counting as owed). Make it inactive instead.
drop policy if exists suppliers_delete on public.suppliers;
create policy suppliers_delete on public.suppliers for delete to authenticated
  using ((select public.my_role()) = 'admin');

create or replace function public.guard_supplier_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.grvs where supplier_id = old.id)
     or exists (select 1 from public.supplier_payments where supplier_id = old.id)
     or exists (select 1 from public.purchase_orders where supplier_id = old.id) then
    raise exception '% has deliveries, payments or purchase orders on record, so it cannot be deleted. Switch it to inactive instead.', old.name;
  end if;
  return old;
end $$;
revoke all on function public.guard_supplier_delete() from public, anon, authenticated;
drop trigger if exists guard_supplier_delete on public.suppliers;
create trigger guard_supplier_delete before delete on public.suppliers
  for each row execute function public.guard_supplier_delete();


-- ===== MIGRATION: 031_price_and_time_integrity.sql =====
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


-- ===== MIGRATION: 032_profit_report_refunds.sql =====
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


-- ===== MIGRATION: 033_lock_posted_deliveries_and_stock.sql =====
-- Posted deliveries and stock levels can only change through the proper actions
-- (post delivery, reverse delivery, stock movement, sale), never by editing rows directly.
-- These trigger functions are deliberately NOT security definer: current_user is 'authenticated'
-- for a direct edit from the app or browser, and 'postgres' inside the server's own functions.

create or replace function public.guard_grv() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    return new;
  end if;
  if old.status <> 'draft' then
    raise exception 'Delivery % is already posted. Reverse it instead of changing or deleting it.', old.grv_no;
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    raise exception 'Use Post or Reverse to change the status of a delivery.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists trg_guard_grv on public.grvs;
create trigger trg_guard_grv before insert or update or delete on public.grvs
  for each row execute function public.guard_grv();

create or replace function public.guard_grv_line() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text; v_no text;
begin
  if current_user not in ('authenticated', 'anon') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  select status::text, grv_no::text into v_status, v_no from public.grvs
   where id = case when tg_op = 'DELETE' then old.grv_id else new.grv_id end;
  if coalesce(v_status, 'draft') <> 'draft' then
    raise exception 'Delivery % is already posted. Its lines cannot be changed.', v_no;
  end if;
  if tg_op = 'UPDATE' and new.grv_id is distinct from old.grv_id then
    select status::text into v_status from public.grvs where id = old.grv_id;
    if coalesce(v_status, 'draft') <> 'draft' then raise exception 'Lines cannot be moved off a posted delivery.'; end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists trg_guard_grv_line on public.grv_lines;
create trigger trg_guard_grv_line before insert or update or delete on public.grv_lines
  for each row execute function public.guard_grv_line();

create or replace function public.guard_stock_item() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.qty_on_hand := 0;   -- opening stock goes in as a stock movement so it is recorded
    return new;
  end if;
  if new.qty_on_hand is distinct from old.qty_on_hand or new.avg_cost is distinct from old.avg_cost then
    raise exception 'Stock on hand and average cost change only through deliveries, sales, stock-takes and adjustments.';
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_stock_item on public.stock_items;
create trigger trg_guard_stock_item before insert or update on public.stock_items
  for each row execute function public.guard_stock_item();


-- ===== MIGRATION: 034_go_live_guard.sql =====
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


-- ===== MIGRATION: 035_stock_categories.sql =====
-- Stock categories the admin can add, rename and delete. Stock items keep the category name as text;
-- renaming or deleting a category updates the items in one step on the server.
create table if not exists public.stock_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
insert into public.stock_categories(name)
  select distinct trim(category) from public.stock_items where coalesce(trim(category), '') <> ''
  on conflict (name) do nothing;

alter table public.stock_categories enable row level security;
drop policy if exists stock_categories_select on public.stock_categories;
create policy stock_categories_select on public.stock_categories for select to authenticated using (true);
drop policy if exists stock_categories_insert on public.stock_categories;
create policy stock_categories_insert on public.stock_categories for insert to authenticated
  with check ((select public.my_role())::text in ('admin', 'stock'));
drop policy if exists stock_categories_delete on public.stock_categories;
create policy stock_categories_delete on public.stock_categories for delete to authenticated
  using ((select public.my_role())::text = 'admin');
grant select, insert, delete on public.stock_categories to authenticated;

-- A new category typed on a stock item is added to the list automatically.
create or replace function public.stock_item_category() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(trim(new.category), '') <> '' then
    new.category := trim(new.category);
    insert into public.stock_categories(name) values (new.category) on conflict (name) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.stock_item_category() from public, anon, authenticated;
drop trigger if exists trg_stock_item_category on public.stock_items;
create trigger trg_stock_item_category before insert or update of category on public.stock_items
  for each row execute function public.stock_item_category();

create or replace function public.rename_stock_category(p_old text, p_new text) returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can rename a category'; end if;
  p_new := trim(coalesce(p_new, ''));
  if p_new = '' then raise exception 'Type the new name'; end if;
  if p_new <> p_old and exists (select 1 from public.stock_categories where lower(name) = lower(p_new) and name <> p_old) then
    -- Renaming onto an existing category merges the two.
    delete from public.stock_categories where name = p_old;
  else
    update public.stock_categories set name = p_new where name = p_old;
    if not found then insert into public.stock_categories(name) values (p_new) on conflict (name) do nothing; end if;
  end if;
  update public.stock_items set category = (select name from public.stock_categories where lower(name) = lower(p_new) limit 1)
   where category = p_old;
  get diagnostics v_n = row_count;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('stock_categories', p_old, 'renamed', jsonb_build_object('from', p_old, 'to', p_new, 'items', v_n));
  return v_n;
end $$;

create or replace function public.delete_stock_category(p_name text, p_move_to text) returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can delete a category'; end if;
  select count(*) into v_n from public.stock_items where category = p_name;
  if v_n > 0 then
    if coalesce(trim(p_move_to), '') = '' or p_move_to = p_name then
      raise exception '% stock items are in this category. Choose where to move them.', v_n;
    end if;
    insert into public.stock_categories(name) values (trim(p_move_to)) on conflict (name) do nothing;
    update public.stock_items set category = trim(p_move_to) where category = p_name;
  end if;
  delete from public.stock_categories where name = p_name;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('stock_categories', p_name, 'deleted', jsonb_build_object('moved_to', p_move_to, 'items', v_n));
  return v_n;
end $$;
revoke all on function public.rename_stock_category(text, text) from public, anon;
revoke all on function public.delete_stock_category(text, text) from public, anon;
grant execute on function public.rename_stock_category(text, text) to authenticated;
grant execute on function public.delete_stock_category(text, text) to authenticated;


-- ===== MIGRATION: 036_supplier_payment_rules.sql =====
-- Supplier payments go through one server function with rules:
-- * the same payment sent twice (retry, double tap) is saved once (the app sends its own id)
-- * a delivery must belong to that supplier and be posted, and cannot be paid beyond what is left on it
-- * the total cannot go beyond what is owed to the supplier unless "paying in advance" is ticked
-- * the date cannot be in the future
-- Direct inserts from the app are no longer allowed.

create or replace function public.record_supplier_payment(
  p_id uuid, p_supplier uuid, p_grv uuid, p_amount numeric, p_method text,
  p_paid_on date, p_note text, p_advance boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_owing numeric; v_left numeric; v_grv record; v_name text;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only the admin can record supplier payments'; end if;
  if p_id is null then raise exception 'Missing payment id'; end if;
  if exists (select 1 from public.supplier_payments where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicate', true);
  end if;
  perform 1 from public.suppliers where id = p_supplier for update;   -- one payment per supplier at a time
  select name into v_name from public.suppliers where id = p_supplier;
  if v_name is null then raise exception 'Supplier not found'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 then raise exception 'Enter an amount above zero'; end if;
  if p_method not in ('eft', 'cash', 'card', 'credit_note') then raise exception 'Choose how it was paid'; end if;
  if coalesce(p_paid_on, current_date) > (now() at time zone public.app_tz())::date then
    raise exception 'The payment date cannot be in the future';
  end if;

  if p_grv is not null then
    select id, grv_no, supplier_id, status::text status, total into v_grv from public.grvs where id = p_grv;
    if v_grv.id is null then raise exception 'Delivery not found'; end if;
    if v_grv.supplier_id is distinct from p_supplier then raise exception 'Delivery % is not from %', v_grv.grv_no, v_name; end if;
    if v_grv.status <> 'posted' then raise exception 'Delivery % is not posted, so it cannot be paid', v_grv.grv_no; end if;
    v_left := v_grv.total - coalesce((select sum(amount) from public.supplier_payments where grv_id = p_grv), 0);
    if p_amount > v_left + 0.005 then
      raise exception 'Only R% is left to pay on delivery %', to_char(greatest(v_left, 0), 'FM999999990.00'), v_grv.grv_no;
    end if;
  end if;

  v_owing := coalesce((select sum(total) from public.grvs where supplier_id = p_supplier and status = 'posted'), 0)
           - coalesce((select sum(amount) from public.supplier_payments where supplier_id = p_supplier), 0);
  if p_amount > v_owing + 0.005 and not coalesce(p_advance, false) then
    raise exception 'That is more than the R% owed to %. Tick "Paying in advance" if this is on purpose.',
      to_char(greatest(v_owing, 0), 'FM999999990.00'), v_name;
  end if;

  insert into public.supplier_payments(id, supplier_id, grv_id, amount, method, paid_on, note, created_by)
    values (p_id, p_supplier, p_grv, p_amount, p_method, coalesce(p_paid_on, current_date),
            nullif(trim(coalesce(p_note, '')), ''), auth.uid());
  return jsonb_build_object('id', p_id, 'duplicate', false, 'owing_after', round(v_owing - p_amount, 2));
end $$;
revoke all on function public.record_supplier_payment(uuid, uuid, uuid, numeric, text, date, text, boolean) from public, anon;
grant execute on function public.record_supplier_payment(uuid, uuid, uuid, numeric, text, date, text, boolean) to authenticated;

drop policy if exists supplier_payments_insert on public.supplier_payments;

-- "Deliveries not fully paid": payments not linked to a delivery now pay off the oldest deliveries first,
-- so the list adds up to what is owed.
create or replace function public.supplier_accounts() returns jsonb
language plpgsql stable security definer set search_path = '' as $function$
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
    'deliveries', (
      with g as (
        select g.id, g.grv_no, g.supplier_id, g.received_on, g.delivery_note, g.total,
               coalesce((select sum(amount) from public.supplier_payments p where p.grv_id = g.id), 0) linked,
               g.created_at
        from public.grvs g where g.status = 'posted'),
      r as (
        select g.*, greatest(g.total - g.linked, 0) rem,
               coalesce(sum(greatest(g.total - g.linked, 0)) over (partition by g.supplier_id order by g.received_on, g.created_at
                 rows between unbounded preceding and 1 preceding), 0) before_rem,
               coalesce((select sum(amount) from public.supplier_payments p where p.supplier_id = g.supplier_id and p.grv_id is null), 0) free
        from g),
      a as (
        select r.*, least(r.rem, greatest(r.free - r.before_rem, 0)) applied from r)
      select coalesce(jsonb_agg(jsonb_build_object('id', id, 'grv_no', grv_no, 'supplier_id', supplier_id,
          'received_on', received_on, 'delivery_note', delivery_note, 'total', total,
          'paid', round(linked + applied, 2)) order by received_on), '[]'::jsonb)
      from a where rem - applied > 0.005),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'supplier_id', p.supplier_id, 'amount', p.amount, 'method', p.method,
        'paid_on', p.paid_on, 'note', p.note, 'grv_no', g.grv_no) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from (select * from public.supplier_payments order by created_at desc limit 100) p left join public.grvs g on g.id = p.grv_id));
end $function$;


-- ===== DISABLE RLS =====
-- Disable RLS on all tables for local single-store use.
-- This makes direct SQL queries work without needing to set session roles.
DO $$ DECLARE t text; BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Also grant the postgres superuser all the needed roles
GRANT anon TO postgres;
GRANT authenticated TO postgres;
GRANT service_role TO postgres;


-- ===== CREATE FIRST ADMIN =====
-- Creates the first admin user in the local database.
-- Usage: psql ... -v admin_name='John' -v admin_user='admin' -v admin_pass='1234' -f local_create_admin.sql
-- Or set the variables inline before running.

DO $$
DECLARE
  v_name text := coalesce(nullif(current_setting('vars.admin_name', true), ''), 'Admin');
  v_user text := coalesce(nullif(current_setting('vars.admin_user', true), ''), 'admin');
  v_pass text := coalesce(nullif(current_setting('vars.admin_pass', true), ''), '1234');
  v_uid uuid;
  v_email text;
BEGIN
  v_email := lower(v_user) || '@store.local';

  -- Check if user already exists
  SELECT id INTO v_uid FROM auth.users WHERE email = v_email;
  IF v_uid IS NOT NULL THEN
    RAISE NOTICE 'User "%" already exists with id %', v_user, v_uid;
    RETURN;
  END IF;

  -- Create the auth user
  INSERT INTO auth.users (email, encrypted_password, raw_user_meta_data)
  VALUES (v_email, crypt(v_pass, gen_salt('bf')), jsonb_build_object('full_name', v_name))
  RETURNING id INTO v_uid;

  -- The handle_new_user trigger will create the staff_profiles row.
  -- Since this is the first user, the trigger makes them admin.

  RAISE NOTICE 'Created admin user "%" (%) with id %', v_name, v_user, v_uid;
END $$;
