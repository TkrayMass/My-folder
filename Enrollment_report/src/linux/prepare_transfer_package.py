"""Create a separate release package from complete, hash-bound run evidence."""
import argparse
import json
import datetime
import os
from pathlib import Path
from check_transfer_gate import digest, validate

def prepare(manifest, qc, report, render_folder, destination):
    manifest,qc,report,render_folder,destination=map(Path,(manifest,qc,report,render_folder,destination))
    gate=validate(manifest,qc,report)
    rendered=render_folder/'QC_RENDER_VALIDATION_FULL.json'
    inputs=render_folder/'QC_DISPLAY_INPUTS.json'
    workbook=render_folder/'ACO_Weekly_Final_QC_Colored.xlsx'
    r=json.loads(rendered.read_text());i=json.loads(inputs.read_text())
    if (r.get('run_id')!=gate['run_id'] or i.get('run_id')!=gate['run_id'] or
        i.get('report_date')!=gate['report_date'] or i.get('qc_sha256')!=digest(qc) or
        r.get('qc_render_status')!='PASS' or r.get('fail_rows')!=0 or
        r.get('input_receipt_sha256')!=digest(inputs) or r.get('workbook_sha256')!=digest(workbook)):
        raise ValueError('Private QC does not match completed run')
    paths={'run_manifest':manifest,'final_qc':qc,'report':report,'private_qc':workbook,
           'qc_render_receipt':rendered,'qc_input_receipt':inputs}
    primary=render_folder.parent/'Primary_Render'
    primary_receipt=primary/'PRIMARY_QC_VALIDATION.json'
    primary_workbook=primary/'ACO_Enrollment_Comparison_QC.xlsx'
    primary_inputs=primary/'PRIMARY_QC_INPUTS.json'
    pr=json.loads(primary_receipt.read_text())
    if (pr.get('run_id')!=gate['run_id'] or pr.get('report_date')!=gate['report_date'] or
        pr.get('primary_qc_status')!='PASS' or pr.get('failures')!=0 or
        pr.get('final_qc_sha256')!=digest(qc) or pr.get('workbook_sha256')!=digest(primary_workbook) or
        pr.get('inputs_sha256')!=digest(primary_inputs)):
        raise ValueError('Primary comparison QC does not match completed run')
    paths.update(primary_qc=primary_workbook,primary_qc_receipt=primary_receipt,primary_qc_inputs=primary_inputs)
    policy=render_folder.parents[2]/'business_evidence/Baseline_Policy.csv'
    expected=next(e['sha256'] for c in json.loads(qc.read_text())['checks']
                  if c['check']=='baseline_business_policy' for e in c['evidence'] if e['name']=='Baseline_Policy.csv')
    if digest(policy)!=expected:raise ValueError('Baseline policy changed')
    paths['baseline_policy']=policy
    package={'schema_version':1,'run_id':gate['run_id'],'report_date':gate['report_date'],
             'qc_decision':gate['qc_decision'],'release_allowed':True,
             'release_basis':'All required same-run controls complete; PASS and REVIEW allowed, FAIL/NOT_RUN blocked.',
             'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'artifacts':{name:{'path':str(p.resolve()),'sha256':digest(p),'bytes':p.stat().st_size}
                          for name,p in paths.items()},'notification_sent':False}
    scope=manifest.parent/'SAS.log.scope_receipt.json'
    if scope.is_file():package['startup_log_scope']={'path':str(scope),'sha256':digest(scope)}
    destination.mkdir(parents=True,exist_ok=False)
    target=destination/'TRANSFER_PACKAGE.json'
    target.write_text(json.dumps(package,indent=2)+'\n')
    return package

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('run-manifest','final-qc','report','render-folder','destination'):
        p.add_argument('--'+key,required=True)
    a=p.parse_args()
    print(json.dumps(prepare(a.run_manifest,a.final_qc,a.report,a.render_folder,a.destination),indent=2))
