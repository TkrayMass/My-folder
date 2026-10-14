"""Formatting-only native report normalization, preserving raw SAS output.

Linux SAS aliases Arial and inserts line breaks into static ODSTEXT headings.
This patches the original XML byte ranges without reserializing namespaces.
No data values, formulas, cell styles, column widths or panes are changed.
"""
import argparse, hashlib, json, re, shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

X='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
NS={'s':X}

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()

def canonical(text):return ' '.join(text.split())

def normalize(source,destination,program,report_date):
    source=Path(source);destination=Path(destination)
    if destination.exists():raise FileExistsError(destination)
    code=Path(program).read_text()
    headings={}
    for m in re.finditer(r'^\s*p\s+("[^\"]*"|\'[^\']*\')\s*/\s*style=',code,re.M):
        literal=m.group(1)[1:-1].replace('&repdt.',report_date)
        if literal.strip() and '&' not in literal:headings[canonical(literal)]=literal
    if not any(k.startswith('Member caseload taken') for k in headings):raise ValueError('Missing static heading authority')
    changed=[];row_counts={}
    with ZipFile(source) as old:
        styles=old.read('xl/styles.xml').decode('utf-8')
        root=ET.fromstring(styles);fonts=root.find('s:fonts',NS);xfs=root.find('s:cellXfs',NS)
        fills=root.find('s:fills',NS)
        bluefills={i for i,f in enumerate(fills) if any(c.get('rgb','').upper().endswith('0000FF') for c in f.iter())}
        bold={i for i,f in enumerate(fonts) if f.find('s:b',NS) is not None}
        m=re.search(r'(<fonts\b[^>]*>)(.*?)(</fonts>)',styles,re.S)
        if not m:raise ValueError('Unexpected font schema')
        fontblock,names=re.subn(r'(<name\b[^>]*\bval=")[^"]*(")',r'\g<1>Arial\2',m.group(2))
        fontblock,sizes=re.subn(r'(<sz\b[^>]*\bval=")[^"]*(")',r'\g<1>11\2',fontblock)
        if names!=len(fonts) or sizes!=len(fonts):raise ValueError('Font normalization count differs')
        styles=styles[:m.start(2)]+fontblock+styles[m.end(2):]
        # ODSTEXT notes use an unbordered bold paragraph style. Removing SAS's
        # hard returns alone does not disable Excel's own wrapping in column A.
        paragraph_styles={i for i,xf in enumerate(xfs)
            if int(xf.get('fontId','0')) in bold
            and xf.get('fillId','0')=='0' and xf.get('borderId','0')=='0'
            and xf.get('numFmtId','0')=='0'
            and xf.find('s:alignment',NS) is not None
            and xf.find('s:alignment',NS).get('horizontal')=='left'}
        styleblock=re.search(r'(<cellXfs\b[^>]*>)(.*?)(</cellXfs>)',styles,re.S)
        if not styleblock:raise ValueError('Missing cell styles')
        xfblocks=list(re.finditer(r'<xf\b[^>]*>.*?</xf>|<xf\b[^>]*/>',styleblock.group(2),re.S))
        if len(xfblocks)!=len(xfs):raise ValueError('Cell style schema differs')
        content=styleblock.group(2)
        for i in sorted(paragraph_styles,reverse=True):
            b=xfblocks[i]
            corrected=re.sub(r'\bwrapText="1"','wrapText="0"',b.group())
            content=content[:b.start()]+corrected+content[b.end():]
        styles=styles[:styleblock.start(2)]+content+styles[styleblock.end(2):]
        raw=old.read('xl/sharedStrings.xml').decode('utf-8');stringsroot=ET.fromstring(raw)
        strings=[''.join(si.itertext()) for si in stringsroot]
        blocks=list(re.finditer(r'<si\b[^>]*>.*?</si>',raw,re.S))
        if len(blocks)!=len(strings):raise ValueError('Unexpected shared string schema')
        for i in reversed(range(len(strings))):
            text=strings[i];expected=headings.get(canonical(text))
            if expected is None or text==expected:continue
            # Literal heading is a single SAS-generated text node, not rich text.
            tnodes=list(stringsroot[i].findall('s:t',NS))
            if len(tnodes)!=1:raise ValueError('Unexpected rich-text heading')
            b=blocks[i]
            replacement=re.sub(r'(<t\b[^>]*>)(.*?)(</t>)',lambda t:t.group(1)+t.group(2).replace('\n',' ')+t.group(3),b.group(),flags=re.S)
            parsed=ET.fromstring('<root xmlns="'+X+'">'+replacement+'</root>')
            if canonical(''.join(parsed.itertext()))!=canonical(expected):raise ValueError('Heading wording changed')
            raw=raw[:b.start()]+replacement+raw[b.end():]
            changed.append(i)
        finalstrings=[''.join(si.itertext()) for si in ET.fromstring(raw)]
        if len(finalstrings)!=len(strings):raise ValueError('Shared string count changed')
        for i,(a,b) in enumerate(zip(strings,finalstrings)):
            if i not in changed and a!=b:raise ValueError('Unexpected report text change')
        with destination.open('xb') as f,ZipFile(f,'w',ZIP_DEFLATED) as new:
            for info in old.infolist():
                name=info.filename
                if name=='xl/styles.xml':new.writestr(info,styles.encode('utf-8'));continue
                if name=='xl/sharedStrings.xml':new.writestr(info,raw.encode('utf-8'));continue
                if re.fullmatch(r'xl/worksheets/sheet\d+\.xml',name):
                    sheet=old.read(name).decode('utf-8');tree=ET.fromstring(sheet)
                    heights={};previous_header=False
                    for row in tree.findall('s:sheetData/s:row',NS):
                        cells=row.findall('s:c',NS)
                        isheader=any(int(xfs[int(c.get('s','0'))].get('fillId','0')) in bluefills for c in cells)
                        istotal=any(c.get('t') not in ('s','inlineStr') and c.find('s:v',NS) is not None and int(xfs[int(c.get('s','0'))].get('fontId','0')) in bold for c in cells)
                        heights[int(row.get('r'))]=36 if istotal or (isheader and previous_header) else 18
                        previous_header=isheader
                    def height(m):
                        tag=m.group();r=int(re.search(r'\br="(\d+)"',tag).group(1))
                        closing='/>' if tag.endswith('/>') else '>'
                        tag=re.sub(r'\s(?:ht|customHeight)="[^"]*"','',tag)
                        return tag[:-len(closing)]+' ht="'+str(heights[r])+'" customHeight="1"'+closing
                    sheet=re.sub(r'<row\b[^>]*>',height,sheet)
                    after=ET.fromstring(sheet)
                    # Row-only edits must leave all cell XML identical.
                    beforecells=tree.findall('s:sheetData/s:row/s:c',NS)
                    aftercells=after.findall('s:sheetData/s:row/s:c',NS)
                    if len(beforecells)!=len(aftercells) or any(ET.tostring(a)!=ET.tostring(b) for a,b in zip(beforecells,aftercells)):raise ValueError('Report cell content changed')
                    row_counts[name]=len(heights);new.writestr(info,sheet.encode('utf-8'))
                else:
                    with old.open(name) as inp,new.open(info,'w') as out:shutil.copyfileobj(inp,out,1048576)
    with ZipFile(source) as old,ZipFile(destination) as new:
        if old.namelist()!=new.namelist() or new.testzip() is not None:raise ValueError('ZIP verification failed')
        for name in old.namelist():
            if name not in ('xl/styles.xml','xl/sharedStrings.xml') and name not in row_counts:
                if old.read(name)!=new.read(name):raise ValueError('Unrelated package member changed')
    receipt={'source_sha256':digest(source),'result_sha256':digest(destination),
             'authority_program_sha256':digest(program),'report_date':report_date,
             'changed_static_heading_indices':sorted(changed),'worksheet_rows':row_counts,
             'unwrapped_paragraph_styles':sorted(paragraph_styles),
             'worksheet_cells_identical':True,'publication_allowed':False}
    destination.with_suffix('.format_receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True);p.add_argument('--program',required=True);p.add_argument('--report-date',required=True)
    a=p.parse_args();print(json.dumps(normalize(a.source,a.destination,a.program,a.report_date),indent=2))
