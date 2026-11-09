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
