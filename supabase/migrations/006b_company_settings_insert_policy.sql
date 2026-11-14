-- Was applied to the live database on 2026-11-09 without a file here.
drop policy if exists company_insert on public.company_settings;
create policy company_insert on public.company_settings for insert to authenticated with check ((select public.my_role()) = 'admin');
