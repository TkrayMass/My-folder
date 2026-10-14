"""Prepare one QC workbook from immutable comparison and technical evidence.

No refresh, publication, or mail. Python 3.6 compatible; no external libraries.
"""
import argparse, csv, datetime, json
from collections import Counter
from decimal import Decimal
from pathlib import Path
from check_transfer_gate import digest

LABELS = {'technical_completion':'Report integrity', 'baseline_comparison_identity':'Comparison identity',
 'workbook_structure':'Workbook structure', 'upstream_totals':'Upstream totals',
 'row_preservation':'Row preservation', 'percentage_denominators':'Percentage denominators',
 'detail_reconciliation':'Detail reconciliation', 'cross_sheet_reconciliation':'Summary to detail',
 'baseline_business_policy':'Distributed baseline'}

def read_csv(path):
    with Path(path).open(newline='') as handle:return list(csv.DictReader(handle))

def number(value):
    return None if value in ('',None) else float(Decimal(value))

def date(value):
    return datetime.datetime.strptime(value,'%Y%m%d').strftime('%Y-%m-%d')

def prepare(manifest_path,qc_path,policy_path,comparison_path,private_folder,destination):
    manifest_path,qc_path,policy_path,comparison_path,private_folder,destination=map(Path,
        (manifest_path,qc_path,policy_path,comparison_path,private_folder,destination))
    run=json.loads(manifest_path.read_text());qc=json.loads(qc_path.read_text())
    comparison=json.loads(comparison_path.read_text())
    if (qc['run_id']!=run['run_id'] or qc['report_date']!=run['report_date'] or
        comparison['run_id']!=run['run_id'] or comparison['run_manifest_sha256']!=digest(manifest_path)):
        raise ValueError('Combined QC inputs belong to another run')
    policy_control=next(c for c in qc['checks'] if c['check']=='baseline_business_policy')
    expected=next(e['sha256'] for e in policy_control['evidence'] if e['name']=='Baseline_Policy.csv')
    if digest(policy_path)!=expected:raise ValueError('Comparison policy changed')
    private_inputs=private_folder/'QC_DISPLAY_INPUTS.json'
    private=json.loads(private_inputs.read_text())
    if (private['run_id']!=run['run_id'] or private['qc_sha256']!=digest(qc_path)):
        raise ValueError('Technical QC belongs to another final decision')
    for name in ('QC_Display_Summary.csv','QC_Display_Detail.csv'):
        if digest(private_folder/name)!=private['files'][name]:raise ValueError('Technical display input changed')
    policy=read_csv(policy_path);technical=read_csv(private_folder/'QC_Display_Detail.csv')
    keys=[(r['REPORT_SECTION'],r['CATEGORY'],r['MONTH_ID']) for r in policy]
    if len(set(keys))!=len(keys):raise ValueError('Duplicate comparison key')
    counts=Counter(r['POLICY_STATUS'] for r in policy)
    if set(counts)-{'PASS','REVIEW','FAIL'}:raise ValueError('Unknown comparison status')
    prior_date=comparison['baseline_report_date'];current_date=run['report_date']
    detail=[]
    for row in policy:
        prior,current=number(row['BASELINE']),number(row['CANDIDATE'])
        change=number(row['DIFFERENCE'])
        if prior is not None and abs(Decimal(row['CANDIDATE'])-Decimal(row['BASELINE'])-Decimal(row['DIFFERENCE']))>Decimal('0.000001'):
            raise ValueError('Comparison difference is inconsistent')
        pct=(current-prior)/prior if prior else 0 if prior==0 and current==0 else None
        reason=('Current month-to-date; changes are nonblocking.' if row['MONTH_GROUP']=='CURRENT_MTD' else
                'Historical change within warning threshold.' if row['POLICY_STATUS']=='PASS' else
                'Historical change exceeds blocking threshold.' if row['POLICY_STATUS']=='FAIL' else
                'Historical change exceeds warning threshold.')
        if prior is None:reason='No matching prior value; review source coverage.'
        detail.append([row['REPORT_SECTION'],row['CATEGORY'],'TOTAL',row['MONTH_ID'][:4]+'-'+row['MONTH_ID'][4:6],
            row['MONTH_GROUP'],date(prior_date),prior,date(current_date),current,change,pct,
            number(row['WARNING_THRESHOLD']),None if row['MONTH_GROUP']=='CURRENT_MTD' else number(row['FAIL_THRESHOLD']),row['POLICY_STATUS'],reason])
    months=sorted(set(r['MONTH_ID'] for r in policy));groups=sorted(set((r['REPORT_SECTION'],r['CATEGORY']) for r in policy))
    index={(r[0],r[1],r[3]):r for r in detail};matrix=[]
    for section,category in groups:
        for measure,col in [('Prior Members',6),('Current Members',8),('Difference',9),('% Change',10),('QC Flag',13)]:
            matrix.append([section if col==6 else '',category if col==6 else '', 'TOTAL' if col==6 else '',measure]+[index[(section,category,m[:4]+'-'+m[4:6])][col] if (section,category,m[:4]+'-'+m[4:6]) in index else None for m in months])
    tech_counts=Counter(r['STATUS'] for r in technical)
    reasons=Counter(r['CHECK'] for r in technical)
    summary=[['Run Date',date(current_date),'Current report'],['Prior Comparison Date',date(prior_date),'Last distributed baseline'],
      ['Overall QC Status',qc['final_qc_decision'],'FAIL blocks distribution. REVIEW remains visible.'],
      ['Comparison Status','FAIL' if counts['FAIL'] else 'REVIEW' if counts['REVIEW'] else 'PASS','Current versus last distributed report'],
      ['Comparison Rows Checked',len(detail),'17 Summary categories, across all available reporting months.'],
      ['Comparison PASS',counts['PASS'],'Green comparison rows'],['Comparison REVIEW',counts['REVIEW'],'Yellow comparison rows'],
      ['Comparison FAIL',counts['FAIL'],'Red comparison rows'],
      ['Technical Review Lines',tech_counts['REVIEW'],'Rounding/provenance diagnostics, separate from comparison warnings.'],
      ['Technical Failure Lines',tech_counts['FAIL'],'Supporting technical diagnostics'],
      ['Recommended Action','Review yellow items; FAIL blocks distribution.','Use QC_Matrix and QC_Detail for prior/current comparison.'],
      ['Adaptive Threshold Rule','Activates after 8 archived weekly comparison pairs','Existing business floors remain in effect.']]
    tech_summary={r['CHECK']:r['EVIDENCE'].replace('QC Detail','Technical_Detail') for r in read_csv(private_folder/'QC_Display_Summary.csv')}
    for control in qc['checks']:
        label=LABELS.get(control['check'],control['check'])
        explanation=tech_summary.get(label,'Completed same-run control.')
        if control['check']=='baseline_business_policy':explanation='No original publication hash receipt for the seed baseline. Numerical comparison counts are shown above.' if 'Baseline provenance' in reasons else explanation
        summary.append([label,control['status'],explanation])
    for reason,count in sorted(reasons.items()):summary.append([reason+' lines',count,'See Technical_Detail for the exact supporting evidence.'])
    tech_headers=['Status','Check','Worksheet','Member / group','Category','Month','Measure','Reference','Current','Difference','Tolerance / warning','Blocking threshold','Reason']
    tech_rows=[]
    for row in technical:
        tech_rows.append([row[k] if i not in (7,8,9,10,11) else number(row[k]) for i,k in enumerate(
          ['STATUS','CHECK','WORKSHEET','MEMBER_GROUP','CATEGORY','MONTH','MEASURE','REFERENCE','CURRENT','DIFFERENCE','TOLERANCE','BLOCKING_THRESHOLD','REASON'])])
    specs=[
      {'name':'QC_Summary','title':'ACO Weekly Enrollment QC Summary','headers':['QC Summary Item','Value','Detail'],
       'rows':summary,'widths':[38,54,100],'status_col':1,'freeze':3},
      {'name':'QC_Matrix','title':'ACO Enrollment QC Matrix - Prior Report Compared to Current Report',
       'headers':['Section','Category','Plan Type','Measure']+[m[:4]+'-'+m[4:6] for m in months],
       'rows':matrix,'widths':[20,32,14,20]+[17]*len(months),'freeze':3,'freeze_cols':4,'matrix':True},
      {'name':'QC_Detail','title':'ACO Enrollment QC Detail - Current versus Last Distributed',
       'headers':['Section','Category','Plan Type','Month','Month Group','Prior Run','Prior Members','Current Run','Current Members','Difference','% Change','Warning threshold','Blocking threshold','Status','Reason'],
       'rows':detail,'widths':[20,32,14,12,18,14,19,14,19,19,14,19,19,13,68],'status_col':13,'freeze':3,'freeze_cols':3,
       'numeric_cols':[6,8,9,11,12],'pct_cols':[10]},
      {'name':'Technical_Detail','title':'ACO Enrollment Technical QC Detail',
       'headers':tech_headers,'rows':tech_rows,'widths':[13,25,30,24,30,14,22,19,19,19,19,19,90],
       'status_col':0,'freeze':3,'freeze_cols':3,'numeric_cols':[7,8,9,10,11]}]
    payload={'run_id':run['run_id'],'report_date':current_date,'baseline_report_date':prior_date,
      'final_qc_sha256':digest(qc_path),'qc_decision':qc['final_qc_decision'],
      'comparison_rows':len(detail),'comparison_counts':dict(counts),'technical_rows':len(technical),
      'sources':{str(p):digest(p) for p in (manifest_path,qc_path,policy_path,comparison_path,private_inputs,
                     private_folder/'QC_Display_Summary.csv',private_folder/'QC_Display_Detail.csv')},'sheets':specs}
    destination.mkdir(parents=True,exist_ok=False)
    (destination/'COMBINED_QC_INPUTS.json').write_text(json.dumps(payload,indent=2)+'\n')
    for sheet in specs:
        with (destination/(sheet['name']+'.csv')).open('w',newline='') as handle:
            writer=csv.writer(handle);writer.writerow(sheet['headers']);writer.writerows(sheet['rows'])
    write_sas(payload,destination)
    return payload

