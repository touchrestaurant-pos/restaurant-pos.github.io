-- Receipt layout the owner can style (font size, logo size/hide, which header lines show, divider style).
-- One flexible column so new options need no further migration. Footer text stays in receipt_footer.
alter table public.company_settings add column if not exists receipt_style jsonb not null default '{}'::jsonb;
