from pathlib import Path
import xml.etree.ElementTree as ET
import json,re,csv
from decimal import Decimal
from collections import Counter
import argparse
from report_reader import report_events

root=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('--folder',default=str(root/'Validation'/'20261013'))
parser.add_argument('--report',default=str(root/'Validation'/'20261013'/'ReportTestMonthly-20261013_REBUILD_REGXSA.xls'))
args=parser.parse_args();folder=Path(args.folder);report=Path(args.report)
report_date=re.search(r'ReportTestMonthly-(\d{8})',report.name).group(1)
current_month=report_date[:6]+'01'
ns='urn:schemas-microsoft-com:office:spreadsheet'
def colname(n):
    s=''
    while n:n,r=divmod(n-1,26);s=chr(65+r)+s
    return s

summary=[];meta=[];sheet=None;table=None;rows=0
cached=folder/'candidate_structure.json'
if cached.exists():
    saved=json.loads(cached.read_text());summary=saved['summary_rows'];meta=saved['sheets']
events=() if cached.exists() else report_events(report)
for event,e in events:
    if event=='start' and e.tag==f'{{{ns}}}Worksheet':
        sheet=e.attrib[f'{{{ns}}}Name'];rows=0;headers=[]
    elif event=='start' and e.tag==f'{{{ns}}}Table':table=e
    elif event=='end' and e.tag==f'{{{ns}}}Row':
        rows+=1;cells=[];i=0
        for c in e.findall(f'{{{ns}}}Cell'):
            i=int(c.attrib.get(f'{{{ns}}}Index',i+1))
            d=c.find(f'{{{ns}}}Data')
            value=''.join(d.itertext()) if d is not None else ''
            if value:cells.append([colname(i)+str(rows),value])
            i+=int(c.attrib.get(f'{{{ns}}}MergeAcross',0))
        dates=[v for _,v in cells if re.fullmatch(r'\d{8}(?:-MTD)?',v)]
        if dates:headers.append({'row':rows,'periods':list(dict.fromkeys(dates))})
        if sheet=='Summary':summary.append(cells)
        e.clear()
        if table is not None:table.remove(e)
    elif event=='end' and e.tag==f'{{{ns}}}Worksheet':
        meta.append({'name':sheet,'rows':rows,'period_headers':headers});e.clear();table=None
(folder/'candidate_structure.json').write_text(json.dumps({'sheets':meta,'summary_rows':summary},indent=2))
baseline=json.loads((folder/'baseline_structure.json').read_text())
expected=[s['name'] for s in baseline]
actual=[s['name'] for s in meta]
assert expected==actual,('Worksheet mismatch',expected,actual)

def extract(source):
    section=None;periods={};plans={};total={};checks=[]
    for cells in source:
        r={re.sub(r'\d+$','',ref):v.strip() for ref,v in cells}
        title=r.get('A','')
        if 'MassHealth ACO/MCO/PCC Members' in title:section='CASELOAD'
        elif 'MassHealth ACO/MCO/PCC Enrollments' in title:section='ENROLLMENT'
        elif 'MassHealth ACO/MCO/PCC Disenrollments' in title:section='DISENROLLMENT'
        if r.get('B')=='Plan Type':
            periods={};seen=set();plans={}
            for ref,v in cells:
                if re.fullmatch(r'\d{8}(?:-MTD)?',v):
                    month=v[:8]
                    if month in seen:break
                    seen.add(month);periods[re.sub(r'\d+$','',ref)]=month
            continue
        category=r.get('C','');plan=r.get('B','')
        if not section or not category or not periods:continue
        values={m:Decimal(r.get(c,'0').replace(',','')) if r.get(c,'') not in ('','.') else Decimal(0) for c,m in periods.items()}
        if plan:
            if plan in plans:raise ValueError('Duplicate plan row before subtotal')
            plans[plan]=values
        else:
            if not plans:raise ValueError('Subtotal without detail')
            for m,v in values.items():
                key=(section,category,m)
                if key in total:raise ValueError('Duplicate subtotal key')
                total[key]=v
                plan_sum=sum(p[m] for p in plans.values())
                bound=Decimal('0.5')*(len(plans)+1)
                status='PASS' if v==plan_sum else ('ROUNDING_REVIEW' if section=='CASELOAD' and abs(v-plan_sum)<=bound else 'FAIL')
                checks.append({'REPORT_SECTION':section,'CATEGORY':category,'MONTH_ID':m,'SUBTOTAL':str(v),'PLAN_SUM':str(plan_sum),'DIFFERENCE':str(v-plan_sum),'DISPLAY_ROUNDING_BOUND':str(bound),'STATUS':status})
            plans={}
    return total,checks

b,bc=extract(next(s for s in baseline if s['name']=='Summary')['first_rows'])
t,tc=extract(summary)
assert {k[:2] for k in b}=={k[:2] for k in t},'Summary category keys differ'
comparison=[{'REPORT_SECTION':k[0],'CATEGORY':k[1],'MONTH_ID':k[2],'BASELINE':str(b[k]) if k in b else '', 'CANDIDATE':str(t[k]),'DIFFERENCE':str(t[k]-b[k]) if k in b else '', 'PERIOD_GROUP':'CURRENT_MTD' if k[2]==current_month else 'HISTORICAL'} for k in t]
for name,data in [('Summary_Reconciliation.csv',tc),('Summary_All_Category_Comparison.csv',comparison)]:
    with (folder/name).open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(data[0]));w.writeheader();w.writerows(data)
result={'worksheet_names_and_order':'PASS','worksheets':len(actual),'candidate_sheet_rows':{s['name']:s['rows'] for s in meta},'summary_category_periods':len(t),'candidate_summary_reconciliation':dict(Counter(c['STATUS'] for c in tc)),'baseline_summary_reconciliation':dict(Counter(c['STATUS'] for c in bc)),'historical_largest_absolute_revision':str(max(abs(t[k]-b[k]) for k in t if k in b and k[2]!=current_month)),'limitations':['Other ten worksheets checked for XML parsing, names/order and period-header structure only; detailed subtotal reconciliation is a separate check.','NOZERO count cells displayed blank or dot interpreted as zero for this explicitly count-only sum check.','Caseload display differences within 0.5*(plan count+1) remain ROUNDING_REVIEW; unrounded source reconciliation not established.','This is not a same-snapshot calculation equivalence test.']}
(folder/'workbook_validation_summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
