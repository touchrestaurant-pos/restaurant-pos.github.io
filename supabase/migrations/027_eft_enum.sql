-- EFT / bank transfer as a payment type (applied on its own so the new value can be used by 028).
alter type public.pay_method add value if not exists 'eft';
