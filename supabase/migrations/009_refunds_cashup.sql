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
