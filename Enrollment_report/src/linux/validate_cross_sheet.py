from pathlib import Path
from collections import defaultdict,Counter
import json,csv
import argparse
from cross_sheet_precision import paired_values_match,COUNT_PRECISION,RATIO_PRECISION

folder=Path(__file__).resolve().parent/'Validation'/'20261013'
parser=argparse.ArgumentParser();parser.add_argument('--folder',default=str(folder));args=parser.parse_args();folder=Path(args.folder)
rows=json.loads((folder/'worksheet_totals.json').read_text())
by=defaultdict(dict)
for r in rows:
    key=(r['section'],r['member'],r['category'],r['period'])
    if key in by[r['sheet']]:raise ValueError('Duplicate subtotal key '+str((r['sheet'],key)))
    by[r['sheet']][key]=r
pairs=[('Summary','Caseload','CASELOAD'),('Summary','Enrollment','ENROLLMENT'),('Summary','Disenrollment','DISENROLLMENT'),('Summary-Caseload-Reg x SA','Caseload-Reg X SA',None),('Summary-Enroll-Reg X SA','Enrollment-Reg X SA',None),('Summary-DisEnroll-Reg X SA','Disenrollment_Reg X SA',None)]
checks=[]
for left,right,section in pairs:
    a={k:v for k,v in by[left].items() if section is None or k[0]==section}
    b={k:v for k,v in by[right].items() if section is None or k[0]==section}
    for k in sorted(set(a)|set(b)):
        x=a.get(k);y=b.get(k)
        diff=y['count']-x['count'] if x and y else None
        pdiff=y['percentage']-x['percentage'] if x and y else None
        status='MISSING_KEY' if not x or not y else 'PASS' if paired_values_match(k[0],diff,pdiff) else 'MISMATCH'
        checks.append({'SUMMARY_SHEET':left,'DETAIL_SHEET':right,'SECTION':k[0],'GROUP':k[1],'CATEGORY':k[2],'PERIOD':k[3],'SUMMARY_COUNT':x['count'] if x else '', 'DETAIL_COUNT':y['count'] if y else '', 'COUNT_DIFFERENCE':diff,'PERCENT_DIFFERENCE':pdiff,'STATUS':status})
with (folder/'Cross_Sheet_Reconciliation.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(checks[0]));w.writeheader();w.writerows(checks)
result={'checks':len(checks),'status':dict(Counter(r['STATUS'] for r in checks)),'pairs':{l+' versus '+r:dict(Counter(c['STATUS'] for c in checks if c['SUMMARY_SHEET']==l and c['DETAIL_SHEET']==r)) for l,r,_ in pairs},'numerical_equality':{'fractional_caseload_members':COUNT_PRECISION,'enrollment_dis enrollment_count':0,'percentage_fraction':RATIO_PRECISION,'reason':'Native XLSX precision and differing summation orders; not business-change tolerances.'},'limitations':['Checks compare reports with matching source filters and period keys.','Summary-Enroll-Region has no direct detail counterpart; its internal subtotals were separately checked.','Independent source totals and percentage denominators still require verification.']}
(folder/'cross_sheet_validation_summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
