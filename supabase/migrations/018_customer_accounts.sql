-- Customer accounts (sales on account) with a full ledger.
--
-- Rules built in:
--  * No interest and no fees are ever added. Only sales, payments, credit notes
--    and documented write-offs touch an account. (Under the National Credit Act a
--    deferred payment only becomes a credit agreement when interest or fees are
--    charged, so this keeps accounts outside it.)
--  * The ledger is append-only. Nothing is edited or deleted; mistakes are
--    corrected with a new entry. Records are kept (tax records: 5 years).
--  * Only an admin creates accounts, sets limits and changes status. The server
--    checks status, limit, per-sale cap, overdue amounts and whether the cashier
--    may use the account, on every sale, whatever the app shows.
--  * Customer details are kept only with a recorded consent (POPIA).

create sequence if not exists public.account_no_seq;
create sequence if not exists public.account_receipt_seq;

alter table public.company_settings
  add column if not exists accounts_enabled boolean not null default false,
  add column if not exists account_grace_days integer not null default 7 check (account_grace_days between 0 and 60),
  add column if not exists account_block_overdue boolean not null default true;

create table public.customer_accounts (
  id uuid primary key default gen_random_uuid(),
  account_no text not null unique,
  name text not null check (length(trim(name)) > 0),
  contact_name text,
  phone text,
  email text,
  billing_address text,
  vat_no text,
  credit_limit numeric(12,2) not null default 0 check (credit_limit >= 0),
  max_sale numeric(12,2) check (max_sale is null or max_sale > 0),
  terms_days integer not null default 30 check (terms_days between 0 and 120),
  status text not null default 'active' check (status in ('active','blocked','stopped')),
  status_reason text,
  cashier_visible boolean not null default false,
  consent_at timestamptz,
  consent_note text,
  balance numeric(12,2) not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_touch before update on public.customer_accounts
  for each row execute function public.touch_updated_at();

create table public.account_transactions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.customer_accounts(id),
  kind text not null check (kind in ('sale','payment','credit_note','writeoff','writeoff_reversal')),
  amount numeric(12,2) not null,
  order_id uuid references public.orders(id),
  payment_id uuid unique,
  refund_id uuid unique,
  method text check (method is null or method in ('cash','card','eft')),
  reference text,
  note text,
  receipt_no bigint unique,
  business_date date not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint ledger_sign check (
    (kind in ('sale','writeoff_reversal') and amount > 0) or
    (kind in ('payment','credit_note','writeoff') and amount < 0))
);
create index account_transactions_account_idx on public.account_transactions(account_id, business_date, created_at);

alter table public.customer_accounts enable row level security;
alter table public.account_transactions enable row level security;
-- Reads for admin and supervisor only. There are no write policies at all:
-- every change goes through the functions below.
create policy accounts_select on public.customer_accounts for select to authenticated
  using ((select public.my_role())::text in ('admin','supervisor'));
create policy ledger_select on public.account_transactions for select to authenticated
  using ((select public.my_role())::text in ('admin','supervisor'));

create or replace function public.ledger_immutable() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and current_setting('pos.clearing', true) = 'on' then return old; end if;
  raise exception 'Account entries cannot be changed or deleted. Post a correcting entry instead.';
end $$;
create trigger trg_ledger_immutable before update or delete on public.account_transactions
  for each row execute function public.ledger_immutable();

create or replace function public.ledger_apply() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.customer_accounts set balance = balance + new.amount where id = new.account_id;
  return new;
end $$;
create trigger trg_ledger_apply after insert on public.account_transactions
  for each row execute function public.ledger_apply();

-- Audit trail for account details (balance changes are in the ledger itself).
create or replace function public.audit_account() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value)) into v
    from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
    where n.value is distinct from o.value and n.key not in ('updated_at','balance');
    if v is null then return new; end if;
  else
    v := to_jsonb(new);
  end if;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('customer_accounts', new.id::text, lower(tg_op), v);
  return new;
end $$;
create trigger trg_audit after insert or update on public.customer_accounts
  for each row execute function public.audit_account();

