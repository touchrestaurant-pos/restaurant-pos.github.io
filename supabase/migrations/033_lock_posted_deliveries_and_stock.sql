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
