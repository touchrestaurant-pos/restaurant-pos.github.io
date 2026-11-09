create policy company_assets_select on storage.objects for select to authenticated using (bucket_id = 'company-assets');
