import json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
import send_qc_email as mail
from check_transfer_gate import digest

class QCEmailTests(unittest.TestCase):
    def prepare(self,root,run):
        audit=root/'runs'/run;audit.mkdir(parents=True)
        release=root/'releases'/run;release.mkdir(parents=True)
        qc=audit/'FINAL_QC.json';qc.write_text(json.dumps({'run_id':run,'report_date':'20261014',
          'qc_complete':True,'failed_checks':[],'not_run_checks':[],'final_qc_decision':'REVIEW'}))
        primary=audit/'primary.xlsx';primary.write_bytes(b'primary fixture')
        technical=audit/'technical.xlsx';technical.write_bytes(b'technical fixture')
        package={'run_id':run,'report_date':'20261014','release_allowed':True,'qc_decision':'REVIEW',
            'artifacts':{k:{'path':str(p),'sha256':digest(p)} for k,p in
                         [('final_qc',qc),('primary_qc',primary),('private_qc',technical)]}}
        path=release/'TRANSFER_PACKAGE.json';path.write_text(json.dumps(package));return path
    def test_owner_attachments_idempotency_and_failure_gate(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            root=Path(folder);package=self.prepare(root,'fixture')
            with patch.object(mail,'ROOT',root),patch.object(mail.smtplib,'SMTP') as smtp:
                client=smtp.return_value.__enter__.return_value;client.send_message.return_value={}
                self.assertEqual(mail.notify('fixture')['status'],'SMTP_ACCEPTED')
                message=client.send_message.call_args[0][0]
                self.assertEqual(message['To'],'Tatyana.Kray@mass.gov')
                self.assertEqual(len(list(message.iter_attachments())),2)
                self.assertEqual(mail.notify('fixture')['status'],'ALREADY_SUBMITTED')
                self.assertEqual(client.send_message.call_count,1)
                data=json.loads(package.read_text());data['qc_decision']='FAIL';package.write_text(json.dumps(data))
                with self.assertRaises(ValueError):mail.notify('fixture')
                self.assertEqual(client.send_message.call_count,1)
                self.prepare(root,'uncertain');client.send_message.side_effect=OSError('fixture connection failure')
                with self.assertRaises(OSError):mail.notify('uncertain')
                with self.assertRaises(RuntimeError):mail.notify('uncertain')
                self.assertEqual(client.send_message.call_count,2)
if __name__=='__main__':unittest.main()
