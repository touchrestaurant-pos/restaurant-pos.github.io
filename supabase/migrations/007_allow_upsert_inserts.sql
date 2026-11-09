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
