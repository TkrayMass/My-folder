"""Disable wrapping only for the unbordered bold introductory paragraph styles."""
import argparse,hashlib,json,re,shutil,xml.etree.ElementTree as E
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()

def fix(source,destination,expected):
    source=Path(source);destination=Path(destination)
    if sha(source)!=expected:raise ValueError('Completed report hash differs')
    if destination.exists():raise FileExistsError(destination)
    ns={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    with ZipFile(source) as old:
        original=old.read('xl/styles.xml').decode('utf-8');root=E.fromstring(original)
        fonts=root.find('s:fonts',ns);xfs=root.find('s:cellXfs',ns)
        bold={i for i,f in enumerate(fonts) if f.find('s:b',ns) is not None}
        ids={i for i,xf in enumerate(xfs) if int(xf.get('fontId','0')) in bold and xf.get('fillId','0')=='0' and xf.get('borderId','0')=='0' and xf.get('numFmtId','0')=='0' and xf.find('s:alignment',ns) is not None and xf.find('s:alignment',ns).get('horizontal')=='left'}
        m=re.search(r'(<cellXfs\b[^>]*>)(.*?)(</cellXfs>)',original,re.S)
        blocks=list(re.finditer(r'<xf\b[^>]*>.*?</xf>|<xf\b[^>]*/>',m.group(2),re.S))
        if len(blocks)!=len(xfs):raise ValueError('Style schema differs')
        content=m.group(2)
        for i in sorted(ids,reverse=True):
            b=blocks[i];content=content[:b.start()]+re.sub(r'\bwrapText="1"','wrapText="0"',b.group())+content[b.end():]
        corrected=original[:m.start(2)]+content+original[m.end(2):]
        E.fromstring(corrected)
        with destination.open('xb') as f,ZipFile(f,'w',ZIP_DEFLATED) as new:
            for info in old.infolist():
                if info.filename=='xl/styles.xml':new.writestr(info,corrected.encode('utf-8'))
                else:
                    with old.open(info.filename) as inp,new.open(info,'w') as out:shutil.copyfileobj(inp,out,1048576)
    with ZipFile(source) as old,ZipFile(destination) as new:
        if new.testzip() is not None:raise ValueError('ZIP corruption')
        for name in old.namelist():
            if name=='xl/styles.xml':continue
            with old.open(name) as a,new.open(name) as b:
                while True:
                    ca=a.read(1048576);cb=b.read(1048576)
                    if ca!=cb:raise ValueError('Report content changed')
                    if not ca:break
    result={'source_sha256':expected,'result_sha256':sha(destination),'unwrapped_paragraph_styles':sorted(ids),'all_nonstyle_members_identical':True,'publication_allowed':False}
    destination.with_suffix('.notes_receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True);p.add_argument('--expected-sha256',required=True)
    a=p.parse_args();print(json.dumps(fix(a.source,a.destination,a.expected_sha256),indent=2))
