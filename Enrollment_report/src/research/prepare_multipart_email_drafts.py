"""Prepare four owner-only transfer emails; never connects or sends."""
import base64
import hashlib
import json
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    parts_dir = root / 'Validation/20261013T213300_8474/Transfer_Parts_v1'
    manifest = json.loads((parts_dir / 'TRANSFER_MANIFEST.json').read_text())
    parts = manifest['parts']
    payloads = [(parts_dir / part['name']).read_bytes() for part in parts]
    for part, payload in zip(parts, payloads):
        if len(payload) != part['bytes'] or hashlib.sha256(payload).hexdigest() != part['sha256']:
            raise ValueError('Part differs: ' + part['name'])
    report = base64.b64decode(b''.join(payloads), validate=True)
    if len(report) != manifest['report_bytes'] or hashlib.sha256(report).hexdigest() != manifest['report_sha256']:
        raise ValueError('Reconstructed report differs')
    destination = parts_dir.parent / 'Multipart_Email_Drafts_v1'
    destination.mkdir(exist_ok=False)
    drafts = []
    for index, (part, payload) in enumerate(zip(parts, payloads), 1):
        msg = EmailMessage(policy=policy.SMTP)
        msg['To'] = 'Tatyana.Kray@mass.gov'
        msg['Subject'] = 'ACO ENROLLMENT TRANSFER TEST 20261013_213300 PART {}/4{}'.format(index, ' COMPLETE' if index == 4 else '')
        msg['X-Unsent'] = '1'
        msg.set_content('Owner-only enrollment transfer test, part {}/4. Save in the existing ACO_UPG_Test folder. No distribution or production cutover.'.format(index))
        msg.add_attachment(payload, maintype='application', subtype='octet-stream', filename=part['name'])
        raw = msg.as_bytes()
        parsed = BytesParser(policy=policy.SMTP).parsebytes(raw)
        attachments = list(parsed.iter_attachments())
        if len(attachments) != 1 or attachments[0].get_payload(decode=True) != payload:
            raise ValueError('MIME round trip differs')
        if len(raw) >= 20_000_000:
            raise ValueError('Draft exceeds conservative test size')
        filename = 'Part_{:03d}_UNSENT.eml'.format(index)
        (destination / filename).write_bytes(raw)
        drafts.append({'filename': filename, 'subject': str(msg['Subject']), 'message_bytes': len(raw), 'attachment': part['name'], 'attachment_sha256': part['sha256']})
    receipt = {'run_id': manifest['run_id'], 'to': 'Tatyana.Kray@mass.gov', 'report_sha256': manifest['report_sha256'], 'reconstruction_verified': True, 'email_sent': False, 'drafts': drafts, 'send_sequence': 'Send parts 1-3 separately; confirm all three flow saves succeeded before sending part 4 COMPLETE. Verify reconstructed workbook SHA256 before any publication.'}
    (destination / 'DRAFT_RECEIPT.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
