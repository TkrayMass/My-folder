#!/usr/bin/env python3
"""Assemble a candidate QC decision; required unchecked controls remain visible."""
import argparse,datetime,hashlib,json
from pathlib import Path

REQUIRED=('workbook_structure','upstream_totals','row_preservation','percentage_denominators','detail_reconciliation','cross_sheet_reconciliation','baseline_business_policy')
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
def finalize(manifest_path,comparison_dir,checks_path,destination):
    manifest_path=Path(manifest_path);comparison_dir=Path(comparison_dir);destination=Path(destination)
    run=json.loads(manifest_path.read_text());rid=run['run_id'];checks=[]
    checks.append({'check':'technical_completion','status':'PASS' if run['technical_status']=='PASS' else 'FAIL','evidence_sha256':sha(manifest_path)})
    comparison_file=comparison_dir/'BASELINE_COMPARISON.json'
    if comparison_file.is_file():
        comp=json.loads(comparison_file.read_text());csvpath=comparison_dir/'Distributed_Baseline_Comparison.csv'
        valid=comp.get('run_id')==rid and comp.get('run_manifest_sha256')==sha(manifest_path) and csvpath.is_file() and comp.get('comparison_sha256')==sha(csvpath)
        checks.append({'check':'baseline_comparison_identity','status':'PASS' if valid else 'FAIL','evidence_sha256':sha(comparison_file)})
    else:checks.append({'check':'baseline_comparison_identity','status':'NOT_RUN'})
    controls={}
    if checks_path and Path(checks_path).is_file():
        p=Path(checks_path);doc=json.loads(p.read_text())
        if doc.get('run_id')!=rid:raise ValueError('Business checks belong to another run')
        if doc.get('run_manifest_sha256')!=sha(manifest_path):raise ValueError('Business checks belong to another manifest version')
        reports=[a for a in run.get('artifacts',[]) if Path(a['path']).name.endswith(('_REGXSA.xlsx','_REGXSA.xls'))]
        if len(reports)!=1 or doc.get('report_sha256')!=reports[0]['sha256']:raise ValueError('Business checks belong to another report version')
        for c in doc['checks']:
            if c['check'] in controls:raise ValueError('Duplicate check ID')
            status=c['status']
            if status not in ('PASS','REVIEW','FAIL','NOT_RUN'):raise ValueError('Unrecognized check status')
            if status!='NOT_RUN':
                if not c.get('evidence'):raise ValueError('Completed check lacks evidence')
                for artifact in c['evidence']:
                    relative=Path(artifact['name'])
                    if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid evidence path')
                    evidence=p.parent/relative
                    if sha(evidence)!=artifact['sha256']:raise ValueError('Check evidence hash mismatch')
            controls[c['check']]=c
    for name in REQUIRED:checks.append(controls.get(name,{'check':name,'status':'NOT_RUN'}))
    failed=[c['check'] for c in checks if c['status']=='FAIL'];missing=[c['check'] for c in checks if c['status']=='NOT_RUN'];reviews=[c['check'] for c in checks if c['status']=='REVIEW']
    decision='FAIL' if failed or missing else 'REVIEW' if reviews else 'PASS'
    result={'schema_version':1,'run_id':rid,'report_date':run['report_date'],'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'final_qc_decision':decision,'qc_complete':not missing,'failed_checks':failed,'not_run_checks':missing,'review_checks':reviews,'checks':checks,'candidate_only':True,'publication_allowed':False,'policy':'Required FAIL or NOT_RUN blocks release; REVIEW remains visible. Candidate publication is disabled even if all controls pass.'}
    destination.mkdir(parents=True,exist_ok=True);target=destination/'FINAL_QC.json'
    if target.exists():raise FileExistsError('Do not overwrite finalized evidence; use a new finalization version')
    tmp=destination/'FINAL_QC.json.partial';tmp.write_text(json.dumps(result,indent=2)+'\n');tmp.replace(target)
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-manifest',required=True);p.add_argument('--comparison-dir',required=True);p.add_argument('--checks');p.add_argument('--destination',required=True)
    a=p.parse_args();r=finalize(a.run_manifest,a.comparison_dir,a.checks,a.destination)
    print('FINAL_QC='+r['final_qc_decision']+' COMPLETE='+str(r['qc_complete']))
    raise SystemExit(0 if r['qc_complete'] and r['final_qc_decision']!='FAIL' else 2)
