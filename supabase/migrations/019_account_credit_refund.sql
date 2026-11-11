-- 019: give a customer's credit back (cash, card or EFT). Admin only, recorded in the ledger.
alter table public.account_transactions drop constraint account_transactions_kind_check;
alter table public.account_transactions add constraint account_transactions_kind_check
  check (kind in ('sale','payment','credit_note','writeoff','writeoff_reversal','credit_refund'));
alter table public.account_transactions drop constraint ledger_sign;
alter table public.account_transactions add constraint ledger_sign check (
  (kind in ('sale','writeoff_reversal','credit_refund') and amount > 0) or
  (kind in ('payment','credit_note','writeoff') and amount < 0));

-- Ageing: a credit refund is not a new charge; it takes back credit that was applied.
create or replace function public.account_open_items(p_account uuid)
returns table(txn_id uuid, txn_date date, kind text, charged numeric, outstanding numeric)
language sql stable security definer set search_path = '' as $$
  with ch as (
    select id, business_date, kind, amount,
           sum(amount) over (order by business_date, created_at, id) cum
    from public.account_transactions where account_id = p_account and kind in ('sale','writeoff_reversal')
  ), cr as (
    select coalesce(-sum(amount) filter (where amount < 0), 0) - coalesce(sum(amount) filter (where kind = 'credit_refund'), 0) total
    from public.account_transactions where account_id = p_account
  )
  select ch.id, ch.business_date, ch.kind, ch.amount,
         round(least(ch.amount, greatest(0, ch.cum - cr.total)), 2)
  from ch cross join cr
$$;

create or replace function public.refund_account_credit(
  p_account uuid, p_amount numeric, p_method text, p_reference text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_day date := (now() at time zone public.app_tz())::date;
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_no bigint; t public.account_transactions;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can pay out an account credit'; end if;
  if p_method not in ('cash','card','eft') then raise exception 'Choose cash, card or EFT'; end if;
  select * into t from public.account_transactions where id = v_id;
  if found then
    select * into a from public.customer_accounts where id = t.account_id;
    return jsonb_build_object('receipt_no', t.receipt_no, 'balance', a.balance, 'account_no', a.account_no,
        'name', a.name, 'amount', t.amount, 'method', t.method, 'date', t.business_date, 'repeat', true);
  end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if a.balance >= -0.005 then raise exception 'This account has no credit to pay out'; end if;
  if v_amt > -a.balance + 0.001 then raise exception 'The customer is only owed R%.', -a.balance; end if;
  if exists (select 1 from public.day_closes where business_date = v_day) then
    raise exception 'Today (%) is closed. An admin can reopen it.', v_day;
  end if;
  v_no := nextval('public.account_receipt_seq');
  insert into public.account_transactions(id, account_id, kind, amount, method, reference, note, receipt_no, business_date)
  values (v_id, a.id, 'credit_refund', v_amt, p_method, nullif(trim(coalesce(p_reference, '')), ''), 'Credit paid back to customer', v_no, v_day);
  select * into a from public.customer_accounts where id = a.id;
  return jsonb_build_object('receipt_no', v_no, 'balance', a.balance, 'account_no', a.account_no,
      'name', a.name, 'amount', v_amt, 'method', p_method, 'date', v_day, 'repeat', false);
end $$;
revoke execute on function public.refund_account_credit(uuid, numeric, text, text, uuid) from public, anon;
grant execute on function public.refund_account_credit(uuid, numeric, text, text, uuid) to authenticated;

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
          'at', m.created_at, 'by', coalesce(s.full_name, '')) order by m.created_at), '[]'::jsonb)
        from mv m left join public.staff_profiles s on s.id = m.created_by),
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

create or replace function public.save_cash_up(p_date date, p_float numeric, p_counted numeric, p_notes text, p_staff uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_exp numeric; v_in numeric;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Cash-up is for supervisor and admin only';
  end if;
  s := public.cash_up_summary(p_date, p_staff);
  -- cash received from account customers goes into the drawer like any other cash in
  v_in := (s->>'cash_in')::numeric + (s->>'acct_cash')::numeric;
  v_exp := round(p_float + (s->>'cash_sales')::numeric + (s->>'cash_tips')::numeric - (s->>'cash_refunds')::numeric
           - (s->>'cash_out')::numeric - (s->>'acct_cash_back')::numeric + v_in, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, cash_out, cash_in, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, (s->>'cash_out')::numeric + (s->>'acct_cash_back')::numeric, v_in,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;
