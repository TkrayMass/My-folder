"""Verify a published XLSX against the immutable release, allowing XML reserialization."""
import argparse,datetime,itertools,json,os,posixpath
from decimal import Decimal
from pathlib import Path
from zipfile import ZipFile
import xml.etree.ElementTree as ET
from check_transfer_gate import digest

M='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
POLICY='enrollment_content_v1'

class Report:
    def __init__(self,path):
        self.z=ZipFile(path);self.strings=[]
        if 'xl/sharedStrings.xml' in self.z.namelist():
            with self.z.open('xl/sharedStrings.xml') as f:
                for _,e in ET.iterparse(f,events=('end',)):
                    if e.tag==M+'si':
                        self.strings.append(''.join(t.text or '' for t in e.iter(M+'t')));e.clear()
        relations=ET.fromstring(self.z.read('xl/_rels/workbook.xml.rels'))
        targets={e.get('Id'):e.get('Target').lstrip('/') if e.get('Target').startswith('/') else posixpath.normpath(posixpath.join('xl',e.get('Target'))) for e in relations}
        wb=ET.fromstring(self.z.read('xl/workbook.xml'))
        self.sheets=[(e.get('name'),targets[e.get(R+'id')],e.get('state','visible')) for e in wb.find(M+'sheets')]
        self.date_system=wb.find(M+'workbookPr')
        self.date_system=self.date_system.get('date1904','0') if self.date_system is not None else '0'
        self.names=sorted((e.get('name'),e.get('localSheetId'),e.text or '') for e in wb.findall(M+'definedNames/'+M+'definedName') if not e.get('name','').startswith('_xlnm.Print_'))
    def rows(self,path,structure):
        structure.update({'merges':set(),'panes':[]})
        with self.z.open(path) as f:
            for _,e in ET.iterparse(f,events=('end',)):
                if e.tag==M+'mergeCell':structure['merges'].add(e.get('ref'))
                elif e.tag==M+'pane':structure['panes'].append((e.get('xSplit','0'),e.get('ySplit','0'),e.get('topLeftCell','A1'),e.get('state','split')))
                elif e.tag==M+'row':
                    cells={}
                    for c in e.findall(M+'c'):
                        typ=c.get('t','n');v=c.findtext(M+'v');formula=c.find(M+'f')
                        if typ=='s':value=('text',self.strings[int(v)].strip()) if v is not None else ('blank','')
                        elif typ=='inlineStr':value=('text',''.join(t.text or '' for t in c.iter(M+'t')).strip())
                        elif typ in ('str','e','b','d'):value=(typ,v or '')
                        elif v is not None:value=('number',v)
                        else:value=('blank','')
                        if formula is not None:value=('formula',formula.text or '',tuple(sorted(formula.attrib.items())),value)
                        if value in (('text',''),('blank','')):continue
                        cells[c.get('r')]=value
                    row=int(e.get('r'));e.clear()
                    if cells:yield row,cells
    def close(self):self.z.close()

def same_value(a,b):
    if a==b:return True
    if a is None or b is None or a[0]!=b[0]:return False
    if a[0]=='number':
        # Only storage noise: no whole-count or four-decimal rate rounding allowance.
        x,y=Decimal(a[1]),Decimal(b[1])
        if not x.is_finite() or not y.is_finite():return False
        tolerance=Decimal('0.000000000000001') if abs(x)<=1 else Decimal('0.000000001')
        return abs(x-y)<=tolerance
    if a[0]=='formula':return a[1:3]==b[1:3] and same_value(a[3],b[3])
    return False

def verify(source,published,expected,run_id,report_date,output):
    source,published,output=map(Path,(source,published,output))
    source_hash,published_hash=digest(source),digest(published)
    if source_hash!=expected.lower():raise ValueError('Immutable release source checksum differs')
    result={'schema_version':1,'policy':POLICY,'run_id':run_id,'report_date':report_date,
            'source_sha256':source_hash,'published_sha256':published_hash,
            'verified_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'source_path':str(source),'published_path':str(published),
            'status':'PASS','differences':0,'method':'SHA256','sheets':[]}
    if published_hash!=source_hash:
        a,b=Report(source),Report(published)
        try:
            if [(n,s) for n,_,s in a.sheets]!=[(n,s) for n,_,s in b.sheets]:raise ValueError('Worksheet names, order, or visibility changed')
            if a.date_system!=b.date_system or a.names!=b.names:raise ValueError('Workbook date system or defined names changed')
            result['method']='CONTENT'
            for (name,pa,_),(_,pb,_) in zip(a.sheets,b.sheets):
                sa,sb={},{};ia,ib=iter(a.rows(pa,sa)),iter(b.rows(pb,sb))
                ra,rb=next(ia,None),next(ib,None);checked=0
                while ra is not None or rb is not None:
                    if rb is None or (ra is not None and ra[0]<rb[0]):ca,cb=ra[1],{};ra=next(ia,None)
                    elif ra is None or rb[0]<ra[0]:ca,cb={},rb[1];rb=next(ib,None)
                    else:ca,cb=ra[1],rb[1];ra,rb=next(ia,None),next(ib,None)
                    for address in ca.keys()|cb.keys():
                        if not same_value(ca.get(address),cb.get(address)):raise ValueError('Report content changed at '+name+'!'+address)
                        checked+=1
                if sa!=sb:raise ValueError('Merged ranges or frozen panes changed: '+name)
                result['sheets'].append({'name':name,'checked_cells':checked,'differences':0})
                print('CONTENT VERIFIED '+name,flush=True)
        finally:a.close();b.close()
    if digest(source)!=source_hash or digest(published)!=published_hash:raise ValueError('Report changed during verification; retry with stable files')
    temporary=output.with_suffix('.partial');temporary.write_text(json.dumps(result,indent=2)+'\n')
    os.replace(str(temporary),str(output))
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('source','published','expected-sha256','run-id','report-date','output'):p.add_argument('--'+key,required=True)
    a=p.parse_args()
    print(json.dumps(verify(a.source,a.published,a.expected_sha256,a.run_id,a.report_date,a.output),indent=2))
