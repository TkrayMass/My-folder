#!/usr/bin/env python3
"""Record technical status and retain QC evidence. Never publish or send mail."""
import argparse,csv,datetime,hashlib,json,re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

ERROR=re.compile(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:',re.M)
def digest(path):
    with path.open('rb') as f:
        h=hashlib.sha256()
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def finalize(run_id, sas_rc, log, output_root, audit_dir, program,output_format='xls'):
    if not re.fullmatch(r'[A-Za-z0-9_]{1,80}',run_id):raise ValueError('Invalid run ID')
    if output_format not in ('xls','xlsx'):raise ValueError('Invalid output format')
    log=Path(log);audit_dir=Path(audit_dir);output_dir=Path(output_root)/run_id
    audit_dir.mkdir(parents=True,exist_ok=True)
    failures=[]
    if sas_rc!=0:failures.append('SAS return code '+str(sas_rc))
    content=log.read_text(errors='replace') if log.is_file() else ''
    if not content:failures.append('Missing or empty SAS log')
    errors=ERROR.findall(content)
    if errors:failures.append('Actual SAS error lines found')
    markers=re.findall(r'^\s*NOTE: ACO_REBUILD_RUN_COMPLETE REPDT=(\d{8}) RUNID=([A-Za-z0-9_]+)\s*$',content,re.M)
    report_date=None
    if len(markers)!=1 or markers[0][1]!=run_id:failures.append('Missing, duplicate or mismatched completion marker')
    else:
        report_date=markers[0][0]
        try:datetime.datetime.strptime(report_date,'%Y%m%d')
        except ValueError:failures.append('Invalid report date')
    required=['QC_Current_Matrix.csv','QC_Check_Matrix.csv','QC_Summary.csv','Freshness.csv','TECHNICAL_COMPLETE.txt']
    if report_date:
        required += [f'ReportTestMonthly-{report_date}_REBUILD_{kind}.{output_format}' for kind in ('REGXSA','SASQA')]
    for name in required:
        p=output_dir/name
        if not p.is_file() or not p.stat().st_size:failures.append('Missing or empty '+name)
    if output_format=='xlsx' and report_date:
        expected={'REGXSA':['Summary','Summary-Enroll-Region','Summary-Caseload-Reg x SA','Summary-Enroll-Reg X SA','Summary-DisEnroll-Reg X SA','Caseload','Caseload-Reg X SA','Enrollment','Enrollment-Reg X SA','Disenrollment','Disenrollment_Reg X SA'],'SASQA':['QC_Summary','QC_Matrix','QC_Detail']}
        for kind,names in expected.items():
            p=output_dir/f'ReportTestMonthly-{report_date}_REBUILD_{kind}.xlsx'
            try:
                with zipfile.ZipFile(p) as z:
                    if z.testzip() is not None:raise ValueError('Corrupt ZIP member')
                    sheets=ET.fromstring(z.read('xl/workbook.xml')).find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}sheets')
                    if [s.attrib['name'] for s in sheets]!=names:raise ValueError('Worksheet names/order differ')
            except (OSError,ValueError,KeyError,zipfile.BadZipFile,ET.ParseError) as e:failures.append('Invalid XLSX '+kind+': '+str(e))
    qc={};completion={}
    try:
        with (output_dir/'QC_Summary.csv').open(newline='') as f:
            for r in csv.DictReader(f):
                if r['ITEM'] in qc:raise ValueError('Duplicate QC summary item')
                qc[r['ITEM']]=r['VALUE']
        for line in (output_dir/'TECHNICAL_COMPLETE.txt').read_text().splitlines():
            key,value=line.split('=',1)
            if key in completion:raise ValueError('Duplicate completion field')
            completion[key]=value
        if completion.get('RunID')!=run_id or completion.get('ReportDate')!=report_date:
            failures.append('Completion identity mismatch')
        if completion.get('QCStatus')!=qc.get('Technical QC Status') or completion.get('DistributionDecision')!=qc.get('Distribution Decision'):
            failures.append('QC decision disagreement')
        if qc.get('Technical QC Status') not in ('PASS','WARNING','FAIL','BASELINE_ONLY'):
            failures.append('Unrecognized QC status')
        if qc.get('Distribution Decision') not in ('READY TO DISTRIBUTE','REVIEW BEFORE DISTRIBUTION','DO NOT DISTRIBUTE'):
            failures.append('Unrecognized distribution decision')
    except (OSError,ValueError,KeyError) as e:failures.append('QC evidence incomplete: '+str(e))
    artifacts=[]
    paths=[log,Path(program)] if program else [log]
    if output_dir.is_dir():paths.extend(sorted(p for p in output_dir.iterdir() if p.is_file()))
    for p in paths:
        if p.is_file():
            try:artifacts.append({'path':str(p.resolve()),'bytes':p.stat().st_size,'sha256':digest(p)})
            except OSError as e:failures.append('Cannot hash '+str(p)+': '+str(e))
    result={'schema_version':1,'run_id':run_id,'report_date':report_date,'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'technical_status':'FAIL' if failures else 'PASS','sas_return_code':sas_rc,'failures':failures,'qc_status':qc.get('Technical QC Status','NOT_AVAILABLE'),'distribution_decision':qc.get('Distribution Decision','NOT_AVAILABLE'),'candidate_only':True,'publication_allowed':False,'artifacts':artifacts,'retention':'Keep log and available report/QC artifacts for every attempt, including FAIL; no cleanup performed.'}
    target=audit_dir/'RUN_MANIFEST.json'
    if target.exists():raise FileExistsError('Existing run manifest must not be overwritten')
    temporary=audit_dir/'RUN_MANIFEST.json.partial'
    temporary.write_text(json.dumps(result,indent=2)+'\n')
    temporary.replace(target)
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--run-id',required=True);p.add_argument('--sas-rc',required=True,type=int)
    p.add_argument('--log',required=True);p.add_argument('--output-root',required=True)
    p.add_argument('--audit-dir',required=True);p.add_argument('--program')
    p.add_argument('--output-format',choices=('xls','xlsx'),default='xls')
    a=p.parse_args();result=finalize(a.run_id,a.sas_rc,a.log,a.output_root,a.audit_dir,a.program,a.output_format)
    print(result['technical_status']+' '+str(Path(a.audit_dir)/'RUN_MANIFEST.json'))
    raise SystemExit(0 if result['technical_status']=='PASS' else 1)
