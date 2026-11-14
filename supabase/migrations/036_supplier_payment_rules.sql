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
