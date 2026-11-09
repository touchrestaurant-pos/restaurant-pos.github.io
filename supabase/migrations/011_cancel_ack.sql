alter table public.orders add column if not exists cancel_ack_at timestamptz;
update public.orders set cancel_ack_at = now() where status = 'void' and cancel_ack_at is null;
