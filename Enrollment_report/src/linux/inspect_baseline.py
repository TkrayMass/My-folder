from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET
import json
import re
import argparse

parser=argparse.ArgumentParser()
parser.add_argument('--source',default=r'C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report\ReportTestMonthly-20261007_REGXSA.xlsx')
parser.add_argument('--folder',default=str(Path(__file__).parent/'Validation'/'20261013'))
args=parser.parse_args()
p = Path(args.source)
ns = {'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
with zipfile.ZipFile(p) as z:
    strings = []
    if 'xl/sharedStrings.xml' in z.namelist():
        for _, elem in ET.iterparse(z.open('xl/sharedStrings.xml'), events=('end',)):
            if elem.tag.endswith('}si'):
                strings.append(''.join(t.text or '' for t in elem.iter() if t.tag.endswith('}t')))
                elem.clear()
    rels = {r.attrib['Id']:r.attrib['Target'] for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
    sheets = []
    for s in ET.fromstring(z.read('xl/workbook.xml')).find('m:sheets',ns):
        target = rels[s.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
        member = target.lstrip('/') if target.startswith('/') else 'xl/' + target
        rows=[]
        for _, elem in ET.iterparse(z.open(member), events=('end',)):
            if elem.tag.endswith('}row'):
                cells=[]
                for c in elem:
                    v=c.find('m:v',ns)
                    value=v.text if v is not None else ''
                    if c.attrib.get('t')=='s': value=strings[int(value)]
                    elif c.attrib.get('t')=='inlineStr': value=''.join(c.itertext())
                    if value: cells.append([c.attrib.get('r'),value])
                rows.append(cells)
                elem.clear()
                if len(rows)>=(220 if s.attrib['name']=='Summary' else 12): break
        sheets.append({'name':s.attrib['name'],'member':member,'first_rows':rows})
    out=Path(args.folder)/'baseline_structure.json'
    out.write_text(json.dumps(sheets,indent=2))
    for s in sheets:
        print(s['name'])
        if s['name']=='Summary':
            for row in s['first_rows']:
                labels=[c for c in row if re.match(r'^[ABC]\d+$',c[0])]
                if labels: print(json.dumps(labels))
