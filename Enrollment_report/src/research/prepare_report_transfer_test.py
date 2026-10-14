"""Prepare an owner-only full-file transfer test draft. Never send email."""
import argparse,hashlib,json
from email.message import EmailMessage
from email import policy
from pathlib import Path

def prepare(folder):
    folder=Path(folder);report=folder/'ACO_Weekly_Enrollment_20261013_Visual_Review.xlsx'
    data=report.read_bytes();digest=hashlib.sha256(data).hexdigest()
    if digest!='f4883f08c3a3fb2ed51df78ffaba31a270ebe22dcac43a3e228bc78baaf04d9e':raise ValueError('Reviewed report differs')
    dest=folder/'Owner_Transfer_Test_Draft.eml'
    if dest.exists():raise FileExistsError('Preserve existing draft')
    msg=EmailMessage(policy=policy.SMTP)
    msg['To']='Tatyana.Kray@mass.gov'
    msg['Subject']='UPG TEST - ACO Weekly Enrollment QC - Full Report Transfer Test - October 13, 2026'
    msg['X-Unsent']='1'
    msg.set_content('Owner-only isolated full-report transfer test. This checks the existing test flow\'s ability to save the full attachment. Production publication and regular distribution remain pending.\nRun ID: 20261013T213300_8474\nAttachment SHA256: '+digest+'\n')
    msg.add_attachment(data,maintype='application',subtype='vnd.openxmlformats-officedocument.spreadsheetml.sheet',filename=report.name)
    package=msg.as_bytes();dest.write_bytes(package)
    receipt={'to':str(msg['To']),'subject':str(msg['Subject']),'run_id':'20261013T213300_8474','attachment':report.name,'attachment_sha256':digest,'attachment_bytes':len(data),'encoded_message_bytes':len(package),'send_enabled':False,'email_sent':False,'purpose':'Owner-only test of full report transfer into existing ACO_UPG_Test folder'}
    (folder/'TRANSFER_TEST_DRAFT.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--folder',required=True);prepare(p.parse_args().folder)
