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
