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
