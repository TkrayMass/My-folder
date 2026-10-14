"""Submit one owner-only QC email for a validated release."""
import argparse,datetime,json,re,smtplib
from email.message import EmailMessage
from pathlib import Path
from check_transfer_gate import digest
ROOT=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX')
OWNER='Tatyana.Kray@mass.gov'

def notify(run_id):
    if not re.fullmatch(r'[A-Za-z0-9_]{1,80}',run_id):raise ValueError('Invalid run ID')
    audit=ROOT/'runs'/run_id;package_path=ROOT/'releases'/run_id/'TRANSFER_PACKAGE.json'
    package=json.loads(package_path.read_text())
    if (package.get('run_id')!=run_id or package.get('release_allowed') is not True or
        package.get('qc_decision') not in ('PASS','REVIEW')):raise ValueError('QC email requires a validated, non-failing release')
    artifacts=package['artifacts']
    for key in ('final_qc','primary_qc','private_qc'):
        if digest(artifacts[key]['path'])!=artifacts[key]['sha256']:raise ValueError('QC artifact checksum changed: '+key)
    qc=json.loads(Path(artifacts['final_qc']['path']).read_text())
    if (qc.get('run_id')!=run_id or qc.get('report_date')!=package.get('report_date') or
        qc.get('qc_complete') is not True or qc.get('failed_checks') or qc.get('not_run_checks') or
        qc.get('final_qc_decision')!=package['qc_decision']):raise ValueError('QC completeness or identity differs')
    marker=audit/'QC_EMAIL_ATTEMPT.json';result_path=audit/'QC_EMAIL_RESULT.json'
    if marker.exists():
        if result_path.exists() and json.loads(result_path.read_text()).get('status')=='SMTP_ACCEPTED':
            return {'run_id':run_id,'status':'ALREADY_SUBMITTED','to':OWNER}
        raise RuntimeError('Prior uncertain QC email attempt requires receipt review before retry')
    record={'run_id':run_id,'to':OWNER,'qc_decision':package['qc_decision'],'release_package_sha256':digest(package_path),
            'status':'ATTEMPT_RECORDED','recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    message=EmailMessage();message['From']='tkray@dph-pr-sgn-lap09.hhs.comacloud.net';message['To']=OWNER
    message['Subject']='Enrollment QC '+package['qc_decision']+' - '+package['report_date']+' - '+run_id
    message.set_content('Enrollment generation and required QC completed with no blocking failure.\n\n'
        'Report date: '+package['report_date']+'\nRun: '+run_id+'\nQC decision: '+package['qc_decision']+
        '\n\nAttached: comparison QC and technical QC. REVIEW notes remain in technical QC.\n'
        'The Windows automation will publish this approved run directly to OneDrive.\n'
        'This owner QC email is separate from the Friday distribution email.\n')
    for key in ('primary_qc','private_qc'):
        path=Path(artifacts[key]['path'])
        message.add_attachment(path.read_bytes(),maintype='application',
            subtype='vnd.openxmlformats-officedocument.spreadsheetml.sheet',filename=path.name)
    with marker.open('x') as f:json.dump(record,f,indent=2)
    try:
        with smtplib.SMTP('ITD-SMTP-OUT.STATE.MA.US',25,timeout=45) as smtp:
            if smtp.send_message(message):raise RuntimeError('QC recipient refused')
        record['status']='SMTP_ACCEPTED'
    except Exception as exc:
        record.update(status='FAILED_OR_UNCERTAIN',error=str(exc))
        result_path.write_text(json.dumps(record,indent=2)+'\n');raise
    result_path.write_text(json.dumps(record,indent=2)+'\n');return record

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-id',required=True)
    print(json.dumps(notify(p.parse_args().run_id),indent=2))
