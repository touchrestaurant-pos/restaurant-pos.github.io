-- EFT / bank transfer payments: a required bank reference, an on/off switch, banking details for the cashier,
-- a separate line in the cash-up (it is not cash in the drawer), and a per-cashier permission.
alter table public.payments add column if not exists reference text;
alter table public.company_settings add column if not exists accept_eft boolean not null default false;
alter table public.company_settings add column if not exists eft_details text;

-- Cash-up: add EFT figures next to the card figures (patched in place so the rest of the function is untouched).
do $$ declare d text; begin
  d := pg_get_functiondef('public.cash_up_summary(date,uuid)'::regprocedure);
  if d not like '%eft_sales%' then
    d := replace(d, '''account_sales'', coalesce(',
      '''eft_sales'', coalesce((select sum(amount) from p where method::text = ''eft''), 0), ''eft_count'', (select count(*) from p where method::text = ''eft''), ''eft_refunds'', coalesce((select sum(amount) from rf where method::text = ''eft''), 0), ''account_sales'', coalesce(');
    d := replace(d, '''card'', coalesce(sum(p.amount) filter (where p.method = ''card_manual''), 0),',
      '''card'', coalesce(sum(p.amount) filter (where p.method = ''card_manual''), 0), ''eft'', coalesce(sum(p.amount) filter (where p.method::text = ''eft''), 0),');
    execute d;
  end if;
end $$;

-- Payments: EFT needs a reference, and a cashier can be switched off from taking it.
create or replace function public.guard_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, '');
begin
  if v_role = 'cashier' then new.created_by := auth.uid(); end if;
  if new.method::text = 'eft' then
    if length(trim(coalesce(new.reference, ''))) = 0 then raise exception 'An EFT payment needs the bank reference'; end if;
    if v_role = 'cashier' and public.my_perm('can_take_eft') = 'false'::jsonb then
      raise exception 'You are not allowed to take EFT payments. Ask the admin.';
    end if;
    if coalesce(new.tip, 0) <> 0 then raise exception 'A tip cannot be put on an EFT payment'; end if;
  end if;
  return new;
end $$;
