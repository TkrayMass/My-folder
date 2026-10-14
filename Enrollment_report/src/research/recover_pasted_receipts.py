"""Recover SAS-log receipt text; accept manifest only if original hash matches."""
import argparse
import hashlib
import json
import re
from pathlib import Path

def recover(text):
    blocks = re.findall(r'(?m)^ \{\r?\n.*?^ \}\r?$', text, re.S | re.M)
    if len(blocks) != 2:
        raise ValueError('Expected exactly two JSON receipts')
    results = []
    for block in blocks:
        cleaned = '\n'.join(line[1:] if line.startswith(' ') else line for line in block.splitlines())
        # SAS wraps long path and policy strings. Rejoin only those observed fields.
        cleaned = re.sub(r'("path": "[^"\n]*)\n\s*', r'\1', cleaned)
        cleaned = re.sub(r'("policy": "[^"\n]*)\n\s*', r'\1 ', cleaned)
        results.append(json.loads(cleaned))
    manifest, qc = results
    raw_manifest = (json.dumps(manifest, indent=2) + '\n').encode('utf-8')
    original_hash = next(c['evidence_sha256'] for c in qc['checks'] if c['check']=='technical_completion')
    if hashlib.sha256(raw_manifest).hexdigest() != original_hash:
        raise ValueError('Reconstructed manifest does not match original server SHA256')
    return raw_manifest, (json.dumps(qc, indent=2)+'\n').encode('utf-8')

if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('log');p.add_argument('destination');a=p.parse_args()
    manifest,qc=recover(Path(a.log).read_text(encoding='utf-8-sig'))
    destination=Path(a.destination);destination.mkdir(exist_ok=True)
    (destination/'RUN_MANIFEST.json').write_bytes(manifest)
    (destination/'FINAL_QC.json').write_bytes(qc)
    print('Original manifest SHA256 verified; receipts recovered')
