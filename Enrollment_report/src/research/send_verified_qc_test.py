#!/usr/bin/env python3
"""Send one explicitly authorized QC-owner test through existing SAS SMTP."""
import argparse,datetime,hashlib,json,os,re,subprocess
from pathlib import Path

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
    return h.hexdigest()
def send(folder,draft_name='Email_Draft'):
    if Path(draft_name).name!=draft_name or draft_name in ('','.','..'):raise ValueError('Invalid draft folder')
    folder=Path(folder);draft=folder/draft_name
    receipt=json.loads((draft/'EMAIL_DRAFT_RECEIPT.json').read_text())
    qc=json.loads((folder/'FINAL_QC.json').read_text())
    if receipt['to'].lower()!='tatyana.kray@mass.gov':raise ValueError('Unexpected test recipient')
    if not qc['qc_complete'] or qc['run_id']!=receipt['run_id']:raise ValueError('QC is incomplete or identity differs')
    if Path(receipt['attachment']).name!=receipt['attachment']:raise ValueError('Invalid attachment name')
    for p,expected in [(folder/receipt['attachment'],receipt['attachment_sha256']),(folder/'FINAL_QC.json',receipt['final_qc_sha256']),(draft/'QC_Email_Body.txt',receipt['body_sha256'])]:
        if sha(p)!=expected:raise ValueError('Send-time evidence hash mismatch: '+p.name)
    template=(draft/'Send_Final_QC_DISABLED.sas').read_text()
    if template.count('%let QC_EMAIL_SEND=NO;')!=1:raise ValueError('Unexpected send template gate')
    if '%let QC_EMAIL_TO='+receipt['to']+';' not in template:raise ValueError('Template recipient differs')
    if '%let QC_EMAIL_SUBJECT='+receipt['subject']+';' not in template:raise ValueError('Template subject differs')
    for name in ('QC_Email_Attempted.txt','EMAIL_SUBMISSION.json','Send_Final_QC_APPROVED.sas'):
        if (draft/name).exists():raise FileExistsError('Prior attempt exists; inspect status instead of resending')
    approved=draft/'Send_Final_QC_APPROVED.sas'
    with approved.open('x') as f:
        f.write(template.replace('%let QC_EMAIL_SEND=NO;','%let QC_EMAIL_SEND=YES;',1))
    log=draft/'QC_Email_Submission.log'
    exe='/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas'
    env=dict(os.environ);env['LD_LIBRARY_PATH']='/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:'+env.get('LD_LIBRARY_PATH','')
    timed_out=False
    try:
        result=subprocess.run([exe,'-nodms','-noterminal','-sysin',str(approved),'-log',str(log),'-print',str(draft/'QC_Email_Submission.lst')],env=env,timeout=180)
        rc=result.returncode
    except subprocess.TimeoutExpired:rc=None;timed_out=True
    content=log.read_text(errors='replace') if log.exists() else ''
    errors=re.findall(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:.*$',content,re.M)
    confirmed=rc==0 and not errors and 'NOTE: QC SMTP submission completed. This does not establish mailbox delivery.' in content and (draft/'QC_Email_Attempted.txt').exists()
    record={'run_id':qc['run_id'],'to':receipt['to'],'subject':receipt['subject'],'attachment_sha256':receipt['attachment_sha256'],'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sas_return_code':rc,'timed_out':timed_out,'status':'SUBMITTED' if confirmed else 'FAILED_OR_UNCERTAIN','mailbox_delivery_confirmed':False,'errors':errors,'sas_log_sha256':sha(log) if log.exists() else None,'authorized_sender_sha256':sha(approved),'retry_policy':'No automatic resend; inspect attempt/submission state first.'}
    (draft/'EMAIL_SUBMISSION.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record,indent=2));return 0 if confirmed else 1
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--qc-folder',required=True);p.add_argument('--send',action='store_true')
    p.add_argument('--draft-name',default='Email_Draft')
    a=p.parse_args()
    if not a.send:p.error('--send is required; no mail sent')
    raise SystemExit(send(a.qc_folder,a.draft_name))