-- ---- paying an order on account -------------------------------------------------

alter table public.payments
  add column if not exists account_id uuid references public.customer_accounts(id),
  add column if not exists account_no text,
  add column if not exists account_name text,
  add column if not exists account_vat_no text,
  add column if not exists account_address text;
alter table public.payments add constraint payments_account_chk
  check ((method::text = 'account') = (account_id is not null));

-- Copies the customer's name and number onto the payment, so the tax invoice can
-- show who was charged (name, address and VAT number of the customer).
create or replace function public.account_snapshot() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts;
begin
  if new.method::text = 'account' then
    select * into a from public.customer_accounts where id = new.account_id;
    if found then
      new.account_no := a.account_no;
      new.account_name := a.name;
      new.account_vat_no := a.vat_no;
      new.account_address := a.billing_address;
    end if;
  else
    new.account_no := null; new.account_name := null; new.account_vat_no := null; new.account_address := null;
  end if;
  return new;
end $$;
create trigger trg_account_snapshot before insert on public.payments
  for each row execute function public.account_snapshot();

-- Runs after the payment row is accepted (so a safe retry of the same payment
-- does nothing twice) and refuses the sale if any rule is broken.
create or replace function public.account_charge() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a public.customer_accounts; cs public.company_settings;
  v_role text := coalesce((select public.my_role())::text, '');
  v_total numeric; v_paid numeric; v_ref text; v_od numeric;
begin
  if new.method::text <> 'account' then return new; end if;
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed to sell on account'; end if;
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
create trigger trg_account_charge after insert on public.payments
  for each row execute function public.account_charge();

-- A cancelled order puts its account amount back (a credit note on the account).
create or replace function public.account_on_void() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v_net numeric;
begin
  for r in select account_id, sum(amount) amt from public.payments
           where order_id = new.id and method::text = 'account' group by account_id loop
    select r.amt + coalesce(sum(amount), 0) into v_net from public.account_transactions
      where order_id = new.id and account_id = r.account_id and kind = 'credit_note';
    if v_net > 0 then
      insert into public.account_transactions(account_id, kind, amount, order_id, note, business_date)
      values (r.account_id, 'credit_note', -round(v_net, 2), new.id, 'Order cancelled',
              (now() at time zone public.app_tz())::date);
    end if;
  end loop;
  return new;
end $$;
create trigger trg_account_void after update on public.orders
  for each row when (new.status = 'void' and old.status <> 'void')
  execute function public.account_on_void();

-- ---- ageing helpers (oldest invoices are treated as paid first) --------------------

create or replace function public.account_open_items(p_account uuid)
returns table(txn_id uuid, txn_date date, kind text, charged numeric, outstanding numeric)
language sql stable security definer set search_path = '' as $$
  with ch as (
    select id, business_date, kind, amount,
           sum(amount) over (order by business_date, created_at, id) cum
    from public.account_transactions where account_id = p_account and amount > 0
  ), cr as (
    select coalesce(-sum(amount), 0) total from public.account_transactions where account_id = p_account and amount < 0
  )
  select ch.id, ch.business_date, ch.kind, ch.amount,
         round(least(ch.amount, greatest(0, ch.cum - cr.total)), 2)
  from ch cross join cr
$$;

create or replace function public.account_overdue(p_account uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(oi.outstanding), 0)
  from public.account_open_items(p_account) oi
  join public.customer_accounts a on a.id = p_account
  cross join (select account_grace_days g from public.company_settings where id = 1) cs
  where oi.outstanding > 0
    and (now() at time zone public.app_tz())::date - oi.txn_date > a.terms_days + cs.g
$$;

-- ---- functions the app calls ----------------------------------------------------------

