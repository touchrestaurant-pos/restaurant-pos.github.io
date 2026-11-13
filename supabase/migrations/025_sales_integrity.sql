-- Sales integrity. The till works exactly as before (orders, items and payments are still saved on the device and
-- synced). The server now stops a modified app from changing money fields it should not.
--  * "paid" and the invoice number come only from payments the server has seen
--  * a cashier cannot raise a discount, change a price or quantity, or void items on a paid order
--  * a discount over the cashier's limit needs a one-time manager approval; without it the discount is cut back
--    to the limit and logged (the sale is never lost)
--  * a cashier's own name is always put on the orders and payments they create

alter table public.orders add column if not exists discount_approval uuid;

create table if not exists public.discount_approvals (
  id uuid primary key default gen_random_uuid(),
  cashier uuid not null,
  approver uuid not null,
  amount numeric(12,2) not null,
  detail text,
  created_at timestamptz not null default now(),
  used_order uuid
);
alter table public.discount_approvals enable row level security;
revoke all on public.discount_approvals from public, anon, authenticated;

-- Manager approves one discount. Returns {id, by}, or null when the PIN is wrong (the failed try is kept and counts toward the lock-out).
create or replace function public.approve_discount(p_pin text, p_amount numeric, p_detail text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_fail int; v_name text; v_id uuid; v_ap uuid;
begin
  if coalesce((select public.my_role())::text, '') <> 'cashier' then raise exception 'Only a cashier asks for a discount approval'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the discount first'; end if;
  select count(*) into v_fail from public.audit_log
    where table_name = 'approval' and action = 'failed' and user_id = auth.uid() and at > now() - interval '10 minutes';
  if v_fail >= 5 then raise exception 'Too many wrong PINs. Wait 10 minutes or ask the manager to log in.'; end if;
  select mp.staff_id, sp.full_name into v_id, v_name
    from public.manager_pins mp join public.staff_profiles sp on sp.id = mp.staff_id
    where sp.role::text in ('admin','supervisor') and coalesce(sp.active, true)
      and mp.pin_hash = encode(sha256(convert_to(mp.salt || p_pin, 'UTF8')), 'hex')
    limit 1;
  if v_id is null then
    insert into public.audit_log(table_name, row_id, action, changes) values ('approval', null, 'failed', jsonb_build_object('what', 'discount'));
    return null;
  end if;
  insert into public.discount_approvals(cashier, approver, amount, detail) values (auth.uid(), v_id, round(p_amount, 2), p_detail) returning id into v_ap;
  insert into public.audit_log(table_name, row_id, action, changes)
    values ('approval', v_id::text, 'approved', jsonb_build_object('what', 'discount', 'detail', p_detail, 'approved_by', v_name, 'amount', p_amount));
  return jsonb_build_object('id', v_ap, 'by', v_name);
end $$;
revoke execute on function public.approve_discount(text, numeric, text) from public, anon;
grant execute on function public.approve_discount(text, numeric, text) to authenticated;

-- Orders
create or replace function public.guard_order() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_role text := coalesce((select public.my_role())::text, '');
  v_mgr boolean := coalesce((select public.my_role())::text, '') in ('admin','supervisor');
  v_items numeric; v_std numeric; v_rate numeric; v_pj jsonb; v_lim numeric; v_gross numeric; v_found int;
begin
  if tg_op = 'UPDATE' then
    new.invoice_no := coalesce(old.invoice_no, new.invoice_no);
    new.created_by := coalesce(old.created_by, new.created_by);
    -- Only a payment the server has seen can make an order paid.
    if new.paid and not old.paid and coalesce(current_setting('pos.paying', true), '') <> '1' then new.paid := false; end if;
    if old.paid and not new.paid then new.paid := true; end if;
    if new.invoice_no is distinct from old.invoice_no and old.invoice_no is not null then new.invoice_no := old.invoice_no; end if;
    new.discount_approval := old.discount_approval;
    if not v_mgr and new.discount > old.discount + 0.005 then
      insert into public.audit_log(table_name, row_id, action, changes)
        values ('orders', new.id::text, 'blocked_change', jsonb_build_object('what', 'discount raised', 'from', old.discount, 'to', new.discount, 'order_ref', new.order_ref));
      new.discount := old.discount; new.discount_reason := old.discount_reason;
    end if;
    if old.status = 'void' then
      new.status := 'void';
      new.voided_at := old.voided_at;
      new.voided_by := old.voided_by;
      new.void_reason := coalesce(old.void_reason, new.void_reason);
    end if;
    new.cancel_ack_at := coalesce(new.cancel_ack_at, old.cancel_ack_at);
    if new.status = 'void' and old.status <> 'void' then
      if old.paid and not v_mgr then
        raise exception 'Only a supervisor or admin can cancel an order that has been paid';
      end if;
      if v_role = 'cashier' and not old.paid and public.my_perm('can_cancel_unpaid') = 'false'::jsonb then
        raise exception 'You are not allowed to cancel orders. Ask a supervisor.';
      end if;
      new.voided_by := coalesce(new.voided_by, auth.uid());
      new.voided_at := coalesce(new.voided_at, now());
    end if;
    select sum(qty * unit_price), sum(qty * unit_price) filter (where vat_type = 'standard')
      into v_items, v_std from public.order_items where order_id = new.id and not voided;
    if v_items is not null then
      select coalesce(vat_rate, 15) into v_rate from public.company_settings where id = 1;
      new.total := round(greatest(v_items - new.discount, 0), 2);
      new.vat := round(new.total * (case when v_items > 0 then coalesce(v_std, 0) / v_items else 1 end) * v_rate / (100 + v_rate), 2);
      new.subtotal := new.total - new.vat;
    end if;
  else
    -- A new order is never paid until its payments arrive; the invoice number is given then.
    new.paid := false;
    new.invoice_no := null;
    new.created_by := case when v_role = 'cashier' then auth.uid() else coalesce(new.created_by, auth.uid()) end;
    if new.discount > 0 and not v_mgr then
      v_gross := new.total + new.discount;
      v_pj := public.my_perm('max_discount_pct');
      v_lim := case when jsonb_typeof(v_pj) = 'number' then (v_pj #>> '{}')::numeric else 10 end;
      if new.discount > v_gross * v_lim / 100 + 0.01 then
        update public.discount_approvals set used_order = new.id
          where id = new.discount_approval and cashier = auth.uid() and used_order is null
            and amount >= new.discount - 0.01
            and created_at > coalesce(new.created_at, now()) - interval '3 hours'
            and created_at < coalesce(new.created_at, now()) + interval '30 minutes';
        get diagnostics v_found = row_count;
        if v_found > 0 then
          insert into public.audit_log(table_name, row_id, action, changes)
            values ('orders', new.id::text, 'discount_approved', jsonb_build_object('discount', new.discount, 'order_ref', new.order_ref));
        else
          insert into public.audit_log(table_name, row_id, action, changes)
            values ('orders', new.id::text, 'discount_cut_back', jsonb_build_object('asked', new.discount, 'allowed', round(v_gross * v_lim / 100, 2), 'order_ref', new.order_ref));
          new.discount := round(v_gross * v_lim / 100, 2);
          new.total := round(v_gross - new.discount, 2);
        end if;
      end if;
    end if;
  end if;
  if new.paid and new.invoice_no is null then
    new.invoice_no := nextval('public.invoice_seq');
  end if;
  return new;
end $$;

-- A payment is what makes an order paid.
create or replace function public.mark_order_paid() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('pos.paying', '1', true);
  update public.orders o set paid = true
  where o.id = new.order_id and not o.paid
    and (select coalesce(sum(amount), 0) from public.payments where order_id = new.order_id) >= o.total - 0.005;
  perform set_config('pos.paying', '', true);
  return new;
end $$;

-- Items: a cashier or kitchen user cannot change what was sold or for how much.
create or replace function public.guard_order_item() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role text := coalesce((select public.my_role())::text, ''); v_paid boolean;
begin
  if v_role in ('admin','supervisor') then return new; end if;
  if new.unit_price is distinct from old.unit_price or new.qty is distinct from old.qty
     or new.vat_type is distinct from old.vat_type or new.product_id is distinct from old.product_id then
    insert into public.audit_log(table_name, row_id, action, changes)
      values ('order_items', new.id::text, 'blocked_change', jsonb_build_object('what', 'price or quantity', 'item', old.name,
        'price', jsonb_build_array(old.unit_price, new.unit_price), 'qty', jsonb_build_array(old.qty, new.qty)));
    new.unit_price := old.unit_price; new.qty := old.qty; new.vat_type := old.vat_type; new.product_id := old.product_id;
  end if;
  if new.voided and not old.voided then
    select paid into v_paid from public.orders where id = new.order_id;
    if coalesce(v_paid, false)
       or (old.done and v_role = 'cashier' and coalesce(public.my_perm('can_remove_sent'), 'false'::jsonb) <> 'true'::jsonb) then
      insert into public.audit_log(table_name, row_id, action, changes)
        values ('order_items', new.id::text, 'blocked_change', jsonb_build_object('what', 'item removed', 'item', old.name, 'order_paid', coalesce(v_paid, false)));
      new.voided := false; new.voided_at := old.voided_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_item on public.order_items;
create trigger trg_guard_item before update on public.order_items for each row execute function public.guard_order_item();

-- A cashier's payments always carry their own name.
create or replace function public.guard_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce((select public.my_role())::text, '') = 'cashier' then new.created_by := auth.uid(); end if;
  return new;
end $$;
drop trigger if exists trg_guard_payment on public.payments;
create trigger trg_guard_payment before insert on public.payments for each row execute function public.guard_payment();

revoke execute on function public.guard_order(), public.mark_order_paid(), public.guard_order_item(), public.guard_payment() from public, anon, authenticated;
