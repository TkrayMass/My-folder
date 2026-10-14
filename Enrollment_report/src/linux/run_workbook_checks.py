#!/usr/bin/env python3
"""Check existing run workbook and finalize seven hash-linked business controls."""
import argparse,csv,datetime,hashlib,json,subprocess,sys
from pathlib import Path
from decimal import Decimal
from adaptive_qc_policy import load_history,thresholds

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()
def main(a):
    manifest_path=Path(a.run_manifest);run=json.loads(manifest_path.read_text())
    baseline_dir=Path(a.baseline_dir);base=json.loads((baseline_dir/'BASELINE_MANIFEST.json').read_text())
    report=Path(a.report);dest=Path(a.destination);source_checks=Path(a.source_checks)
    if run['technical_status']!='PASS':raise ValueError('Technical run failed')
    source=json.loads(source_checks.read_text())
    if source['run_id']!=run['run_id'] or source['run_manifest_sha256']!=sha(manifest_path):raise ValueError('Source controls belong to a different run')
    for c in source['checks']:
        for e in c['evidence']:
            if sha(source_checks.parent/e['name'])!=e['sha256']:raise ValueError('Source evidence changed')
    artifacts=[r for r in run['artifacts'] if Path(r['path']).name==report.name]
    if len(artifacts)!=1 or sha(report)!=artifacts[0]['sha256']:raise ValueError('Workbook hash differs from completed run')
    for e in base['artifacts']:
        if sha(baseline_dir/e['name'])!=e['sha256']:raise ValueError('Baseline archive changed')
    baseline_reports=[e for e in base['artifacts'] if e['name'].endswith('_REGXSA.xlsx')]
    if len(baseline_reports)!=1:raise ValueError('Baseline report ambiguous')
    if dest.exists():raise FileExistsError('Use a new evidence version')
    dest.mkdir(parents=True)
    scripts=Path(__file__).parent
    jobs=[('inspect_baseline.py',['--source',str(baseline_dir/baseline_reports[0]['name']),'--folder',str(dest)]),('validate_workbook.py',['--report',str(report),'--folder',str(dest)]),('validate_detail.py',['--report',str(report),'--folder',str(dest)]),('validate_cross_sheet.py',['--folder',str(dest)])]
    for script,args in jobs:
        print('Checking '+script,flush=True)
        with (dest/(script+'.log')).open('w') as f:
            subprocess.run([sys.executable,str(scripts/script)]+args,stdout=f,stderr=subprocess.STDOUT,check=True)
    if sha(report)!=artifacts[0]['sha256']:raise ValueError('Workbook changed during checks')
    structure=json.loads((dest/'workbook_validation_summary.json').read_text())
    detail=json.loads((dest/'detail_validation_summary.json').read_text())
    cross=json.loads((dest/'cross_sheet_validation_summary.json').read_text())
    records=[]
    history=load_history(baseline_dir)
    with (dest/'Summary_All_Category_Comparison.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            y=int(run['report_date'][:4]);m=int(run['report_date'][4:6]);current=f'{y:04d}{m:02d}01';previous=f'{y-1:04d}1201' if m==1 else f'{y:04d}{m-1:02d}01'
            group='CURRENT_MTD' if r['MONTH_ID']==current else 'PREVIOUS_MONTH' if r['MONTH_ID']==previous else 'OLDER_MONTH'
            warning=15000 if group=='CURRENT_MTD' and r['REPORT_SECTION']=='CASELOAD' else 25000 if group=='CURRENT_MTD' else 5000 if group=='PREVIOUS_MONTH' else 50
            fail=30000 if group=='CURRENT_MTD' and r['REPORT_SECTION']=='CASELOAD' else 50000 if group=='CURRENT_MTD' else 15000 if group=='PREVIOUS_MONTH' else 500 if r['REPORT_SECTION']=='CASELOAD' else 100
            pairs=history.get((r['REPORT_SECTION'],r['CATEGORY'],group),[])
            warning,fail,adaptive=thresholds(pairs,warning,fail)
            old=Decimal(r['BASELINE']) if r['BASELINE'] else None;new=Decimal(r['CANDIDATE']);diff=new-old if old is not None else None
            if old is None:status='REVIEW' if group=='CURRENT_MTD' else 'FAIL'
            elif group=='CURRENT_MTD':status='REVIEW' if (old==0 and new>0) or (old>0 and new==0) or abs(diff)>=warning else 'PASS'
            elif (old==0 and new>0) or (old>0 and new==0) or abs(diff)>=fail:status='FAIL'
            elif abs(diff)>=warning:status='REVIEW'
            else:status='PASS'
            records.append(dict(r,MONTH_GROUP=group,WARNING_THRESHOLD=str(warning),FAIL_THRESHOLD=str(fail),POLICY_STATUS=status,HISTORY_PAIR_COUNT=len(pairs),ADAPTIVE_APPLIED=adaptive))
    with (dest/'Baseline_Policy.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(records[0]));w.writeheader();w.writerows(records)
    policy={'method':'Existing SAS floors; max(floor, mean + 2/3 sample SD) after eight archived distributed comparison pairs, grouped by section/category/month group.','failed_rows':sum(r['POLICY_STATUS']=='FAIL' for r in records),'review_rows':sum(r['POLICY_STATUS']=='REVIEW' for r in records),'baseline_provenance_review':bool(base.get('limitations')),'scope':'17 Summary categories; expanded coverage beyond five original QC series.'}
    (dest/'baseline_policy_summary.json').write_text(json.dumps(policy,indent=2))
    checks=[]
    def add(name,status,names):checks.append({'check':name,'status':status,'evidence':[{'name':p,'sha256':sha(dest/p)} for p in names]})
    add('workbook_structure','PASS' if structure['worksheet_names_and_order']=='PASS' and structure['worksheets']==11 else 'FAIL',['workbook_validation_summary.json','candidate_structure.json'])
    failures=bool(detail['unclosed_groups']) or any(v.get('count_FAIL',0) or v.get('percent_FAIL',0) for v in detail['sheets'].values())
    review=any(v.get('count_ROUNDING_REVIEW',0) or v.get('percent_ROUNDING_REVIEW',0) for v in detail['sheets'].values())
    add('detail_reconciliation','FAIL' if failures else 'REVIEW' if review else 'PASS',['detail_validation_summary.json','Detail_Reconciliation.csv','worksheet_totals.json'])
    add('cross_sheet_reconciliation','PASS' if cross['status']=={'PASS':cross['checks']} else 'FAIL',['cross_sheet_validation_summary.json','Cross_Sheet_Reconciliation.csv'])
    add('baseline_business_policy','FAIL' if policy['failed_rows'] else 'REVIEW' if policy['review_rows'] or policy['baseline_provenance_review'] else 'PASS',['baseline_policy_summary.json','Baseline_Policy.csv'])
    for c in source['checks']:
        linked=[]
        for e in c['evidence']:
            relative=(Path('source_evidence')/e['name']);target=dest/relative;target.parent.mkdir(exist_ok=True)
            target.write_bytes((source_checks.parent/e['name']).read_bytes())
            if sha(target)!=e['sha256']:raise ValueError('Source evidence copy mismatch')
            linked.append({'name':str(relative),'sha256':sha(target)})
        checks.append(dict(c,evidence=linked))
    final_report_hash=sha(report)
    if final_report_hash!=artifacts[0]['sha256']:raise ValueError('Workbook changed before evidence commit')
    doc={'schema_version':1,'run_id':run['run_id'],'run_manifest_sha256':sha(manifest_path),'report_sha256':final_report_hash,'baseline_manifest_sha256':sha(baseline_dir/'BASELINE_MANIFEST.json'),'checks':checks}
    (dest/'Business_Checks.json').write_text(json.dumps(doc,indent=2)+'\n')
    print(json.dumps({c['check']:c['status'] for c in checks},indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for arg in ('run-manifest','baseline-dir','report','source-checks','destination'):p.add_argument('--'+arg,required=True)
    main(p.parse_args())
