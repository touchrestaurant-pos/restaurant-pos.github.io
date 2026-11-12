-- Per-user permission settings (set by the admin on the Staff screen). A missing key means "use the default".
alter table public.staff_profiles add column if not exists perms jsonb not null default '{}'::jsonb;

create or replace function public.my_perm(k text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select perms -> k from public.staff_profiles where id = auth.uid()
$$;
revoke execute on function public.my_perm(text) from public, anon;
grant execute on function public.my_perm(text) to authenticated;

-- Till pay-outs: a cashier can be switched off, and can have their own limit (blank = the company limit, 0 = no limit).
create or replace function public.till_payout(p_amount numeric, p_category text, p_reference text, p_note text, p_id uuid DEFAULT NULL::uuid)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_role text := coalesce((select public.my_role())::text, ''); v_amt numeric := round(coalesce(p_amount, 0), 2);
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_day date := (now() at time zone public.app_tz())::date;
        v_lim numeric; v_kind text; m public.cash_movements; v_pl jsonb;
begin
  if v_role not in ('cashier','supervisor','admin') then raise exception 'You cannot take money from the till'; end if;
  if v_role = 'cashier' and public.my_perm('can_payout') = 'false'::jsonb then raise exception 'You are not allowed to take money from the till. Ask the admin.'; end if;
  select * into m from public.cash_movements where id = v_id;
  if found then return to_jsonb(m); end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  if length(trim(coalesce(p_category, ''))) = 0 then raise exception 'Choose what the money is for'; end if;
  if length(trim(coalesce(p_reference, ''))) = 0 then raise exception 'Enter a reference, such as a slip, invoice or receipt number'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what the money was used for'; end if;
  select disbursement_limit into v_lim from public.company_settings where id = 1;
  v_pl := public.my_perm('payout_limit');
  if v_pl is not null and jsonb_typeof(v_pl) = 'number' then v_lim := (v_pl #>> '{}')::numeric; end if;
  if v_role = 'cashier' and coalesce(v_lim, 0) > 0 and v_amt > v_lim then
    raise exception 'You can take at most R% at a time. Ask a supervisor for more.', v_lim;
  end if;
  v_kind := case trim(p_category) when 'Cash drop to safe' then 'drop' when 'Tips paid out' then 'tip_payout' else 'payout' end;
  insert into public.cash_movements(id, business_date, kind, amount, note, staff_id, created_by, category, reference)
  values (v_id, v_day, v_kind, v_amt, trim(p_note), auth.uid(), auth.uid(), trim(p_category), trim(p_reference))
  returning * into m;
  return to_jsonb(m);
end $function$;

-- Account sales: a cashier can be switched off from selling on account.
create or replace function public.account_charge() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a public.customer_accounts; cs public.company_settings;
  v_role text := coalesce((select public.my_role())::text, '');
  v_total numeric; v_paid numeric; v_ref text; v_od numeric;
begin
  if new.method::text <> 'account' then return new; end if;
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed to sell on account'; end if;
  if v_role = 'cashier' and public.my_perm('can_account_sale') = 'false'::jsonb then
    raise exception 'You are not allowed to sell on account. Ask the admin.';
  end if;
  select * into a from public.customer_accounts where id = new.account_id for update;
  if not found then raise exception 'Account not found'; end if;
  if a.status <> 'active' then
    raise exception 'Account % (%) is %. No new sales can be put on it.', a.account_no, a.name, a.status;
  end if;
  if v_role = 'cashier' and not a.cashier_visible then
    raise exception 'Account % is not available at the till.', a.account_no;
  end if;
  if a.consent_at is null then raise exception 'Account % has not been activated (no consent recorded).', a.account_no; end if;
  if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an account.'; end if;
  if a.credit_limit <= 0 then raise exception 'Account % has no credit limit.', a.account_no; end if;
  if a.balance + new.amount > a.credit_limit + 0.001 then
    raise exception 'Over the credit limit on account %. Available: R%.', a.account_no,
      to_char(greatest(a.credit_limit - a.balance, 0), 'FM999999990.00');
  end if;
  if a.max_sale is not null and new.amount > a.max_sale + 0.001 then
    raise exception 'The most allowed on account % in one sale is R%.', a.account_no, to_char(a.max_sale, 'FM999999990.00');
  end if;
  select * into cs from public.company_settings where id = 1;
  if cs.account_block_overdue then
    v_od := public.account_overdue(a.id);
    if v_od > 0 then
      raise exception 'Account % has R% overdue. Payment is needed before more credit.', a.account_no, to_char(v_od, 'FM999999990.00');
    end if;
  end if;
  select total, order_ref into v_total, v_ref from public.orders where id = new.order_id;
  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = new.order_id and id <> new.id;
  if new.amount > v_total - v_paid + 0.005 then
    raise exception 'The account amount is more than what is still owed on the order.';
  end if;
  insert into public.account_transactions(account_id, kind, amount, order_id, payment_id, reference, business_date, created_by)
  values (a.id, 'sale', round(new.amount, 2), new.order_id, new.id, v_ref,
          (now() at time zone public.app_tz())::date, coalesce(new.created_by, auth.uid()));
  return new;
end $$;

-- Every kitchen reprint is recorded: who, which order, when.
create or replace function public.log_reprint(p_order uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_ref text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select order_ref into v_ref from public.orders where id = p_order;
  insert into public.audit_log(table_name, row_id, action, changes)
  values ('orders', p_order::text, 'kitchen_reprint', jsonb_build_object('order_ref', v_ref));
end $$;
revoke execute on function public.log_reprint(uuid) from public, anon;
grant execute on function public.log_reprint(uuid) to authenticated;