-- Admin only: create or change an account's details. Status changes have their own function.
create or replace function public.save_account(p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid; v_name text := trim(coalesce(p->>'name', ''));
  v_limit numeric := coalesce(nullif(p->>'credit_limit', '')::numeric, 0);
  v_max numeric := nullif(p->>'max_sale', '')::numeric;
  v_terms int := coalesce(nullif(p->>'terms_days', '')::int, 30);
  v_vat text := nullif(trim(coalesce(p->>'vat_no', '')), '');
  v_email text := nullif(trim(coalesce(p->>'email', '')), '');
  v_phone text := nullif(trim(coalesce(p->>'phone', '')), '');
  v_vis boolean := coalesce((p->>'cashier_visible')::boolean, false);
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can manage accounts'; end if;
  if v_name = '' then raise exception 'The account needs a name'; end if;
  if v_limit < 0 or v_limit > 10000000 then raise exception 'Credit limit must be between R0 and R10 000 000'; end if;
  if v_max is not null and (v_max <= 0 or v_max > v_limit) then raise exception 'The most per sale must be more than R0 and not more than the credit limit'; end if;
  if v_terms < 0 or v_terms > 120 then raise exception 'Payment terms must be 0 to 120 days'; end if;
  if v_vat is not null and v_vat !~ '^[0-9]{10}$' then raise exception 'A VAT number has 10 digits'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right'; end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'That phone number is too short'; end if;
  if v_id is null then
    if coalesce((p->>'consent')::boolean, false) is not true then
      raise exception 'Tick that the customer agreed to the account terms and to us keeping their details';
    end if;
    insert into public.customer_accounts(account_no, name, contact_name, phone, email, billing_address, vat_no,
        credit_limit, max_sale, terms_days, cashier_visible, consent_at, consent_note)
    values ('ACC' || lpad(nextval('public.account_no_seq')::text, 4, '0'), v_name,
        nullif(trim(coalesce(p->>'contact_name', '')), ''), v_phone, v_email,
        nullif(trim(coalesce(p->>'billing_address', '')), ''), v_vat,
        round(v_limit, 2), round(v_max, 2), v_terms, v_vis, now(),
        nullif(trim(coalesce(p->>'consent_note', '')), ''))
    returning id into v_id;
  else
    update public.customer_accounts set name = v_name,
        contact_name = nullif(trim(coalesce(p->>'contact_name', '')), ''), phone = v_phone, email = v_email,
        billing_address = nullif(trim(coalesce(p->>'billing_address', '')), ''), vat_no = v_vat,
        credit_limit = round(v_limit, 2), max_sale = round(v_max, 2), terms_days = v_terms, cashier_visible = v_vis
    where id = v_id;
    if not found then raise exception 'Account not found'; end if;
  end if;
  return v_id;
end $$;

-- Admin only: allow (active), block (temporary) or stop (closed) an account.
create or replace function public.set_account_status(p_id uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can change an account''s status'; end if;
  if p_status not in ('active','blocked','stopped') then raise exception 'Unknown status'; end if;
  select * into a from public.customer_accounts where id = p_id for update;
  if not found then raise exception 'Account not found'; end if;
  if p_status in ('blocked','stopped') and length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Give a reason (at least 5 letters)';
  end if;
  if p_status = 'stopped' and abs(a.balance) > 0.005 then
    raise exception 'The account still has a balance of R%. Collect it or write it off before stopping the account.', a.balance;
  end if;
  update public.customer_accounts set status = p_status,
      status_reason = case when p_status = 'active' then null else trim(p_reason) end
  where id = p_id;
end $$;

-- What the till may offer. Cashiers see only accounts marked visible to them, and only
-- name, number, whether a sale is allowed and how much is available.
create or replace function public.till_accounts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); cs public.company_settings; out jsonb;
begin
  if v_role not in ('admin','supervisor','cashier') then raise exception 'Not allowed'; end if;
  select * into cs from public.company_settings where id = 1;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into out from (
    select jsonb_build_object(
      'id', a.id, 'account_no', a.account_no, 'name', a.name, 'status', a.status,
      'billing_address', a.billing_address, 'vat_no', a.vat_no,
      'can_charge', r.reason is null,
      'reason', r.reason,
      'available', case when r.reason is null
          then least(greatest(a.credit_limit - a.balance, 0), coalesce(a.max_sale, greatest(a.credit_limit - a.balance, 0)))
          else 0 end) x
    from public.customer_accounts a
    cross join lateral (select case
        when a.status = 'blocked' then 'Blocked'
        when a.consent_at is null then 'Not activated'
        when a.credit_limit <= 0 then 'No credit limit'
        when a.balance >= a.credit_limit - 0.005 then 'At credit limit'
        when cs.account_block_overdue and public.account_overdue(a.id) > 0 then 'Overdue, payment needed'
        else null end reason) r
    where a.status <> 'stopped' and (v_role <> 'cashier' or a.cashier_visible)
  ) y;
  return out;
end $$;

-- Admin and supervisor: record money received from an account customer.
create or replace function public.record_account_payment(
  p_account uuid, p_amount numeric, p_method text, p_reference text, p_note text, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_day date := (now() at time zone public.app_tz())::date;
        v_id uuid := coalesce(p_id, gen_random_uuid()); v_no bigint; t public.account_transactions;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can record an account payment';
  end if;
  if p_method not in ('cash','card','eft') then raise exception 'Choose cash, card or EFT'; end if;
  select * into t from public.account_transactions where id = v_id;
  if found then
    select * into a from public.customer_accounts where id = t.account_id;
    return jsonb_build_object('receipt_no', t.receipt_no, 'balance', a.balance, 'account_no', a.account_no,
        'name', a.name, 'amount', -t.amount, 'method', t.method, 'date', t.business_date, 'repeat', true);
  end if;
  if v_amt <= 0 then raise exception 'The amount must be more than R0'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if a.status = 'stopped' then raise exception 'This account is stopped'; end if;
  if a.balance <= 0.005 then raise exception 'Nothing is owing on this account'; end if;
  if v_amt > a.balance + 0.001 then raise exception 'The payment is more than the balance of R%.', a.balance; end if;
  if exists (select 1 from public.day_closes where business_date = v_day) then
    raise exception 'Today (%) is closed. An admin can reopen it.', v_day;
  end if;
  v_no := nextval('public.account_receipt_seq');
  insert into public.account_transactions(id, account_id, kind, amount, method, reference, note, receipt_no, business_date)
  values (v_id, a.id, 'payment', -v_amt, p_method, nullif(trim(coalesce(p_reference, '')), ''),
          nullif(trim(coalesce(p_note, '')), ''), v_no, v_day);
  select * into a from public.customer_accounts where id = a.id;
  return jsonb_build_object('receipt_no', v_no, 'balance', a.balance, 'account_no', a.account_no,
      'name', a.name, 'amount', v_amt, 'method', p_method, 'date', v_day, 'repeat', false);
end $$;

-- Admin only: write off an amount that cannot be collected. Needs a written reason.
-- The VAT treatment of a bad debt is for the accountant to decide.
create or replace function public.account_writeoff(p_account uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can write off a debt'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Write the reason for the write-off (at least 10 letters)'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  if v_amt <= 0 or v_amt > a.balance + 0.001 then raise exception 'The write-off must be more than R0 and not more than the balance of R%.', a.balance; end if;
  insert into public.account_transactions(account_id, kind, amount, note, business_date)
  values (a.id, 'writeoff', -v_amt, trim(p_reason), (now() at time zone public.app_tz())::date);
end $$;

-- Admin only: put back a written-off amount (for example when the customer pays after all).
create or replace function public.account_reinstate(p_account uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.customer_accounts; v_amt numeric := round(coalesce(p_amount, 0), 2); v_off numeric;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can reinstate a written-off debt'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Write the reason (at least 10 letters)'; end if;
  select * into a from public.customer_accounts where id = p_account for update;
  if not found then raise exception 'Account not found'; end if;
  select coalesce(-sum(amount) filter (where kind = 'writeoff'), 0) - coalesce(sum(amount) filter (where kind = 'writeoff_reversal'), 0)
    into v_off from public.account_transactions where account_id = a.id;
  if v_amt <= 0 or v_amt > v_off + 0.001 then raise exception 'Only R% has been written off and not yet reinstated.', v_off; end if;
  insert into public.account_transactions(account_id, kind, amount, note, business_date)
  values (a.id, 'writeoff_reversal', v_amt, trim(p_reason), (now() at time zone public.app_tz())::date);
end $$;

-- Admin and supervisor: all accounts with balances and ageing.
create or replace function public.account_ageing() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date := (now() at time zone public.app_tz())::date; v_g int; out jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then raise exception 'Not allowed'; end if;
  select account_grace_days into v_g from public.company_settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'account_no', a.account_no, 'name', a.name, 'status', a.status, 'status_reason', a.status_reason,
      'contact_name', a.contact_name, 'phone', a.phone, 'email', a.email, 'billing_address', a.billing_address, 'vat_no', a.vat_no,
      'credit_limit', a.credit_limit, 'max_sale', a.max_sale, 'terms_days', a.terms_days,
      'cashier_visible', a.cashier_visible, 'consent_at', a.consent_at, 'balance', a.balance,
      'available', greatest(a.credit_limit - a.balance, 0),
      'current', coalesce(o.b1, 0), 'd31', coalesce(o.b2, 0), 'd61', coalesce(o.b3, 0), 'd90', coalesce(o.b4, 0),
      'overdue', coalesce(o.od, 0),
      'last_payment', (select max(t.business_date) from public.account_transactions t where t.account_id = a.id and t.kind = 'payment')
    ) order by a.name), '[]'::jsonb) into out
  from public.customer_accounts a
  left join lateral (
    select sum(oi.outstanding) filter (where v_today - oi.txn_date <= 30) b1,
           sum(oi.outstanding) filter (where v_today - oi.txn_date between 31 and 60) b2,
           sum(oi.outstanding) filter (where v_today - oi.txn_date between 61 and 90) b3,
           sum(oi.outstanding) filter (where v_today - oi.txn_date > 90) b4,
           sum(oi.outstanding) filter (where v_today - oi.txn_date > a.terms_days + v_g) od
    from public.account_open_items(a.id) oi where oi.outstanding > 0) o on true;
  return out;
end $$;

-- Admin and supervisor: a statement for one account between two dates.
create or replace function public.account_statement(p_account uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a public.customer_accounts; v_open numeric; v_lines jsonb; v_today date := (now() at time zone public.app_tz())::date; v_age jsonb;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then raise exception 'Not allowed'; end if;
  select * into a from public.customer_accounts where id = p_account;
  if not found then raise exception 'Account not found'; end if;
  select coalesce(sum(amount), 0) into v_open from public.account_transactions where account_id = p_account and business_date < p_from;
  select coalesce(jsonb_agg(jsonb_build_object(
      'date', l.business_date, 'kind', l.kind, 'amount', l.amount, 'running', l.running,
      'ref', l.ref, 'invoice_no', l.invoice_no, 'credit_note_no', l.credit_note_no,
      'method', l.method, 'reference', l.reference, 'note', l.note) order by l.business_date, l.created_at, l.id), '[]'::jsonb)
    into v_lines
  from (
    select t.id, t.business_date, t.created_at, t.kind, t.amount, t.method, t.reference, t.note,
           case when t.kind = 'payment' then 'ARC' || lpad(t.receipt_no::text, 5, '0') else o.order_ref end ref,
           o.invoice_no, r.credit_note_no,
           v_open + sum(t.amount) over (order by t.business_date, t.created_at, t.id) running
    from public.account_transactions t
    left join public.orders o on o.id = t.order_id
    left join public.refunds r on r.id = t.refund_id
    where t.account_id = p_account and t.business_date between p_from and p_to
  ) l;
  select jsonb_build_object(
      'current', coalesce(sum(outstanding) filter (where v_today - txn_date <= 30), 0),
      'd31', coalesce(sum(outstanding) filter (where v_today - txn_date between 31 and 60), 0),
      'd61', coalesce(sum(outstanding) filter (where v_today - txn_date between 61 and 90), 0),
      'd90', coalesce(sum(outstanding) filter (where v_today - txn_date > 90), 0))
    into v_age from public.account_open_items(p_account) where outstanding > 0;
  return jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'account_no', a.account_no, 'name', a.name, 'contact_name', a.contact_name,
        'phone', a.phone, 'email', a.email, 'billing_address', a.billing_address, 'vat_no', a.vat_no,
        'credit_limit', a.credit_limit, 'terms_days', a.terms_days, 'status', a.status, 'balance', a.balance),
    'from', p_from, 'to', p_to, 'opening', v_open, 'lines', v_lines,
    'closing', coalesce((select sum(amount) from public.account_transactions where account_id = p_account and business_date <= p_to), 0),
    'ageing', v_age, 'as_at', v_today);
