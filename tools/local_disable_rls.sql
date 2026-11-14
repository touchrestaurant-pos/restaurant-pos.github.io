-- Disable RLS on all tables for local single-store use.
-- This makes direct SQL queries work without needing to set session roles.
DO $$ DECLARE t text; BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Also grant the postgres superuser all the needed roles
GRANT anon TO postgres;
GRANT authenticated TO postgres;
GRANT service_role TO postgres;
