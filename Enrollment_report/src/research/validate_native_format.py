"""Read-only comparison of native report width/pane metadata to its reference."""
import argparse, hashlib, json, posixpath, xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile
X='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
R='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
def validate(report,reference,manifest):
    report=Path(report);reference=Path(reference);manifest=Path(manifest)
    run=json.loads(manifest.read_text())
    expected=[a for a in run['artifacts'] if Path(a['path']).name==report.name]
    h=hashlib.sha256()
    with report.open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    if run['technical_status']!='PASS' or len(expected)!=1 or expected[0]['sha256']!=h.hexdigest():raise ValueError('Completed report hash required')
    profiles=json.loads(reference.read_text())['sheets'];checks=[]
    with ZipFile(report) as z:
        relations={r.get('Id'):r.get('Target') for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        sheets=ET.fromstring(z.read('xl/workbook.xml')).find('{'+X+'}sheets')
        if [s.get('name') for s in sheets]!=[s['sheet'] for s in profiles]:raise ValueError('Sheet order differs')
        for s,p in zip(sheets,profiles):
            target=relations[s.get('{'+R+'}id')]
            entry=target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/'+target)
            pane=None;cols=[]
            with z.open(entry) as f:
                for event,e in ET.iterparse(f,events=('start',)):
                    if e.tag=='{'+X+'}pane':pane=dict(e.attrib)
                    elif e.tag=='{'+X+'}col':cols.append(dict(e.attrib))
                    elif e.tag=='{'+X+'}sheetData':break
            frozen=int(p['pane'].get('ySplit','0')) if p['pane'] else 0
            frozen=3 if frozen>1 else frozen
            actual_frozen=int(float(pane.get('ySplit','0'))) if pane else 0
            if actual_frozen!=frozen:raise ValueError('Freeze mismatch: '+p['sheet'])
            if pane and float(pane.get('xSplit','0'))!=0:raise ValueError('Unexpected frozen columns')
            worst=0
            for c in cols:
                for i in range(int(c['min']),int(c['max'])+1):
                    old=[q for q in p['columns'] if int(q['min'])<=i<=int(q['max'])]
                    if not old:old=[max(p['columns'],key=lambda q:int(q['max']))]
                    difference=abs(float(c['width'])-float(old[0]['width']))
                    worst=max(worst,difference)
                    if difference>0.02:raise ValueError('Column width mismatch: '+p['sheet']+' column '+str(i))
            checks.append({'sheet':p['sheet'],'freeze_rows':frozen,'largest_width_difference_characters':worst})
    return {'run_id':run['run_id'],'format_metadata_status':'PASS','report_sha256':h.hexdigest(),'checks':checks,'limitations':['Pane and column-width metadata verified; full visual layout/row-height acceptance remains separate.'],'publication_allowed':False}
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('report','reference','manifest'):p.add_argument('--'+key,required=True)
    a=p.parse_args();print(json.dumps(validate(a.report,a.reference,a.manifest),indent=2))