end $$;

-- ---- refunds: put an account sale back on the account ---------------------------------

create or replace function public.issue_refund(p_order_id uuid, p_amount numeric, p_method public.pay_method, p_reason text, p_restock boolean default false)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid boolean; v_done numeric; v_status public.order_status; v_frac numeric;
        v_acct_paid numeric; v_acct_back numeric; v_acct uuid; v_accts int; v_rid uuid;
begin
  if coalesce((select public.my_role())::text, '') not in ('admin','supervisor') then
    raise exception 'Only a supervisor or admin can refund';
  end if;
  select total, paid, status into v_total, v_paid, v_status from public.orders where id = p_order_id;
  if v_total is null then raise exception 'Order not found'; end if;
  if not v_paid then raise exception 'This order was never paid, nothing to refund'; end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = p_order_id;
  if p_amount <= 0 or p_amount > v_total - v_done + 0.001 then
    raise exception 'Refund must be more than 0 and no more than R% (still refundable)', (v_total - v_done);
  end if;
  if p_restock and v_status = 'void' then
    raise exception 'This order was cancelled, so its ingredients were already put back in stock';
  end if;
  select coalesce(sum(amount),0), min(account_id::text)::uuid, count(distinct account_id)
    into v_acct_paid, v_acct, v_accts from public.payments where order_id = p_order_id and method::text = 'account';
  select coalesce(sum(amount),0) into v_acct_back from public.refunds where order_id = p_order_id and method::text = 'account';
  if p_method::text = 'account' then
    if v_acct_paid <= 0 then raise exception 'This order was not paid on an account'; end if;
    if v_accts > 1 then raise exception 'This order was paid on more than one account. Ask the admin.'; end if;
    if p_amount > v_acct_paid - v_acct_back + 0.001 then
      raise exception 'Only R% of this order is still on the account.', (v_acct_paid - v_acct_back);
    end if;
  elsif v_acct_paid > 0 then
    if p_amount > (v_total - v_acct_paid) - (v_done - v_acct_back) + 0.001 then
      raise exception 'Only R% of this order was paid with cash or card. Refund the rest to the account.',
        ((v_total - v_acct_paid) - (v_done - v_acct_back));
    end if;
  end if;
  insert into public.refunds(order_id, amount, method, reason, restocked)
    values (p_order_id, round(p_amount,2), p_method, trim(p_reason), p_restock)
    returning id into v_rid;
  if p_method::text = 'account' then
    insert into public.account_transactions(account_id, kind, amount, order_id, refund_id, note, business_date)
    values (v_acct, 'credit_note', -round(p_amount, 2), p_order_id, v_rid, trim(p_reason),
            (now() at time zone public.app_tz())::date);
  end if;
  if p_restock and v_total > 0 then
    v_frac := least(p_amount / v_total, 1);
    insert into public.stock_movements (stock_item_id, qty_change, reason, ref_id, note)
    select x.stock_item_id, round(least(x.used * v_frac, x.used - x.back), 3), 'sale_void'::public.move_reason, x.ref_id, 'Refund restock'
    from (
      select m.ref_id, m.stock_item_id,
             -sum(m.qty_change) filter (where m.reason = 'sale') used,
             coalesce(sum(m.qty_change) filter (where m.reason = 'sale_void'), 0) back
      from public.stock_movements m join public.order_items oi on oi.id = m.ref_id
      where oi.order_id = p_order_id and not oi.voided and m.reason in ('sale','sale_void')
      group by m.ref_id, m.stock_item_id
    ) x
    where x.used > 0 and round(least(x.used * v_frac, x.used - x.back), 3) > 0;
  end if;
