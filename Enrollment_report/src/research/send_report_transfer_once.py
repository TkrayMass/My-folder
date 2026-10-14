"""One explicitly approved owner-only full-report transfer test. No retries."""
import datetime,hashlib,json,smtplib
from email import policy
from email.parser import BytesParser
from email.utils import formatdate,make_msgid
from pathlib import Path

ROOT=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX')
FOLDER=ROOT/'runs/20261013T213300_8474/Owner_Transfer_Test_v1'
QC=ROOT/'runs/20261013T213300_8474/qc_versions/Final_v2/FINAL_QC.json'
OWNER='Tatyana.Kray@mass.gov'
SENDER='tkray@dph-pr-sgn-lap09.hhs.comacloud.net'

def main():
    receipt=json.loads((FOLDER/'TRANSFER_TEST_DRAFT.json').read_text())
    qc=json.loads(QC.read_text())
    if not qc['qc_complete'] or qc['failed_checks'] or qc['not_run_checks']:raise ValueError('QC blocks transfer test')
    if qc['run_id']!=receipt['run_id'] or receipt['to']!=OWNER:raise ValueError('Identity differs')
    msg=BytesParser(policy=policy.SMTP).parsebytes((FOLDER/'Owner_Transfer_Test_Draft.eml').read_bytes())
    if str(msg['To'])!=OWNER or str(msg['Subject'])!=receipt['subject']:raise ValueError('Recipient or subject changed')
    attachments=list(msg.iter_attachments())
    if len(attachments)!=1 or hashlib.sha256(attachments[0].get_payload(decode=True)).hexdigest()!=receipt['attachment_sha256']:raise ValueError('Attachment differs')
    del msg['X-Unsent'];msg['From']=SENDER;msg['Date']=formatdate(localtime=False);msg['Message-ID']=make_msgid(domain='hhs.comacloud.net')
    record={'run_id':qc['run_id'],'to':OWNER,'message_id':str(msg['Message-ID']),'attachment_sha256':receipt['attachment_sha256'],'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'ATTEMPT_RECORDED','mailbox_delivery_confirmed':False}
    with (FOLDER/'ATTEMPT.json').open('x') as f:json.dump(record,f,indent=2)
    try:
        with smtplib.SMTP('ITD-SMTP-OUT.STATE.MA.US',25,timeout=120) as smtp:
            refused=smtp.sendmail(SENDER,[OWNER],msg.as_bytes())
            if refused:raise ValueError('Recipient refused')
        record['status']='SMTP_ACCEPTED'
    except Exception as e:
        record['status']='FAILED_OR_UNCERTAIN';record['error']=str(e)
    (FOLDER/'SUBMISSION.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record,indent=2))
    return 0 if record['status']=='SMTP_ACCEPTED' else 1

if __name__=='__main__':raise SystemExit(main())
