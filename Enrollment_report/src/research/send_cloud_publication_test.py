"""One owner-only cloud transport test of an already approved report; no distribution."""
import argparse,datetime,json,re,smtplib
from email.message import EmailMessage
from pathlib import Path
from check_transfer_gate import digest

def send(package_path):
    package_path=Path(package_path);p=json.loads(package_path.read_text())
    if p.get('release_allowed') is not True or p.get('qc_decision') not in ('PASS','REVIEW'):raise ValueError('Release is blocked')
    run=p['run_id']
    if not re.fullmatch(r'[A-Za-z0-9_]{1,80}',run):raise ValueError('Invalid run')
    report=Path(p['artifacts']['report']['path']);qc=Path(p['artifacts']['final_qc']['path'])
    if digest(report)!=p['artifacts']['report']['sha256'] or digest(qc)!=p['artifacts']['final_qc']['sha256']:raise ValueError('Approved evidence changed')
    data=json.loads(qc.read_text())
    if data.get('run_id')!=run or data.get('qc_complete') is not True or data.get('failed_checks') or data.get('not_run_checks'):
        raise ValueError('QC incomplete or failing')
    audit=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/runs')/run
    attempt=audit/'CLOUD_ONLY_FULL_REPORT_TEST_ATTEMPT.json';result=audit/'CLOUD_ONLY_FULL_REPORT_TEST_RESULT.json'
    if attempt.exists():raise RuntimeError('Prior cloud test attempt exists; inspect it before retrying')
    filename='ACO_Cloud_Only_'+p['report_date']+'_Test.xlsx'
    message=EmailMessage();message['From']='tkray@dph-pr-sgn-lap09.hhs.comacloud.net';message['To']='Tatyana.Kray@mass.gov'
    message['Subject']='ACO ENROLLMENT APPROVED CLOUD REPORT TEST '+run
    message.set_content('Owner-only PC-independent OneDrive transfer test. This is not a distribution notification.\n'
        'The cloud flow saves this approved attachment only in ACO_UPG_Test.\nRun: '+run+
        '\nReport SHA256: '+p['artifacts']['report']['sha256']+'\nQC: '+p['qc_decision']+'\n')
    message.add_attachment(report.read_bytes(),maintype='application',
        subtype='vnd.openxmlformats-officedocument.spreadsheetml.sheet',filename=filename)
    raw=message.as_bytes()
    if len(raw)>49_000_000:raise ValueError('Full message exceeds cloud connector limit; no message sent')
    record={'run_id':run,'to':'Tatyana.Kray@mass.gov','subject':message['Subject'],'filename':filename,
        'message_bytes':len(raw),'report_bytes':report.stat().st_size,'report_sha256':digest(report),
        'status':'ATTEMPT_RECORDED','recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'production_publication':False,'distribution_email':False}
    with attempt.open('x') as f:json.dump(record,f,indent=2)
    try:
        with smtplib.SMTP('ITD-SMTP-OUT.STATE.MA.US',25,timeout=120) as smtp:
            if smtp.send_message(message):raise RuntimeError('Owner recipient refused')
        record['status']='SMTP_ACCEPTED'
    except Exception as exc:
        record.update(status='FAILED_OR_UNCERTAIN',error=str(exc));result.write_text(json.dumps(record,indent=2));raise
    result.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--package',required=True);send(p.parse_args().package)
