-- 021: till disbursements (money taken out of the till, with category and reference), daily summary, disbursement report.
alter table public.cash_movements add column if not exists category text, add column if not exists reference text;
alter table public.company_settings
  add column if not exists disbursement_limit numeric(12,2) not null default 0 check (disbursement_limit >= 0),
  add column if not exists chart_style text not null default 'auto' check (chart_style in ('auto','bars','line','pie','ranked'));

create or replace function public.till_payout(p_amount numeric, p_category text, p_reference text, p_note text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_amt numeric := round(coalesce(p_amount, 0), 2);
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_day date := (now() at time zone public.app_tz())::date;
        v_lim numeric; v_kind text; m public.cash_movements;
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'You cannot take money from the till'; end if;
  select * into m from public.cash_movements where id = v_id;
  if found then return to_jsonb(m); end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  if length(trim(coalesce(p_category, ''))) = 0 then raise exception 'Choose what the money is for'; end if;
  if length(trim(coalesce(p_reference, ''))) = 0 then raise exception 'Enter a reference, such as a slip, invoice or receipt number'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what the money was used for'; end if;
  select disbursement_limit into v_lim from public.company_settings where id = 1;
  if v_role = 'cashier' and coalesce(v_lim, 0) > 0 and v_amt > v_lim then
    raise exception 'A cashier can take at most R% at a time. Ask a supervisor for more.', v_lim;
  end if;
  v_kind := case trim(p_category) when 'Cash drop to safe' then 'drop' when 'Tips paid out' then 'tip_payout' else 'payout' end;
  insert into public.cash_movements(id, business_date, kind, amount, note, staff_id, created_by, category, reference)
  values (v_id, v_day, v_kind, v_amt, trim(p_note), auth.uid(), auth.uid(), trim(p_category), trim(p_reference))
  returning * into m;
  return to_jsonb(m);
end $$;
revoke execute on function public.till_payout(numeric, text, text, text, uuid) from public, anon;
grant execute on function public.till_payout(numeric, text, text, text, uuid) to authenticated;

-- What a till user may see: their own pay-outs for the day, nothing about sales.
create or replace function public.my_payouts(p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_day date := coalesce(p_date, (now() at time zone public.app_tz())::date);
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'Not allowed'; end if;
  return jsonb_build_object('date', v_day,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.created_at, 'kind', m.kind, 'category', m.category,
          'reference', m.reference, 'note', m.note, 'amount', m.amount, 'by', coalesce(s.full_name, '')) order by m.created_at desc), '[]'::jsonb)
        from public.cash_movements m left join public.staff_profiles s on s.id = m.created_by
        where m.business_date = v_day and m.kind <> 'float_in' and (v_role <> 'cashier' or m.staff_id = auth.uid())),
    'total', (select coalesce(sum(amount), 0) from public.cash_movements m
        where m.business_date = v_day and m.kind <> 'float_in' and (v_role <> 'cashier' or m.staff_id = auth.uid())),
    'limit', (select disbursement_limit from public.company_settings where id = 1),
    'closed', exists (select 1 from public.day_closes where business_date = v_day));
end $$;
revoke execute on function public.my_payouts(date) from public, anon;
grant execute on function public.my_payouts(date) to authenticated;

create or replace function public.daily_summary(p_date date)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz(); v_from timestamptz := p_date::timestamp at time zone tz; v_to timestamptz := (p_date + 1)::timestamp at time zone tz;
        rep jsonb; cu jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'The daily summary is for supervisor and admin only';
  end if;
  rep := public.admin_report(v_from, v_to);
  cu := public.cash_up_summary(p_date);
  return jsonb_build_object(
    'date', p_date,
    'summary', rep->'summary', 'payments', rep->'payments', 'unpaid', rep->'unpaid', 'voided', rep->'voided',
    'by_staff', rep->'by_staff', 'vat', public.vat_report(v_from, v_to),
    'cash', cu - 'by_staff' - 'done',
    'cash_ups', (select coalesce(jsonb_agg(jsonb_build_object('staff', coalesce(s.full_name, 'Whole day'), 'float', c.opening_float,
        'expected', c.expected_cash, 'counted', c.counted_cash, 'variance', c.variance, 'notes', c.notes) order by c.created_at), '[]'::jsonb)
        from public.cash_ups c left join public.staff_profiles s on s.id = c.staff_id where c.business_date = p_date),
    'account_owed', coalesce((select sum(balance) from public.customer_accounts where balance > 0), 0),
    'closed', cu->'closed');
end $$;
revoke execute on function public.daily_summary(date) from public, anon;
grant execute on function public.daily_summary(date) to authenticated;

