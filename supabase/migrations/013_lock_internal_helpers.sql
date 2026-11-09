-- Internal helpers used only inside other database functions.
revoke execute on function public.app_tz() from public, anon, authenticated;
revoke execute on function public.item_usage(uuid, uuid[], numeric) from public, anon, authenticated;
