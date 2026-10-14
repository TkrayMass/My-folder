from pathlib import Path
import xml.etree.ElementTree as ET
import csv,json,re
from collections import Counter,defaultdict
import argparse
from report_reader import report_events

root=Path(__file__).resolve().parent;folder=root/'Validation'/'20261013'
parser=argparse.ArgumentParser();parser.add_argument('--folder',default=str(folder));parser.add_argument('--report',default=str(folder/'ReportTestMonthly-20261013_REBUILD_REGXSA.xls'))
args=parser.parse_args();folder=Path(args.folder);report=Path(args.report)
ns='urn:schemas-microsoft-com:office:spreadsheet'
def colname(n):
    s=''
    while n:n,r=divmod(n-1,26);s=chr(65+r)+s
    return s
def number(v):
    if v in ('','.'):return 0.0
    if v.endswith('%'):return float(v[:-1].replace(',',''))/100
    return float(v.replace(',',''))

sheet=None;table=None;counts=[];percents=[];headers={};sums={};psum={};n=0;rows=0
checks=[];totals=[];stats=defaultdict(Counter);section=None;unclosed=[]
for event,e in report_events(report):
    if event=='start' and e.tag==f'{{{ns}}}Worksheet':
        sheet=e.attrib[f'{{{ns}}}Name'];counts=[];headers={};sums={};psum={};n=0;rows=0
        section='DISENROLLMENT' if 'DisEnroll' in sheet or 'Disenroll' in sheet else 'ENROLLMENT' if 'Enroll' in sheet else 'CASELOAD'
    elif event=='start' and e.tag==f'{{{ns}}}Table':table=e
    elif event=='end' and e.tag==f'{{{ns}}}Row':
        rows+=1;r={};i=0
        for c in e.findall(f'{{{ns}}}Cell'):
            i=int(c.attrib.get(f'{{{ns}}}Index',i+1));d=c.find(f'{{{ns}}}Data')
            value=''.join(d.itertext()).strip() if d is not None else ''
            if value:r[colname(i)]=value
            i+=int(c.attrib.get(f'{{{ns}}}MergeAcross',0))
        title=r.get('A','')
        if 'MassHealth ACO/MCO/PCC Members' in title:section='CASELOAD'
        elif 'MassHealth ACO/MCO/PCC Enrollments' in title:section='ENROLLMENT'
        elif 'MassHealth ACO/MCO/PCC Disenrollments' in title:section='DISENROLLMENT'
        datecells=[(c,v) for c,v in r.items() if re.fullmatch(r'\d{8}(?:-MTD)?',v)]
        if datecells and 'Plan Type' in r.values():
            seen=set();counts=[];percents=[]
            for c,v in datecells:
                if v in seen:percents.append((c,v))
                else:seen.add(v);counts.append((c,v))
            assert [v for _,v in counts]==[v for _,v in percents],sheet
            headers={c:v for c,v in r.items() if v in ('Caseload','Reason','Enrollment','Disenrollment','MCO Regions','Service Areas','Plan Type','ACO/MCO','Running Date')}
            sums={m:0 for _,m in counts};psum={m:0 for _,m in counts};n=0
        elif counts:
            categorycols=[c for c,v in headers.items() if v==('Caseload' if section=='CASELOAD' else 'Reason')]
            category=r.get(categorycols[-1],'') if categorycols else ''
            numeric_present=any(c in r for c,_ in counts)
            if category and numeric_present:
                dims=[c for c,v in headers.items() if v in ('MCO Regions','Service Areas','Plan Type','ACO/MCO','Running Date')]
                subtotal=all(not r.get(c) for c in dims)
                vals={m:number(r.get(c,'')) for c,m in counts}
                pv={m:number(r.get(c,'')) for c,m in percents}
                if subtotal:
                    assert n>0,(sheet,rows,'Subtotal without detail')
                    membercols=[c for c,v in headers.items() if v in ('Enrollment','Disenrollment')]
                    member=r.get(membercols[-1],'') if membercols else (category if section=='CASELOAD' else 'All')
                    for m,v in vals.items():
                        diff=v-sums[m];bound=.5*(n+1) if section=='CASELOAD' else 0
                        countstatus='PASS' if diff==0 else 'ROUNDING_REVIEW' if abs(diff)<=bound else 'FAIL'
                        pdiff=pv[m]-psum[m];pbound=.00005*(n+1)+1e-12
                        pstatus='PASS' if abs(pdiff)<1e-10 else 'ROUNDING_REVIEW' if abs(pdiff)<=pbound else 'FAIL'
                        checks.append({'SHEET':sheet,'ROW':rows,'SECTION':section,'MEMBER_TYPE':member,'CATEGORY':category,'PERIOD':m,'DETAIL_ROWS':n,'COUNT_DIFFERENCE':diff,'COUNT_ROUNDING_BOUND':bound,'COUNT_STATUS':countstatus,'PERCENT_DIFFERENCE':pdiff,'PERCENT_ROUNDING_BOUND':pbound,'PERCENT_STATUS':pstatus})
                        totals.append({'sheet':sheet,'section':section,'member':member,'category':category,'period':m,'count':v,'percentage':pv[m]})
                        stats[sheet]['count_'+countstatus]+=1;stats[sheet]['percent_'+pstatus]+=1
                    sums={m:0 for _,m in counts};psum={m:0 for _,m in counts};n=0
                else:
                    n+=1
                    for m,v in vals.items():sums[m]+=v;psum[m]+=pv[m]
        e.clear()
        if table is not None:table.remove(e)
    elif event=='end' and e.tag==f'{{{ns}}}Worksheet':
        if n:unclosed.append({'sheet':sheet,'unclosed_detail_rows':n})
        e.clear();table=None
with (folder/'Detail_Reconciliation.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(checks[0]));w.writeheader();w.writerows(checks)
(folder/'worksheet_totals.json').write_text(json.dumps(totals))
result={'sheets':dict(stats),'unclosed_groups':unclosed,'check_rows':len(checks),'limitations':['Count and percentage subtotal display checks only; independent source denominator validation remains pending.','Caseload and percentages use mathematically derived display-rounding bounds; ROUNDING_REVIEW is not a business PASS.','Unknown/out-of-state exclusions differ by worksheet; cross-sheet population reconciliation is separate.']}
(folder/'detail_validation_summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