create or replace function public.disbursement_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz();
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'This report is for supervisor and admin only';
  end if;
  if p_to < p_from then raise exception 'The end date is before the start date'; end if;
  if p_to - p_from > 400 then raise exception 'Choose a period of 400 days or less'; end if;
  return (
    with mv as (
      select m.*, coalesce(m.category, case m.kind when 'drop' then 'Cash drop to safe' when 'tip_payout' then 'Tips paid out' else 'Other' end) cat
      from public.cash_movements m where m.business_date between p_from and p_to and m.kind <> 'float_in'
    ), days as (select d::date d from generate_series(p_from, p_to, interval '1 day') d)
    select jsonb_build_object(
      'total', coalesce((select sum(amount) from mv), 0),
      'count', (select count(*) from mv),
      'float_in', coalesce((select sum(amount) from public.cash_movements where business_date between p_from and p_to and kind = 'float_in'), 0),
      'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'total', t, 'count', c) order by t desc), '[]'::jsonb)
          from (select cat, sum(amount) t, count(*) c from mv group by cat) q),
      'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d.d, 'total', coalesce(x.t, 0), 'count', coalesce(x.c, 0)) order by d.d), '[]'::jsonb)
          from days d left join (select business_date, sum(amount) t, count(*) c from mv group by business_date) x on x.business_date = d.d),
      'by_staff', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'total', t, 'count', c) order by t desc), '[]'::jsonb)
          from (select coalesce(s.full_name, 'Unknown') nm, sum(mv.amount) t, count(*) c
                from mv left join public.staff_profiles s on s.id = mv.staff_id group by 1) q),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('day', mv.business_date, 'at', mv.created_at, 'category', mv.cat, 'reference', mv.reference,
            'note', mv.note, 'amount', mv.amount, 'by', coalesce(s.full_name, '')) order by mv.created_at desc), '[]'::jsonb)
          from mv left join public.staff_profiles s on s.id = mv.staff_id),
      'cash_flow', (select coalesce(jsonb_agg(jsonb_build_object('day', d.d,
            'sales', coalesce((select sum(p.amount + p.tip) from public.payments p where p.method = 'cash' and (p.created_at at time zone tz)::date = d.d), 0),
            'accounts', coalesce((select -sum(t.amount) from public.account_transactions t where t.kind = 'payment' and t.method = 'cash' and t.business_date = d.d), 0),
            'float_in', coalesce((select sum(m.amount) from public.cash_movements m where m.kind = 'float_in' and m.business_date = d.d), 0),
            'refunds', coalesce((select sum(r.amount) from public.refunds r where r.method = 'cash' and (r.created_at at time zone tz)::date = d.d), 0),
            'credit_back', coalesce((select sum(t.amount) from public.account_transactions t where t.kind = 'credit_refund' and t.method = 'cash' and t.business_date = d.d), 0),
            'payouts', coalesce((select sum(m.amount) from public.cash_movements m where m.kind <> 'float_in' and m.business_date = d.d), 0)
          ) order by d.d), '[]'::jsonb) from days d)
    )
  );
end $$;
revoke execute on function public.disbursement_report(date, date) from public, anon;
grant execute on function public.disbursement_report(date, date) to authenticated;

create or replace function public.cash_up_summary(p_date date, p_staff uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := public.app_tz(); r jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  with p as (
    select * from public.payments
    where (created_at at time zone tz)::date = p_date and (p_staff is null or created_by = p_staff)
  ), rf as (
    select * from public.refunds
    where (created_at at time zone tz)::date = p_date and (p_staff is null or created_by = p_staff)
  ), mv as (
    select * from public.cash_movements where business_date = p_date and (p_staff is null or staff_id = p_staff)
  ), ab as (
    select * from public.account_transactions
    where kind = 'credit_refund' and business_date = p_date and (p_staff is null or created_by = p_staff)
  ), ar as (
    select * from public.account_transactions
    where kind = 'payment' and business_date = p_date and (p_staff is null or created_by = p_staff)
  )
  select jsonb_build_object(
    'cash_sales', coalesce((select sum(amount) from p where method = 'cash'), 0),
    'cash_tips', coalesce((select sum(tip) from p where method = 'cash'), 0),
    'cash_count', (select count(*) from p where method = 'cash'),
    'card_sales', coalesce((select sum(amount) from p where method = 'card_manual'), 0),
    'card_tips', coalesce((select sum(tip) from p where method = 'card_manual'), 0),
    'card_slips', (select count(*) from p where method = 'card_manual'),
    'account_sales', coalesce((select sum(amount) from p where method::text = 'account'), 0),
    'acct_cash', coalesce((select -sum(amount) from ar where method = 'cash'), 0),
    'acct_cash_back', coalesce((select sum(amount) from ab where method = 'cash'), 0),
    'acct_card', coalesce((select -sum(amount) from ar where method = 'card'), 0),
    'acct_eft', coalesce((select -sum(amount) from ar where method = 'eft'), 0),
    'cash_refunds', coalesce((select sum(amount) from rf where method = 'cash'), 0),
    'card_refunds', coalesce((select sum(amount) from rf where method = 'card_manual'), 0),
    'cash_out', coalesce((select sum(amount) from mv where kind <> 'float_in'), 0),
    'cash_in', coalesce((select sum(amount) from mv where kind = 'float_in'), 0),
    'movements', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'amount', m.amount, 'note', m.note,
          'at', m.created_at, 'by', coalesce(s.full_name, ''), 'reference', m.reference, 'category', m.category) order by m.created_at), '[]'::jsonb)
        from mv m left join public.staff_profiles s on s.id = m.created_by),
    'out_by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'total', total) order by total desc), '[]'::jsonb)
        from (select coalesce(category, case kind when 'drop' then 'Cash drop to safe' when 'tip_payout' then 'Tips paid out' else 'Other' end) category,
                     sum(amount) total from mv where kind <> 'float_in' group by 1) q),
    'closed', exists (select 1 from public.day_closes where business_date = p_date),
    'by_staff', (select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
        select jsonb_build_object('staff_id', p.created_by, 'name', coalesce(s.full_name, 'Unknown'),
          'cash', coalesce(sum(p.amount) filter (where p.method = 'cash'), 0),
          'card', coalesce(sum(p.amount) filter (where p.method = 'card_manual'), 0),
          'tips', coalesce(sum(p.tip), 0), 'payments', count(*)) x
        from p left join public.staff_profiles s on s.id = p.created_by
        group by p.created_by, s.full_name) y),
    'done', (select to_jsonb(c) from (select business_date, staff_id, opening_float, expected_cash, counted_cash, variance, notes, created_at
              from public.cash_ups where business_date = p_date and staff_id is not distinct from p_staff
              order by created_at desc limit 1) c)
  ) into r;
  return r;
end $$;