end $$;

-- ---- cash-up: account sales are not cash; cash received on accounts is ----------------

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
           - (s->>'cash_out')::numeric + v_in, 2);
  insert into public.cash_ups(business_date, staff_id, opening_float, cash_sales, cash_refunds, expected_cash, counted_cash, variance,
      card_sales, card_refunds, card_slips, cash_tips, card_tips, cash_out, cash_in, notes)
  values (p_date, p_staff, round(p_float,2), (s->>'cash_sales')::numeric, (s->>'cash_refunds')::numeric, v_exp, round(p_counted,2),
      round(p_counted - v_exp, 2), (s->>'card_sales')::numeric, (s->>'card_refunds')::numeric, (s->>'card_slips')::int,
      (s->>'cash_tips')::numeric, (s->>'card_tips')::numeric, (s->>'cash_out')::numeric, v_in,
      nullif(trim(coalesce(p_notes,'')),''));
end $$;

-- ---- clearing test sales also clears the test account entries ---------------------------

create or replace function public.clear_test_sales(p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n_orders int;
begin
  if coalesce((select public.my_role())::text, '') <> 'admin' then raise exception 'Only an admin can clear sales'; end if;
  if p_confirm is distinct from 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  select count(*) into n_orders from public.orders;
  perform set_config('pos.clearing', 'on', true);
  delete from public.account_transactions;
  update public.customer_accounts set balance = 0;
  perform setval('public.account_receipt_seq', 1, false);
  perform set_config('pos.clearing', 'off', true);
  update public.stock_items si set qty_on_hand = si.qty_on_hand - x.q
  from (select stock_item_id, sum(qty_change) q from public.stock_movements where reason in ('sale','sale_void') group by 1) x
  where x.stock_item_id = si.id;
  delete from public.stock_movements where reason in ('sale','sale_void');
  delete from public.refunds;
  delete from public.cash_ups;
  delete from public.payments;
  delete from public.order_items;
  delete from public.orders;
  perform setval('public.invoice_seq', 1, false);
  return jsonb_build_object('orders_removed', n_orders);
end $$;

-- ---- who may call what -------------------------------------------------------------------

revoke execute on function public.ledger_immutable() from public, anon, authenticated;
revoke execute on function public.ledger_apply() from public, anon, authenticated;
revoke execute on function public.audit_account() from public, anon, authenticated;
revoke execute on function public.account_snapshot() from public, anon, authenticated;
revoke execute on function public.account_charge() from public, anon, authenticated;
revoke execute on function public.account_on_void() from public, anon, authenticated;
revoke execute on function public.account_open_items(uuid) from public, anon, authenticated;
revoke execute on function public.account_overdue(uuid) from public, anon, authenticated;

revoke execute on function public.save_account(jsonb) from public, anon;
revoke execute on function public.set_account_status(uuid, text, text) from public, anon;
revoke execute on function public.till_accounts() from public, anon;
revoke execute on function public.record_account_payment(uuid, numeric, text, text, text, uuid) from public, anon;
revoke execute on function public.account_writeoff(uuid, numeric, text) from public, anon;
revoke execute on function public.account_reinstate(uuid, numeric, text) from public, anon;
revoke execute on function public.account_ageing() from public, anon;
revoke execute on function public.account_statement(uuid, date, date) from public, anon;
grant execute on function public.save_account(jsonb) to authenticated;
grant execute on function public.set_account_status(uuid, text, text) to authenticated;
grant execute on function public.till_accounts() to authenticated;
grant execute on function public.record_account_payment(uuid, numeric, text, text, text, uuid) to authenticated;
grant execute on function public.account_writeoff(uuid, numeric, text) to authenticated;
grant execute on function public.account_reinstate(uuid, numeric, text) to authenticated;
grant execute on function public.account_ageing() to authenticated;
grant execute on function public.account_statement(uuid, date, date) to authenticated;
