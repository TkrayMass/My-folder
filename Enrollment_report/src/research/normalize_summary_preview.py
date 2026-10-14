"""Fix only static Summary note line breaks and match reference row heights.

Formatting-only preview utility. Preserves namespace bytes and numeric cells.
The input must already have Arial normalization applied.
"""
import argparse, hashlib, json, re
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

NS={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
PREFIXES=('Member caseload taken from state eligibility',
          'Member enrollment and disenrollment taken from enrollment table')

def fix(source,destination):
    source=Path(source); destination=Path(destination)
    if destination.exists(): raise FileExistsError(destination)
    with ZipFile(source) as zin:
        raw=zin.read('xl/sharedStrings.xml').decode('utf-8')
        root=ET.fromstring(raw)
        indices=[]
        for i,si in enumerate(root):
            text=''.join(si.itertext())
            if text.replace('\n',' ').startswith(PREFIXES):
                indices.append(i)
        if len(indices)!=2: raise ValueError('Expected exactly two static Summary notes')
        blocks=list(re.finditer(r'<si\b[^>]*>.*?</si>',raw,re.S))
        for i in reversed(indices):
            m=blocks[i]; block=m.group()
            block=re.sub(r'(<t\b[^>]*>)(.*?)(</t>)',lambda t:t.group(1)+t.group(2).replace('\n',' ')+t.group(3),block,flags=re.S)
            raw=raw[:m.start()]+block+raw[m.end():]
        patched=ET.fromstring(raw)
        for i,(old,new) in enumerate(zip(root,patched)):
            expected=''.join(old.itertext()).replace('\n',' ') if i in indices else ''.join(old.itertext())
            if ''.join(new.itertext())!=expected: raise ValueError('Unexpected text change')
        sheet=zin.read('xl/worksheets/sheet1.xml').decode('utf-8')
        # Published Summary has ordinary 18pt intro/detail, 18pt spanning header,
        # 36pt column header and 36pt subtotal. Limit to its first displayed block.
        def rowheight(m):
            tag=m.group(); r=int(re.search(r'\br="(\d+)"',tag).group(1))
            if r>15:return tag
            height=36 if r in (10,15) else 18
            tag=re.sub(r'\sht="[^"]*"','',tag)
            tag=re.sub(r'\scustomHeight="[^"]*"','',tag)
            closing='/>' if tag.endswith('/>') else '>'
            return tag[:-len(closing)]+' ht="'+str(height)+'" customHeight="1"'+closing
        sheet=re.sub(r'<row\b[^>]*>',rowheight,sheet)
        before=ET.fromstring(zin.read('xl/worksheets/sheet1.xml'))
        after=ET.fromstring(sheet)
        oldcells=[ET.tostring(c) for c in before.findall('s:sheetData/s:row/s:c',NS)]
        newcells=[ET.tostring(c) for c in after.findall('s:sheetData/s:row/s:c',NS)]
        if oldcells!=newcells:raise ValueError('Worksheet cell content changed')
        with destination.open('xb') as f,ZipFile(f,'w',ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data=raw.encode('utf-8') if item.filename=='xl/sharedStrings.xml' else sheet.encode('utf-8') if item.filename=='xl/worksheets/sheet1.xml' else zin.read(item.filename)
                zout.writestr(item,data)
    with ZipFile(source) as old,ZipFile(destination) as new:
        if new.testzip() is not None:raise ValueError('ZIP integrity failure')
        for name in old.namelist():
            if name not in ('xl/sharedStrings.xml','xl/worksheets/sheet1.xml') and old.read(name)!=new.read(name):raise ValueError('Unexpected package change')
    result={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
            'result_sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),
            'changed_note_indices':indices,'worksheet_cells_identical':True,
            'publication_allowed':False,'scope':'Summary-only review preview'}
    destination.with_suffix('.layout_receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True)
    a=p.parse_args();print(json.dumps(fix(a.source,a.destination),indent=2))
