-- Staff sign in with a username. Each username maps to a hidden internal email
-- (username@<staff login domain>) because Supabase logins need an email.

alter table public.staff_profiles add column username text;
create unique index staff_profiles_username_key on public.staff_profiles (lower(username)) where username is not null;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.staff_profiles (id, full_name, username, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    nullif(lower(new.raw_user_meta_data->>'username'), ''),
    case when not exists (select 1 from public.staff_profiles) then 'admin'::public.app_role else 'cashier'::public.app_role end
  );
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
