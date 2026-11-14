#!/usr/bin/env python3
"""
Builds a single SQL file that sets up the local RestoPOS database:
  1. Bootstrap (auth stubs, roles, storage stubs)
  2. All migrations in order
  3. Disable RLS (single-store, not needed)

Output: tools/local_setup.sql  (run with psql)
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MIGRATIONS = os.path.join(ROOT, 'supabase', 'migrations')

parts = []

# 1. Bootstrap
with open(os.path.join(HERE, 'local_bootstrap.sql'), encoding='utf-8') as f:
    parts.append(f'-- ===== BOOTSTRAP =====\n{f.read()}')

# 2. Migrations (sorted by filename)
files = sorted(f for f in os.listdir(MIGRATIONS) if f.endswith('.sql'))
for fname in files:
    with open(os.path.join(MIGRATIONS, fname), encoding='utf-8') as f:
        sql = f.read()
    parts.append(f'\n-- ===== MIGRATION: {fname} =====\n{sql}')

# 3. Disable RLS
with open(os.path.join(HERE, 'local_disable_rls.sql'), encoding='utf-8') as f:
    parts.append(f'\n-- ===== DISABLE RLS =====\n{f.read()}')

# 4. Create admin user helper
with open(os.path.join(HERE, 'local_create_admin.sql'), encoding='utf-8') as f:
    parts.append(f'\n-- ===== CREATE FIRST ADMIN =====\n{f.read()}')

out = os.path.join(HERE, 'local_setup.sql')
with open(out, 'w', encoding='utf-8') as f:
    f.write('\n'.join(parts))

print(f'Wrote {os.path.getsize(out):,} bytes -> {out}')
print(f'Included {len(files)} migration files')
print()
print('To run:')
print(f'  psql -U postgres -d postgres -f "{out}"')
