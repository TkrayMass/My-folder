"""Normalize SAS/Linux font aliases for Windows Excel in a separate copy.

Only the font records in styles.xml change. Every other ZIP member is verified
byte-identical. Original output is retained. No email or publication is done.
"""
import argparse,hashlib,json,re,shutil,xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED
X='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def sha(stream):
    h=hashlib.sha256()
    for c in iter(lambda:stream.read(1048576),b''):h.update(c)
    return h.hexdigest()
def normalize(source,destination):
    source=Path(source);destination=Path(destination)
    if destination.exists():raise FileExistsError('Preserve existing outputs')
    with destination.open('xb') as f,ZipFile(source) as old,ZipFile(f,'w',ZIP_DEFLATED) as new:
        original_styles=old.read('xl/styles.xml').decode('utf-8')
        # Do not serialize the whole tree: doing so drops namespace declarations
        # referenced only in mc:Ignorable, which makes Excel discard the styles.
        match=re.search(r'(<fonts\b[^>]*>)(.*?)(</fonts>)',original_styles,re.S)
        if not match:raise ValueError('Expected native SAS font block')
        fonts=match.group(2)
        fonts,names=re.subn(r'(<name\b[^>]*\bval=")[^"]*(")',r'\g<1>Arial\2',fonts)
        fonts,sizes=re.subn(r'(<sz\b[^>]*\bval=")[^"]*(")',r'\g<1>11\2',fonts)
        expected=len(ET.fromstring(original_styles).find('{'+X+'}fonts'))
        if names!=expected or sizes!=expected:raise ValueError('Unexpected font schema')
        corrected_styles=original_styles[:match.start(2)]+fonts+original_styles[match.end(2):]
        if corrected_styles[:match.start(2)]!=original_styles[:match.start(2)]:raise ValueError('Style prefix changed')
        for font in ET.fromstring(corrected_styles).find('{'+X+'}fonts'):
            if font.find('{'+X+'}name').get('val')!='Arial' or font.find('{'+X+'}sz').get('val')!='11':raise ValueError('Font normalization failed')
        for name in old.namelist():
            if name=='xl/styles.xml':new.writestr(name,corrected_styles.encode('utf-8'))
            else:
                with old.open(name) as inp,new.open(name,'w') as out:shutil.copyfileobj(inp,out,1048576)
    with ZipFile(source) as old,ZipFile(destination) as new:
        if old.namelist()!=new.namelist():raise ValueError('Package members changed')
        for name in old.namelist():
            if name=='xl/styles.xml':continue
            with old.open(name) as a,new.open(name) as b:
                if sha(a)!=sha(b):raise ValueError('Report content changed')
    with source.open('rb') as f:original_hash=sha(f)
    with destination.open('rb') as f:result_hash=sha(f)
    result={'source_sha256':original_hash,'result_sha256':result_hash,'changes':'styles.xml font family Arial, size 11; all other members byte-identical','publication_allowed':False}
    destination.with_suffix('.font_receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True)
    a=p.parse_args();print(json.dumps(normalize(a.source,a.destination),indent=2))
