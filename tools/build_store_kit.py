#!/usr/bin/env python3
"""Builds the Store Kit folder: scripts + config + every database migration, renumbered so the
Supabase tool accepts the file names. Usage: python3 tools/build_store_kit.py <output folder>"""
import os, re, shutil, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = sys.argv[1]
shutil.rmtree(out, ignore_errors=True)
sb = os.path.join(out, 'supabase')
os.makedirs(os.path.join(sb, 'migrations'))
src = os.path.join(root, 'store-kit', 'files')
for f in os.listdir(src):
    dest = sb if f in ('config.toml', 'seed.sql') else out
    data = open(os.path.join(src, f), 'rb').read()
    if f.endswith(('.bat', '.txt')):
        data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')   # Windows line endings
    open(os.path.join(dest, f), 'wb').write(data)
migs = sorted(f for f in os.listdir(os.path.join(root, 'supabase', 'migrations')) if f.endswith('.sql'))
for i, f in enumerate(migs, 1):
    name = re.sub(r'^[0-9]+[a-z]?_', '', f)
    shutil.copy(os.path.join(root, 'supabase', 'migrations', f), os.path.join(sb, 'migrations', f'{i * 10:05d}_{name}'))
shutil.copytree(os.path.join(root, 'supabase', 'functions'), os.path.join(sb, 'functions'))
print(len(migs), 'migrations ->', out)
