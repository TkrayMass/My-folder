#!/usr/bin/env python3
"""Prepare a QC-owner email draft and disabled SAS sender; never send mail."""
import argparse,datetime,hashlib,json
from pathlib import Path
from email.message import EmailMessage
from email import policy

REQUIRED=('workbook_structure','upstream_totals','row_preservation','percentage_denominators','detail_reconciliation','cross_sheet_reconciliation','baseline_business_policy')
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
def prepare(folder,draft_name='Email_Draft',smtp_relay=None):
    folder=Path(folder);receipt=json.loads((folder/'QC_WITH_DETAIL_RECEIPT.json').read_text())
    if Path(draft_name).name!=draft_name or draft_name in ('','.','..'):raise ValueError('Invalid draft folder')
    if smtp_relay and smtp_relay.upper()!='ITD-SMTP-OUT.STATE.MA.US':raise ValueError('Unexpected relay')
    if Path(receipt['workbook']).name!=receipt['workbook']:raise ValueError('Invalid workbook name')
    workbook=folder/receipt['workbook'];qcfile=folder/'FINAL_QC.json'
    if sha(workbook)!=receipt['workbook_sha256'] or sha(qcfile)!=receipt['final_qc_sha256']:raise ValueError('QC package changed since receipt')
    qc=json.loads(qcfile.read_text())
    if qc['run_id']!=receipt['run_id'] or qc['final_qc_decision']!=receipt['final_qc_decision']:raise ValueError('QC receipt identity mismatch')
    states={c['check']:c['status'] for c in qc['checks']}
    if any(k not in states for k in REQUIRED):raise ValueError('Required check missing')
    counts={status:sum(states[k]==status for k in REQUIRED) for status in ('PASS','REVIEW','FAIL','NOT_RUN')}
    date=datetime.datetime.strptime(qc['report_date'],'%Y%m%d').strftime('%B %d, %Y')
    subject='UPG TEST - ACO Weekly Enrollment QC '+qc['final_qc_decision']+' - '+date
    if smtp_relay:subject+=' - Relay Test'
    recipient='Tatyana.Kray@mass.gov'
    lines=['ACO Weekly Enrollment QC: '+qc['final_qc_decision'],'Report date: '+date,'Required business checks: {PASS} PASS, {REVIEW} REVIEW, {FAIL} FAIL, {NOT_RUN} NOT RUN.'.format(**counts),'']
    if states['detail_reconciliation']=='REVIEW':lines.append('Review: displayed counts and percentages have reconciliation differences within calculated rounding bounds.')
    if states['baseline_business_policy']=='REVIEW':lines.append('Review: the initial distributed-baseline archive lacks a historical submission hash receipt; see QC Detail for any numerical findings.')
    for c in qc['checks']:
        if c['status'] in ('FAIL','NOT_RUN'):lines.append('Action required: '+c['check'].replace('_',' ')+' - '+c['status'])
    lines+=['','The attached workbook contains QC Summary and filterable QC Detail with values, differences, limits and reasons.','This is an isolated test package. Report publication and regular distribution remain disabled.','Run ID: '+qc['run_id']]
    body='\n'.join(lines)+'\n'
    draftdir=folder/draft_name
    if draftdir.exists():raise FileExistsError('Do not overwrite an existing email draft')
    draftdir.mkdir()
    (draftdir/'QC_Email_Body.txt').write_text(body)
    msg=EmailMessage(policy=policy.SMTP);msg['To']=recipient;msg['Subject']=subject;msg['X-Unsent']='1'
    msg.set_content(body)
    msg.add_attachment(workbook.read_bytes(),maintype='application',subtype='vnd.openxmlformats-officedocument.spreadsheetml.sheet',filename=workbook.name)
    (draftdir/'QC_Email_Draft.eml').write_bytes(msg.as_bytes())
    remote='/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/runs/'+qc['run_id']+'/qc_versions/'+folder.name
    sender='''/* QC-owner test notification only. Default is disabled. No report generation. */
%let QC_EMAIL_SEND=NO;
%let QC_EMAIL_TO=RECIPIENT;
%let QC_EMAIL_SUBJECT=__SUBJECT__;
%let QC_EMAIL_BODY=REMOTE/Email_Draft/QC_Email_Body.txt;
%let QC_EMAIL_ATTACH=REMOTE/WORKBOOK;
%let QC_EMAIL_ATTEMPT=REMOTE/Email_Draft/QC_Email_Attempted.txt;
%macro send_final_qc;
 %if %upcase(%superq(QC_EMAIL_SEND)) ne YES %then %do;
  %put NOTE: QC email sender is disabled. No email attempted.; %return;
 %end;
 %if %sysfunc(fileexist(%superq(QC_EMAIL_ATTEMPT))) %then %do;
  %put ERROR: QC email attempt already recorded. Inspect submission status before any resend.; %return;
 %end;
 %if not %sysfunc(fileexist(%superq(QC_EMAIL_BODY))) or not %sysfunc(fileexist(%superq(QC_EMAIL_ATTACH))) %then %do;
  %put ERROR: Required QC email body or attachment missing.; %return;
 %end;
 filename QCATTM "&QC_EMAIL_ATTEMPT.";
 data _null_; file QCATTM; put "RunID=RUNID"; put "Status=ATTEMPT_RECORDED_BEFORE_SUBMISSION"; run;
 %if &syserr > 4 %then %do; %put ERROR: Could not retain email attempt record. No mail attempted.; %return; %end;
 options emailsys=smtp;
 filename QCBODY "&QC_EMAIL_BODY.";
 filename QCMAIL email to=("&QC_EMAIL_TO.") subject="&QC_EMAIL_SUBJECT."
  attach=("&QC_EMAIL_ATTACH." content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") type="text/plain";
 data _null_; infile QCBODY lrecl=32767; file QCMAIL; input; put _infile_; run;
 filename QCMAIL clear;
 %if &syserr > 4 or &syscc > 4 %then %do; %put ERROR: QC submission uncertain or failed. Attempt record retained. Do not automatically retry.; %return; %end;
 %put NOTE: QC SMTP submission completed. This does not establish mailbox delivery.;
%mend;
%send_final_qc;
'''
    for old,new in [('RECIPIENT',recipient),('__SUBJECT__',subject),('REMOTE',remote),('WORKBOOK',workbook.name),('RUNID',qc['run_id'])]:sender=sender.replace(old,new)
    sender=sender.replace('/Email_Draft/', '/'+draft_name+'/')
    if smtp_relay:sender=sender.replace('options emailsys=smtp;','options emailsys=smtp emailhost="'+smtp_relay+'" emailport=25;')
    (draftdir/'Send_Final_QC_DISABLED.sas').write_text(sender)
    record={'run_id':qc['run_id'],'to':recipient,'subject':subject,'attachment':workbook.name,'attachment_sha256':sha(workbook),'final_qc_sha256':sha(qcfile),'body_sha256':sha(draftdir/'QC_Email_Body.txt'),'eml_sha256':sha(draftdir/'QC_Email_Draft.eml'),'send_enabled':False,'status':'DRAFT_ONLY','limitations':['The disabled SAS template still needs a send-time package verifier and controlled delivery test before production use.','Attempt marker blocks blind retries after uncertain submission; no delivery is claimed.']}
    (draftdir/'EMAIL_DRAFT_RECEIPT.json').write_text(json.dumps(record,indent=2)+'\n')
    print(body);print('Prepared draft only; no email sent.')
    return draftdir
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--qc-folder',required=True);p.add_argument('--draft-name',default='Email_Draft');p.add_argument('--smtp-relay');a=p.parse_args();prepare(a.qc_folder,a.draft_name,a.smtp_relay)
