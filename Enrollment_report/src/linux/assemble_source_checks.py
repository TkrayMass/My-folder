#!/usr/bin/env python3
"""Convert retained read-only query results to three run-specific QC controls."""
import argparse,csv,hashlib,json,re
from pathlib import Path
from decimal import Decimal,ROUND_HALF_UP

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()
def rows(p):
    with p.open(newline='',encoding='utf-8-sig') as f:return list(csv.DictReader(f))
def n(r,k):
    v=Decimal(r[k].replace(',',''))
    if not v.is_finite():raise ValueError('Non-finite control '+k)
    return v
def assemble(run_manifest,evidence_dir,current_matrix):
    run_manifest=Path(run_manifest);evidence_dir=Path(evidence_dir);current_matrix=Path(current_matrix)
    run=json.loads(run_manifest.read_text())
    if run['technical_status']!='PASS':raise ValueError('Run lacks technical PASS')
    artifact=[a for a in run['artifacts'] if Path(a['path']).name=='QC_Current_Matrix.csv']
    if len(artifact)!=1 or sha(current_matrix)!=artifact[0]['sha256']:raise ValueError('Current matrix not tied to run')
    log=(evidence_dir/'Source_Checks.log').read_text(errors='replace')
    if re.search(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:',log,re.M) or 'NOTE: ACO_REBUILD_SOURCE_CONTROLS_COMPLETE' not in log:
        raise ValueError('Source control query did not complete successfully')
    first=rows(evidence_dir/'Source_Control_1.csv');second=rows(evidence_dir/'Source_Control_2.csv')
    if not first or not second:raise ValueError('Empty source controls')
    by={}
    for r in second:
        k=tuple(r[x] for x in ('TYPE','MEMBERTYPE','ENRDISCLASS','FIRSTDTWEEK'))
        if k in by:raise ValueError('Duplicate source key')
        by[k]=r
    # Prevent evidence from changed test tables being attached to this run's matrix.
    types={'CASELOAD':'snapshot','ENROLLMENT':'enrollment','DISENROLLMENT':'disenrollment'}
    for r in rows(current_matrix):
        k=(types[r['REPORT_SECTION']],'All','' if r['REPORT_SECTION']=='CASELOAD' else r['CATEGORY'],r['MONTH_ID'])
        if k not in by:raise ValueError('Run matrix group absent from source controls')
        total=n(by[k],'ACTUAL_TOTAL').quantize(Decimal('1'),rounding=ROUND_HALF_UP)
        if total!=n(r,'MBRS'):raise ValueError('Source controls do not match completed run matrix')
    totals_ok=all(r['CONTROL_STATUS']=='PASS' and abs(n(r,'EXPECTED_MBRS')-n(r,'ACTUAL_MBRS'))<=Decimal('0.000001') for r in first)
    counts_ok=all(n(r,'EXPECTED_ROWS')==n(r,'ACTUAL_ROWS') for r in second)
    denominator_ok=all(abs(n(r,'EXPECTED_TOTAL')-n(r,'MIN_DENOMINATOR'))<=Decimal('0.000001') and abs(n(r,'EXPECTED_TOTAL')-n(r,'MAX_DENOMINATOR'))<=Decimal('0.000001') and abs(n(r,'EXPECTED_TOTAL')-n(r,'ACTUAL_TOTAL'))<=Decimal('0.000001') and n(r,'INVALID_RATIO_ROWS')==0 and n(r,'MAX_RATIO_ERROR')<=Decimal('0.0000000001') for r in second)
    evidence=[{'name':name,'sha256':sha(evidence_dir/name)} for name in ('Source_Control_1.csv','Source_Control_2.csv','Source_Checks.log','Validate_Combined_Run_Sources.sas')]
    result={'schema_version':1,'run_id':run['run_id'],'run_manifest_sha256':sha(run_manifest),'checks':[{'check':name,'status':'PASS' if ok else 'FAIL','evidence':evidence} for name,ok in [('upstream_totals',totals_ok),('row_preservation',counts_ok),('percentage_denominators',denominator_ok)]],'source_group_counts':{'upstream_totals':len(first),'row_preservation_and_denominators':len(second)},'limitations':['Controls validate upstream report stages, not independent raw-source completeness.','Source-table snapshot is checked against the completed five-series matrix; shared test tables have no immutable run ID.']}
    target=evidence_dir/'Business_Checks.json'
    if target.exists():raise FileExistsError('Do not overwrite business evidence')
    target.write_text(json.dumps(result,indent=2)+'\n');return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-manifest',required=True);p.add_argument('--evidence-dir',required=True);p.add_argument('--current-matrix',required=True)
    a=p.parse_args();print(json.dumps(assemble(a.run_manifest,a.evidence_dir,a.current_matrix),indent=2))
