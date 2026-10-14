#!/usr/bin/env python3
"""Prepare a private two-sheet SAS QC renderer from a completed QC version.

Does not send email, publish reports, refresh data, or change schedules.
"""
import argparse
import csv
import hashlib
import json
import re
import os
from pathlib import Path

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def prepare(qc_folder, evidence, destination):
    qc_folder=Path(qc_folder).resolve(); evidence=Path(evidence).resolve()
    destination=Path(destination).resolve()
    qc=json.loads((qc_folder/'FINAL_QC.json').read_text())
    if not qc['qc_complete'] or not re.fullmatch(r'[A-Za-z0-9_]{1,80}',qc['run_id']):
        raise ValueError('Completed, identified QC version required')
    if not re.fullmatch(r'\d{8}',qc['report_date']):raise ValueError('Invalid report date')
    for check in qc['checks']:
        for item in check.get('evidence',[]):
            p=(evidence/item['name']).resolve()
            if os.path.commonpath([str(p),str(evidence)])!=str(evidence) or sha(p)!=item['sha256']:
                raise ValueError('QC evidence changed: '+item['name'])
    if destination.exists():raise FileExistsError('Use a new QC render directory')
    destination.mkdir(parents=True)
    def read_csv(name):
        with (evidence/name).open(newline='') as f:return list(csv.DictReader(f))
    totals=json.loads((evidence/'worksheet_totals.json').read_text())
    key=lambda r:(r['sheet'],r['section'],r['member'],r['category'],r['period'])
    index={key(r):r for r in totals}
    if len(index)!=len(totals):raise ValueError('Duplicate subtotal key')
    findings=[]
    for r in read_csv('Detail_Reconciliation.csv'):
        t=index[(r['SHEET'],r['SECTION'],r['MEMBER_TYPE'],r['CATEGORY'],r['PERIOD'])]
        for metric in ('COUNT','PERCENT'):
            flag=r[metric+'_STATUS']
            if flag=='PASS':continue
            factor=100 if metric=='PERCENT' else 1
            current=t['percentage' if factor==100 else 'count']*factor
            difference=float(r[metric+'_DIFFERENCE'])*factor
            findings.append(['FAIL' if flag=='FAIL' else 'REVIEW',
                'Percentage rounding' if factor==100 else 'Subtotal rounding',
                r['SHEET'],r['MEMBER_TYPE'],r['CATEGORY'],r['PERIOD'][:8],
                'Percentage points' if factor==100 else 'Members',
                current-difference,current,difference,float(r[metric+'_ROUNDING_BOUND'])*factor,'',
                'Subtotal row '+r['ROW']+'; '+('exceeds' if flag=='FAIL' else 'within')+' calculated display-rounding tolerance.'])
    for r in read_csv('Baseline_Policy.csv'):
        if r['POLICY_STATUS']=='PASS':continue
        findings.append([r['POLICY_STATUS'],'Baseline movement','Summary','All',r['CATEGORY'],r['MONTH_ID'],
            'Members',r['BASELINE'],r['CANDIDATE'],r['DIFFERENCE'],r['WARNING_THRESHOLD'],r['FAIL_THRESHOLD'],
            r['REPORT_SECTION']+'; '+r['MONTH_GROUP']+'; compared with archived distributed report.'])
    policy=json.loads((evidence/'baseline_policy_summary.json').read_text())
    if policy['baseline_provenance_review']:
        findings.append(['REVIEW','Baseline provenance','Archived baseline','','',qc['report_date'][:6]+'01',
            '', '', '', '', '', '', 'Baseline is archived and hash-verified now; no original publication hash receipt.'])
    findings.sort(key=lambda r:(r[0]!='FAIL',r[1],-int(r[5]),r[2]))
    checks=[r for r in qc['checks'] if r['check'] not in ('technical_completion','baseline_comparison_identity')]
    labels={'workbook_structure':'Workbook structure','upstream_totals':'Upstream totals',
        'row_preservation':'Row preservation','percentage_denominators':'Percentage denominators',
        'detail_reconciliation':'Detail reconciliation','cross_sheet_reconciliation':'Summary to detail',
        'baseline_business_policy':'Distributed baseline'}
    if len(checks)!=7 or set(r['check'] for r in checks)!=set(labels):raise ValueError('Seven business checks required')
    detail=json.loads((evidence/'detail_validation_summary.json').read_text())
    cross=json.loads((evidence/'cross_sheet_validation_summary.json').read_text())
    descriptions={'workbook_structure':'Expected worksheet names and order verified.',
        'upstream_totals':'Source-stage totals reconcile.', 'row_preservation':'Expected source rows retained.',
        'percentage_denominators':'Source denominators and row ratios checked.',
        'detail_reconciliation':str(detail['check_rows'])+' subtotal-period checks. See QC Detail for flagged lines.',
        'cross_sheet_reconciliation':str(cross['checks'])+' summary/detail comparisons.',
        'baseline_business_policy':str(policy['failed_rows'])+' numerical failures; '+str(policy['review_rows'])+' numerical warnings. Baseline provenance review shown separately.'}
    summary=[['Final QC decision',qc['final_qc_decision'],'Run '+qc['run_id']],
        ['Report date',qc['report_date'],'QC details are retained privately.'],
        ['Checks complete','Yes',str(sum(r[0]=='REVIEW' for r in findings))+' REVIEW lines; '+str(sum(r[0]=='FAIL' for r in findings))+' FAIL lines.']]
    summary.extend([labels[r['check']],r['status'],descriptions[r['check']]] for r in checks)
    for name,headers,rows in [('QC_Display_Summary.csv',['CHECK','RESULT','EVIDENCE'],summary),
        ('QC_Display_Detail.csv',['STATUS','CHECK','WORKSHEET','MEMBER_GROUP','CATEGORY','MONTH','MEASURE','REFERENCE','CURRENT','DIFFERENCE','TOLERANCE','BLOCKING_THRESHOLD','REASON'],findings)]:
        with (destination/name).open('w',newline='') as f:
            writer=csv.writer(f);writer.writerow(headers);writer.writerows(rows)
    receipt={'run_id':qc['run_id'],'report_date':qc['report_date'],'qc_sha256':sha(qc_folder/'FINAL_QC.json'),
        'detail_rows':len(findings),'candidate_only':True,'publication_allowed':False,
        'inputs':{name:sha(evidence/name) for name in ('worksheet_totals.json','Detail_Reconciliation.csv','Baseline_Policy.csv')},
        'files':{p.name:sha(p) for p in destination.iterdir()}}
    (destination/'QC_DISPLAY_INPUTS.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('qc-folder','evidence','destination'):p.add_argument('--'+key,required=True)
    a=p.parse_args(); print(json.dumps(prepare(a.qc_folder,a.evidence,a.destination),indent=2))
