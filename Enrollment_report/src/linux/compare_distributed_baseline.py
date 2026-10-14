#!/usr/bin/env python3
"""Create keyed comparison evidence; never authorize publication."""
import argparse,csv,datetime,hashlib,json
from pathlib import Path
from decimal import Decimal
from collections import Counter

KEY=('REPORT_SECTION','CATEGORY','PLAN_TYPE','MONTH_ID')
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for part in iter(lambda:f.read(1024*1024),b''):h.update(part)
    return h.hexdigest()
def read_matrix(path):
    result={}
    with path.open(newline='',encoding='utf-8-sig') as f:
        for r in csv.DictReader(f):
            key=tuple(r[x] for x in KEY)
            if key in result:raise ValueError('Duplicate matrix key '+str(key))
            value=Decimal(r['MBRS'].replace(',',''))
            if not value.is_finite():raise ValueError('Non-finite matrix value')
            result[key]=value
    if not result:raise ValueError('Empty matrix')
    return result
def compare(baseline_dir,candidate_dir,run_manifest_path,destination):
    baseline_dir=Path(baseline_dir);candidate_dir=Path(candidate_dir);destination=Path(destination)
    baseline_manifest_path=baseline_dir/'BASELINE_MANIFEST.json'
    baseline=json.loads(baseline_manifest_path.read_text())
    run_manifest_path=Path(run_manifest_path);run=json.loads(run_manifest_path.read_text())
    if run.get('technical_status')!='PASS':raise ValueError('Candidate has no technical PASS')
    if not baseline['report_date']<run['report_date']:raise ValueError('Baseline must predate candidate report')
    for a in baseline['artifacts']:
        if Path(a['name']).name!=a['name']:raise ValueError('Invalid baseline artifact name')
        p=baseline_dir/a['name']
        if p.stat().st_size!=a['bytes'] or sha(p)!=a['sha256']:raise ValueError('Baseline hash mismatch: '+a['name'])
    current_path=candidate_dir/'QC_Current_Matrix.csv'
    current_artifacts=[a for a in run['artifacts'] if Path(a['path']).name=='QC_Current_Matrix.csv']
    if len(current_artifacts)!=1 or sha(current_path)!=current_artifacts[0]['sha256']:raise ValueError('Run matrix hash mismatch')
    before=read_matrix(baseline_dir/'Distributed_Baseline_Matrix.csv');after=read_matrix(current_path)
    month=run['report_date'][:6]+'01';rows=[]
    for k in sorted(set(before)|set(after)):
        old=before.get(k);new=after.get(k)
        delta=new-old if old is not None and new is not None else None
        if old is None:status='NEW_KEY'
        elif new is None:status='MISSING_KEY'
        else:status='MATCH' if delta==0 else 'CHANGED'
        row=dict(zip(KEY,k));row.update(BASELINE_MBRS=str(old) if old is not None else '',CURRENT_MBRS=str(new) if new is not None else '',DIFFERENCE=str(delta) if delta is not None else '',PERIOD_GROUP='CURRENT_MTD' if k[-1]==month else 'HISTORICAL',COMPARISON=status)
        rows.append(row)
    destination.mkdir(parents=True,exist_ok=True)
    if (destination/'BASELINE_COMPARISON.json').exists() or (destination/'Distributed_Baseline_Comparison.csv').exists():raise FileExistsError('Do not overwrite existing comparison evidence')
    csvpath=destination/'Distributed_Baseline_Comparison.csv'
    with csvpath.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    summary={'schema_version':1,'run_id':run['run_id'],'report_date':run['report_date'],'baseline_id':baseline['baseline_id'],'baseline_report_date':baseline['report_date'],'baseline_manifest_sha256':sha(baseline_manifest_path),'run_manifest_sha256':sha(run_manifest_path),'comparison_sha256':sha(csvpath),'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'comparison_status':'COMPLETE','historical':dict(Counter(r['COMPARISON'] for r in rows if r['PERIOD_GROUP']=='HISTORICAL')),'current_mtd':dict(Counter(r['COMPARISON'] for r in rows if r['PERIOD_GROUP']=='CURRENT_MTD')),'publication_allowed':False,'limitations':baseline['limitations']+['Evidence comparison covers five total-category series; does not implement the complete business-QC policy or authorize distribution.']}
    (destination/'BASELINE_COMPARISON.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary
if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--baseline-dir',required=True);p.add_argument('--candidate-dir',required=True)
    p.add_argument('--run-manifest',required=True);p.add_argument('--destination',required=True)
    a=p.parse_args();s=compare(a.baseline_dir,a.candidate_dir,a.run_manifest,a.destination)
    print(json.dumps(s,indent=2))
