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
