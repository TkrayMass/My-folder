"""One owner-only alert for a recorded failed enrollment pipeline; no attachments."""
import argparse,datetime,json,re,smtplib
from email.message import EmailMessage
from pathlib import Path

def notify(run_id):
    if not re.fullmatch(r'[A-Za-z0-9_]{1,80}',run_id):raise ValueError('Invalid run ID')
    audit=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/runs')/run_id
    status=dict(line.split('=',1) for line in (audit/'PIPELINE_STATUS.txt').read_text().splitlines())
    if status.get('EXIT_CODE') in (None,'0'):raise ValueError('Alert requires a recorded failure')
    marker=audit/'FAILURE_ALERT_ATTEMPT.json'
    if marker.exists():return {'status':'PRIOR_ATTEMPT_RETAINED'}
    record={'run_id':run_id,'to':'Tatyana.Kray@mass.gov','status':'ATTEMPT_RECORDED',
            'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    with marker.open('x') as f:json.dump(record,f,indent=2)
    message=EmailMessage()
    message['From']='tkray@dph-pr-sgn-lap09.hhs.comacloud.net'
    message['To']=record['to'];message['Subject']='Enrollment automation FAILED - '+run_id
    message.set_content('Enrollment run '+run_id+' stopped with exit code '+status['EXIT_CODE']+
        '. No report release was completed by this attempt. Review retained audit evidence: '+str(audit))
    try:
        with smtplib.SMTP('ITD-SMTP-OUT.STATE.MA.US',25,timeout=60) as smtp:smtp.send_message(message)
        record['status']='SMTP_ACCEPTED'
    except Exception as exc:
        record['status']='FAILED_OR_UNCERTAIN';record['error']=str(exc)
    (audit/'FAILURE_ALERT_RESULT.json').write_text(json.dumps(record,indent=2)+'\n')
    return record

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-id',required=True)
    print(json.dumps(notify(p.parse_args().run_id),indent=2))
