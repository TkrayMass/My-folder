#!/usr/bin/env python3
"""Lossless ZIP recompression only; verify every XLSX member byte-for-byte.

This creates a separate delivery candidate, never alters report cells or source.
No email, publication, schedules, or release decisions are performed here.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

def digest(stream):
    h=hashlib.sha256()
    for chunk in iter(lambda:stream.read(1048576),b''):h.update(chunk)
    return h.hexdigest()
def repack(source,destination):
    source=Path(source).resolve();destination=Path(destination).resolve()
    if source==destination or destination.exists():raise ValueError('New separate destination required')
    temporary=destination.with_suffix('.partial')
    with temporary.open('xb') as target:
        with ZipFile(source) as original,ZipFile(target,'w',compression=ZIP_DEFLATED,allowZip64=True) as output:
            entries=original.namelist()
            if len(set(entries))!=len(entries):raise ValueError('Duplicate ZIP entries')
            if original.testzip():raise ValueError('Corrupt source ZIP')
            for entry in entries:
                with original.open(entry) as inp,output.open(entry,'w') as out:
                    shutil.copyfileobj(inp,out,1048576)
    with ZipFile(source) as original,ZipFile(temporary) as output:
        if original.namelist()!=output.namelist() or output.testzip():raise ValueError('Repacked ZIP differs')
        for name in original.namelist():
            with original.open(name) as a,output.open(name) as b:
                if digest(a)!=digest(b):raise ValueError('XLSX member changed: '+name)
    with source.open('rb') as f:source_hash=digest(f)
    with temporary.open('rb') as f:delivery_hash=digest(f)
    temporary.rename(destination)
    result={'source':str(source),'source_sha256':source_hash,'source_bytes':source.stat().st_size,
        'delivery':str(destination),'delivery_sha256':delivery_hash,'delivery_bytes':destination.stat().st_size,
        'member_contents':'IDENTICAL','candidate_only':True,'publication_allowed':False}
    with destination.with_suffix('.receipt.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True)
    a=p.parse_args();print(json.dumps(repack(a.source,a.destination),indent=2))
