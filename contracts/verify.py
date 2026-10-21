#!/usr/bin/env python3
"""Verify versioned fixtures; --workspace compares all five vendored copies."""
import argparse, hashlib, json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(); parser.add_argument('--workspace', action='store_true'); args = parser.parse_args()
repos = ['webnat-web','webnat-electron','webnat-darwin','webnat-ohos','webnat-android']
paths = [root.parent / repo for repo in repos] if args.workspace else [root]
reference = None
for repo in paths:
    folder = repo / 'contracts/v1'; data = (folder / 'golden.json').read_bytes(); manifest = json.loads((folder / 'manifest.json').read_text())
    assert hashlib.sha256(data).hexdigest() == manifest['sha256'], '%s: fixture digest mismatch' % repo.name
    fixtures = json.loads(data); assert fixtures['version'] == manifest['version'] == 1
    for key in ['errors','messages','rejectedMessages','invalidValues','scenarios']:
        ids = [case['id'] for case in fixtures[key]]; assert len(ids) == len(set(ids)), '%s: duplicate IDs' % key
    identity = (data, (folder / 'manifest.json').read_bytes())
    if reference is not None: assert identity == reference, '%s: contracts drifted' % repo.name
    reference = identity
    generated = repo / 'library/src/test/contract-fixtures.ets'
    if generated.exists():
        text = generated.read_text(); literal = text.split('export const contractJson: string = ',1)[1].strip()[:-1]
        assert json.loads(literal) == data.decode(), 'OHOS generated contract module drifted'
    print('%s: contract v1 verified (%s)' % (repo.name, manifest['sha256'][:12]))
