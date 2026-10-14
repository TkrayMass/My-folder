"""Prepare primary baseline-comparison QC; keep rounding diagnostics separate."""
import argparse,csv,json
from decimal import Decimal
from pathlib import Path
from check_transfer_gate import digest

def prepare(qc_path,evidence,destination):
    qc_path,evidence,destination=map(Path,(qc_path,evidence,destination))
    qc=json.loads(qc_path.read_text())
    control=next(c for c in qc['checks'] if c['check']=='baseline_business_policy')
    expected={e['name']:e['sha256'] for e in control['evidence']}
    for name,sha in expected.items():
        if digest(evidence/name)!=sha:raise ValueError('Baseline QC evidence changed')
    with (evidence/'Baseline_Policy.csv').open(newline='') as f:rows=list(csv.DictReader(f))
    prepared=[]
    for r in rows:
        prior=Decimal(r['BASELINE']) if r['BASELINE'] else None
        current=Decimal(r['CANDIDATE'])
        pct=(current-prior)/prior if prior else Decimal(0) if current==0 and prior==0 else None
        prepared.append([r['REPORT_SECTION'],r['CATEGORY'],r['MONTH_ID'][:4]+'-'+r['MONTH_ID'][4:6],
            r['BASELINE'],r['CANDIDATE'],r['DIFFERENCE'],str(pct) if pct is not None else '',
            r['WARNING_THRESHOLD'],'' if r['MONTH_GROUP']=='CURRENT_MTD' else r['FAIL_THRESHOLD'],r['POLICY_STATUS']])
    destination.mkdir(parents=True,exist_ok=False)
    headers=['SECTION','CATEGORY','MONTH','PRIOR','CURRENT','DIFFERENCE','PCT_CHANGE','WARNING','BLOCKING','STATUS']
    flagged=[r for r in prepared if r[-1] in ('REVIEW','FAIL')]
    for name,data in [('Primary_All.csv',prepared),('Primary_Flags.csv',flagged or [['','No threshold warnings or failures','','','','','','','','PASS']])]:
        with (destination/name).open('w',newline='') as f:
            writer=csv.writer(f);writer.writerow(headers);writer.writerows(data)
    result={'run_id':qc['run_id'],'report_date':qc['report_date'],'final_qc_sha256':digest(qc_path),
            'baseline_policy_sha256':digest(evidence/'Baseline_Policy.csv'),'rows':len(prepared),
            'warnings':sum(r[-1]=='REVIEW' for r in prepared),'failures':sum(r[-1]=='FAIL' for r in prepared),
            'files':{name:digest(destination/name) for name in ('Primary_All.csv','Primary_Flags.csv')}}
    (destination/'PRIMARY_QC_INPUTS.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for name in ('final-qc','evidence','destination'):p.add_argument('--'+name,required=True)
    a=p.parse_args();print(json.dumps(prepare(a.final_qc,a.evidence,a.destination),indent=2))
