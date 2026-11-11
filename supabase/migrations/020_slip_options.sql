alter table public.company_settings
  add column if not exists show_vat_on_slip boolean not null default true,
  add column if not exists show_notes_on_slip boolean not null default false;
