-- Creates the first admin user in the local database.
-- Usage: psql ... -v admin_name='John' -v admin_user='admin' -v admin_pass='1234' -f local_create_admin.sql
-- Or set the variables inline before running.

DO $$
DECLARE
  v_name text := coalesce(nullif(current_setting('vars.admin_name', true), ''), 'Admin');
  v_user text := coalesce(nullif(current_setting('vars.admin_user', true), ''), 'admin');
  v_pass text := coalesce(nullif(current_setting('vars.admin_pass', true), ''), '1234');
  v_uid uuid;
  v_email text;
BEGIN
  v_email := lower(v_user) || '@store.local';

  -- Check if user already exists
  SELECT id INTO v_uid FROM auth.users WHERE email = v_email;
  IF v_uid IS NOT NULL THEN
    RAISE NOTICE 'User "%" already exists with id %', v_user, v_uid;
    RETURN;
  END IF;

  -- Create the auth user
  INSERT INTO auth.users (email, encrypted_password, raw_user_meta_data)
  VALUES (v_email, crypt(v_pass, gen_salt('bf')), jsonb_build_object('full_name', v_name))
  RETURNING id INTO v_uid;

  -- The handle_new_user trigger will create the staff_profiles row.
  -- Since this is the first user, the trigger makes them admin.

  RAISE NOTICE 'Created admin user "%" (%) with id %', v_name, v_user, v_uid;
END $$;
