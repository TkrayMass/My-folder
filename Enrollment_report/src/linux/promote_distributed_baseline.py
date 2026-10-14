"""Archive the hash-verified report after the scheduled notification submission."""
import argparse,csv,datetime,json,os,shutil
from decimal import Decimal
from pathlib import Path
from check_transfer_gate import digest

ROOT=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX')

def promote(package_path,marker_path,expected_run,verification_path=None):
    package_path,marker_path=map(Path,(package_path,marker_path))
    package=json.loads(package_path.read_text())
    if package.get('run_id')!=expected_run or package.get('release_allowed') is not True:
        raise ValueError('Notification release identity differs')
    fields=dict(line.split('=',1) for line in marker_path.read_text(encoding='utf-8-sig').splitlines() if '=' in line)
    if (fields.get('ReportDate')!=package['report_date'] or fields.get('RunID')!=expected_run or
        fields.get('ReleaseSHA256',fields.get('PublishedSHA256','')).lower()!=package['artifacts']['report']['sha256'] or
        fields.get('QCDecision') not in ('READY TO DISTRIBUTE','REVIEW BEFORE DISTRIBUTION')):
        raise ValueError('Notification receipt does not bind the published report')
    if fields.get('PublishedSHA256','').lower()!=package['artifacts']['report']['sha256']:
        if not verification_path or digest(verification_path)!=fields.get('ContentVerificationSHA256','').lower():
            raise ValueError('Changed publication requires a bound content verification receipt')
        verified=json.loads(Path(verification_path).read_text())
        if (verified.get('policy')!='enrollment_content_v1' or verified.get('status')!='PASS' or verified.get('differences')!=0 or
            verified.get('method')!='CONTENT' or verified.get('run_id')!=expected_run or verified.get('report_date')!=package['report_date'] or
            verified.get('source_sha256')!=package['artifacts']['report']['sha256'] or
            verified.get('published_sha256')!=fields.get('PublishedSHA256','').lower() or
            not verified.get('sheets') or any(s.get('differences')!=0 for s in verified['sheets'])):
            raise ValueError('Publication content verification identity or result differs')
    pointer=ROOT/'CURRENT_DISTRIBUTED_BASELINE.txt'
    before=Path(pointer.read_text().strip())
    destination=ROOT/'distributed_baselines'/expected_run
    if destination.exists():
        existing=json.loads((destination/'BASELINE_MANIFEST.json').read_text())
        if existing.get('release_package_sha256')!=digest(package_path):raise ValueError('Existing baseline differs')
        return {'baseline':str(destination),'status':'ALREADY_ARCHIVED'}
    previous=json.loads((before/'BASELINE_MANIFEST.json').read_text())
    if previous['report_date']>=package['report_date']:raise ValueError('Baseline must advance in time')
    manifest_path=Path(package['artifacts']['run_manifest']['path'])
    if digest(manifest_path)!=package['artifacts']['run_manifest']['sha256']:raise ValueError('Run manifest changed')
    run=json.loads(manifest_path.read_text())
    matrices=[a for a in run['artifacts'] if Path(a['path']).name=='QC_Current_Matrix.csv']
    if len(matrices)!=1 or digest(matrices[0]['path'])!=matrices[0]['sha256']:raise ValueError('Current matrix changed')
    date=package['report_date']
    sources={'ReportTestMonthly-'+date+'_REGXSA.xlsx':Path(package['artifacts']['report']['path']),
             'ACO_Enrollment_Comparison_QC_'+date+'.xlsx':Path(package['artifacts']['primary_qc']['path']),
             'Distributed_Baseline_Matrix.csv':Path(matrices[0]['path']),
             'Notification_Submission.ok':marker_path,'TRANSFER_PACKAGE.json':package_path}
    if verification_path:sources['Published_Content_Verification.json']=Path(verification_path)
    for key in ('report','primary_qc'):
        if digest(package['artifacts'][key]['path'])!=package['artifacts'][key]['sha256']:raise ValueError('Release artifact changed')
    destination.mkdir(parents=True,exist_ok=False)
    artifacts=[]
    for name,source in sources.items():
        target=destination/name;shutil.copyfile(str(source),str(target))
        if digest(target)!=digest(source):raise ValueError('Baseline archive copy differs')
        artifacts.append({'name':name,'bytes':target.stat().st_size,'sha256':digest(target),'source':str(source)})
    history=[]
    previous_history=before/'ADAPTIVE_HISTORY.csv'
    if previous_history.exists():
        item=next(a for a in previous['artifacts'] if a['name']=='ADAPTIVE_HISTORY.csv')
        if digest(previous_history)!=item['sha256']:raise ValueError('Prior adaptive history changed')
        with previous_history.open(newline='') as f:history=list(csv.DictReader(f))
    if 'baseline_policy' in package['artifacts']:
        item=package['artifacts']['baseline_policy'];policy=Path(item['path'])
        if digest(policy)!=item['sha256']:raise ValueError('Baseline comparisons changed')
        with policy.open(newline='') as f:
            for row in csv.DictReader(f):
                if not row['BASELINE'] or not row['DIFFERENCE']:continue
                history.append({'PAIR_ID':expected_run,'REPORT_SECTION':row['REPORT_SECTION'],
                    'CATEGORY':row['CATEGORY'],'MONTH_ID':row['MONTH_ID'],'MONTH_GROUP':row['MONTH_GROUP'],
                    'ABS_DIFF':str(abs(Decimal(row['DIFFERENCE'])))})
    if history:
        history_path=destination/'ADAPTIVE_HISTORY.csv'
        with history_path.open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=list(history[0]));writer.writeheader();writer.writerows(history)
        artifacts.append({'name':history_path.name,'bytes':history_path.stat().st_size,'sha256':digest(history_path),'source':'Hash-bound distributed comparison pairs'})
    receipt={'schema_version':1,'baseline_id':expected_run,'report_date':date,
             'notification_submitted_at_local':fields['SentAt'],'timezone':'America/New_York',
             'archived_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'release_package_sha256':digest(package_path),'previous_baseline':str(before),
             'observed_published_sha256':fields.get('PublishedSHA256','').lower(),
             'notification_delivery_confirmed':False,'limitations':[],
             'provenance':'Immutable release SHA256 and published byte/content verification checked at notification submission; source run and archive hashes retained.',
             'artifacts':artifacts}
    (destination/'BASELINE_MANIFEST.json').write_text(json.dumps(receipt,indent=2)+'\n')
    temporary=pointer.with_suffix('.'+expected_run+'.partial')
    temporary.write_text(str(destination)+'\n');os.replace(str(temporary),str(pointer))
    return {'baseline':str(destination),'status':'PROMOTED'}

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('package','marker','run-id'):p.add_argument('--'+key,required=True)
    p.add_argument('--verification')
    a=p.parse_args();print(json.dumps(promote(a.package,a.marker,a.run_id,a.verification),indent=2))
