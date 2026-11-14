-- Runs after the database is built: removes the sample menu, stock and suppliers
-- so a new store starts blank. Company settings and all rules stay.
truncate table
  public.grv_lines, public.grvs, public.recipe_lines, public.modifiers, public.products,
  public.categories, public.stock_movements, public.stock_items, public.suppliers,
  public.stock_categories, public.audit_log
  restart identity cascade;
update public.company_settings
   set company_name = 'New store', trading_name = 'New store', logo_url = null,
       phone = null, email = null, address = null, vat_number = null, reg_number = null,
       receipt_footer = null, eft_details = null, accept_eft = false, receipt_style = '{}'::jsonb,
       live_since = null
 where id = 1;
