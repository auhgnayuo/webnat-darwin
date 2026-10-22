#!/usr/bin/env python3
"""Verify versioned contract fixtures and cross-repository copies."""
import argparse, hashlib, json, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(); parser.add_argument('--workspace', action='store_true'); args = parser.parse_args()
repos = ['webnat-web','webnat-electron','webnat-darwin','webnat-ohos','webnat-android']
paths = [root.parent / repo for repo in repos] if args.workspace else [root]
for version in (1, 2):
    reference = None
    for repo in paths:
        folder = repo / ('contracts/v%d' % version)
        data = (folder / 'golden.json').read_bytes()
        manifest = json.loads((folder / 'manifest.json').read_text())
        assert hashlib.sha256(data).hexdigest() == manifest['sha256'], '%s: fixture digest mismatch' % repo.name
        fixtures = json.loads(data); assert fixtures['version'] == manifest['version'] == version
        for key in ['errors','messages','rejectedMessages','invalidValues','scenarios']:
            ids = [case['id'] for case in fixtures[key]]; assert len(ids) == len(set(ids)), '%s: duplicate IDs' % key
        identity = (data, (folder / 'manifest.json').read_bytes())
        if reference is not None: assert identity == reference, '%s: contract v%d drifted' % (repo.name, version)
        reference = identity
        if version == 2:
            generated = repo / 'library/src/test/contract-fixtures.ets'
            if generated.exists():
                text = generated.read_text(); literal = text.split('export const contractJson: string = ',1)[1].strip()[:-1]
                assert json.loads(literal) == data.decode(), 'OHOS generated contract module drifted'
        print('%s: contract v%d verified (%s)' % (repo.name, version, manifest['sha256'][:12]))