def write_sas(payload,destination):
    """SAS is the installed server's spreadsheet renderer; Node is not required."""
    lines=['ods _all_ close; options nodate nonumber;','%let qcdir=%superq(sysparm);',
      '%macro pathcheck;',
      r"%if not %sysfunc(prxmatch(%str(/^\/sas_mass_health\/shared\/tkray\/Enrollment\/Reports\/ACO_REBUILD_XLSX\/runs\/[A-Za-z0-9_]+\/qc_versions\/[A-Za-z0-9_]+\/Combined_Render$/),%superq(qcdir))) %then %abort cancel;",
      '%mend; %pathcheck;']
    for si,sheet in enumerate(payload['sheets']):
        numeric=set(sheet.get('numeric_cols',[])+sheet.get('pct_cols',[]))
        count=len(sheet['headers']);cols=['C'+str(i+1) for i in range(count)]
        chars=[i for i in range(count) if i not in numeric]
        lines += ['data sheet'+str(si)+';', 'infile "&qcdir./'+sheet['name']+'.csv" dsd firstobs=2 lrecl=32767 truncover;',
          'length '+' '.join(cols[i]+' $'+str(max(40,max(len(str(r[i] or '')) for r in sheet['rows'])+8)) for i in chars)+';',
          'input '+' '.join(cols[i]+(' :$'+str(max(40,max(len(str(r[i] or '')) for r in sheet['rows'])+8))+'.' if i in chars else '') for i in range(count))+';',
          'ROW_INDEX=_n_;','run;']
        if si==0:
            lines += ['ods excel file="&qcdir./ACO_Weekly_Enrollment_QC_'+payload['report_date']+'.xlsx" style=minimal',
              "options(sheet_name='"+sheet['name']+"' sheet_interval='none' embedded_titles='yes' gridlines='off' flow='tables' frozen_headers='on' absolute_column_width='"+','.join(map(str,sheet['widths']))+"');"]
        else:lines += ["ods excel options(sheet_name='"+sheet['name']+"' sheet_interval='now' autofilter='"+('none' if sheet.get('matrix') else 'all')+"' frozen_headers='on' frozen_rowheaders='"+str(sheet.get('freeze_cols',0))+"' absolute_column_width='"+','.join(map(str,sheet['widths']))+"');"]
        lines += ["title justify=left font='Arial' height=15pt '"+sheet['title'].replace("'","''")+"';",
          "proc report data=sheet"+str(si)+" nowd missing style(header)=[background=white foreground=black font_face='Arial' font_size=11pt font_weight=bold bordercolor=gray] style(column)=[font_face='Arial' font_size=11pt bordercolor=gray];",
          'columns ROW_INDEX '+' '.join(cols)+';', 'define ROW_INDEX / display noprint;']
        for i,header in enumerate(sheet['headers']):
            fmt=''
            if i in numeric:fmt=' format=best32. style(column)=[tagattr="type:number format:'+('0.00%' if i in sheet.get('pct_cols',[]) else '#,##0.0000' if sheet['name']=='Technical_Detail' else '#,##0.00')+'"]'
            lines.append('define '+cols[i]+" / display '"+header.replace("'","''")+"'"+fmt+';')
        if sheet.get('matrix'):
            for i in range(4,count):
                lines.append('compute '+cols[i]+';')
                lines.append("if C4='% Change' then call define(_col_,'style','style=[tagattr=\"type:number format:0.00%\"]');")
                lines.append("else if C4 ne 'QC Flag' then call define(_col_,'style','style=[tagattr=\"type:number format:#,##0.00\"]');")
                for gi in range(len(sheet['rows'])//5):
                    flag=sheet['rows'][gi*5+4][i]
                    if flag in ('PASS','REVIEW','FAIL'):
                        fill={'PASS':'C6EFCE','REVIEW':'FFEB9C','FAIL':'FFC7CE'}[flag]
                        lines.append("if ROW_INDEX >= "+str(gi*5+1)+" and ROW_INDEX <= "+str(gi*5+5)+" then call define(_col_,'style/merge','style=[background=cx"+fill+"]');")
                lines.append('endcomp;')
        elif 'status_col' in sheet:
            status=cols[sheet['status_col']];lines.append('compute '+status+';')
            for value,fill in [('PASS','C6EFCE'),('REVIEW','FFEB9C'),('FAIL','FFC7CE')]:
                lines.append("if "+status+"='"+value+"' then call define(_row_,'style','style=[background=cx"+fill+"]');")
            lines.append('endcomp;')
        lines.append('run;')
    lines += ['ods excel close;','%macro complete; %if &syscc > 4 %then %abort cancel; %put NOTE: COMBINED_QC_RENDER_COMPLETE; %mend; %complete;']
    (destination/'Render_Combined_QC.sas').write_text('\n'.join(lines)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for key in ('run-manifest','final-qc','policy','comparison','private-folder','destination'):parser.add_argument('--'+key,required=True)
    args=parser.parse_args()
    result=prepare(args.run_manifest,args.final_qc,args.policy,args.comparison,args.private_folder,args.destination)
    print(json.dumps({k:result[k] for k in ('run_id','comparison_rows','comparison_counts','technical_rows')}))
