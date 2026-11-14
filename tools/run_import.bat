@echo off
REM Imports all Supabase data into the local restopos database.
REM Run this from the restaurant-pos folder. Password prompt = your postgres password.
cd /d "%~dp0.."
set PGBIN=C:\Program Files\PostgreSQL\17\bin
"%PGBIN%\psql.exe" -U postgres -d restopos -f tools\local_import_data.sql
echo.
echo Row counts:
"%PGBIN%\psql.exe" -U postgres -d restopos -c "SELECT 'products' t, count(*) FROM public.products UNION ALL SELECT 'orders', count(*) FROM public.orders UNION ALL SELECT 'stock_items', count(*) FROM public.stock_items UNION ALL SELECT 'stock_movements', count(*) FROM public.stock_movements UNION ALL SELECT 'users', count(*) FROM auth.users;"
pause
