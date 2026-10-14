"""Test stronger XLSX compression without changing any internal file bytes."""
import argparse,hashlib,json
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED

def digest(stream):
    h=hashlib.sha256()
    for b in iter(lambda:stream.read(1048576),b''):h.update(b)
    return h.hexdigest()

def compress(source,destination):
    source=Path(source);destination=Path(destination)
    if destination.exists():raise FileExistsError(destination)
    with ZipFile(source) as old,destination.open('xb') as out,ZipFile(out,'w',ZIP_DEFLATED,compresslevel=9) as new:
        for item in old.infolist():new.writestr(item,old.read(item.filename),compress_type=ZIP_DEFLATED,compresslevel=9)
    with ZipFile(source) as old,ZipFile(destination) as new:
        if old.namelist()!=new.namelist() or new.testzip():raise ValueError('Package verification failed')
        for name in old.namelist():
            with old.open(name) as a,new.open(name) as b:
                if digest(a)!=digest(b):raise ValueError('Internal workbook content changed')
    r={'source_bytes':source.stat().st_size,'compressed_bytes':destination.stat().st_size,'all_internal_members_identical':True,'email_sent':False}
    destination.with_suffix('.compression_receipt.json').write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps(r,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True);a=p.parse_args();compress(a.source,a.destination)
