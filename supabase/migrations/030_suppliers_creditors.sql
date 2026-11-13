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
