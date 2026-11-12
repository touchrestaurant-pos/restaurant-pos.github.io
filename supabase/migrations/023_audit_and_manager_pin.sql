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
