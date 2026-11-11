-- Customer accounts, step 1: a new way to pay. Kept on its own because a new enum
-- value cannot be used in the same transaction that adds it.
alter type public.pay_method add value if not exists 'account';
