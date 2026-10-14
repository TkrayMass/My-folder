"""Python 3.6-compatible, certificate-authenticated Linux -> OneDrive test uploader.

No interactive login, email, Windows sync, or credentials in receipts.
Not installed in the production schedule. Requires an IT-provisioned identity.
"""
import argparse
import base64
import datetime
import hashlib
import json
import re
import subprocess
import time
import uuid
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from check_transfer_gate import digest, validate

CHUNK = 10 * 1024 * 1024  # Multiple of Graph's 320 KiB fragment requirement.
PAIRS = {'https://graph.microsoft.com': 'https://login.microsoftonline.com',
         'https://graph.microsoft.us': 'https://login.microsoftonline.us',
         'https://dod-graph.microsoft.us': 'https://login.microsoftonline.us'}


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')


def request(url, method='GET', payload=None, headers=None):
    try:
        return urlopen(Request(url, data=payload, headers=headers or {}, method=method), timeout=120)
    except HTTPError as exc:
        # HTTP errors can contain bearer upload URLs. Do not print response bodies/URLs.
        raise RuntimeError('Cloud request rejected: HTTP {}'.format(exc.code)) from None


def certificate_token(c):
    graph = c['graph_base']
    if graph not in PAIRS:
        raise ValueError('Unrecognized Microsoft cloud')
    for key in ('tenant_id', 'client_id'):
        uuid.UUID(c[key])
    endpoint = PAIRS[graph] + '/' + c['tenant_id'] + '/oauth2/v2.0/token'
    thumb = bytes.fromhex(c['certificate_sha1'])
    if len(thumb) != 20:
        raise ValueError('Expected certificate SHA1 thumbprint')
    now = int(time.time())
    header = {'alg': 'RS256', 'typ': 'JWT', 'x5t': b64(thumb)}
    claims = {'aud': endpoint, 'iss': c['client_id'], 'sub': c['client_id'],
              'jti': str(uuid.uuid4()), 'nbf': now - 30, 'exp': now + 300}
    unsigned = (b64(json.dumps(header).encode()) + '.' + b64(json.dumps(claims).encode())).encode()
    signed = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', c['private_key_path']],
                            input=unsigned, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if signed.returncode:
        raise RuntimeError('Certificate signing failed; check protected key provisioning')
    body = urlencode({'client_id': c['client_id'], 'scope': graph + '/.default',
                      'grant_type': 'client_credentials',
                      'client_assertion_type': 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
                      'client_assertion': unsigned.decode() + '.' + b64(signed.stdout)}).encode()
    with request(endpoint, 'POST', body, {'Content-Type': 'application/x-www-form-urlencoded'}) as response:
        return json.load(response)['access_token']


def approved_report(package_path):
    p = json.loads(Path(package_path).read_text())
    if p.get('release_allowed') is not True:
        raise ValueError('Release blocked')
    a = p['artifacts']
    for entry in a.values():
        if digest(entry['path']) != entry['sha256'] or Path(entry['path']).stat().st_size != entry['bytes']:
            raise ValueError('Release artifact changed')
    gate = validate(a['run_manifest']['path'], a['final_qc']['path'], a['report']['path'])
    if (p['run_id'], p['report_date'], p['qc_decision']) != (gate['run_id'], gate['report_date'], gate['qc_decision']):
        raise ValueError('Package identity differs from validated QC')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,80}', p['run_id']):
        raise ValueError('Invalid run ID')
    return p, Path(a['report']['path'])


def publish(c, package_path, receipt_path, token_provider=certificate_token, send=request):
    # Intentionally test-only until identity and byte-for-byte readback are proven.
    if c.get('mode') != 'isolated_test' or c.get('destination_folder') != 'ACO_UPG_Test':
        raise ValueError('Only isolated ACO_UPG_Test publication is enabled')
    if c['graph_base'] not in PAIRS:
        raise ValueError('Invalid Graph endpoint')
    p, report = approved_report(package_path)
    receipt = Path(receipt_path)
    if receipt.exists():
        raise ValueError('Receipt exists; inspect prior test before repeating')
    token = token_provider(c)
    auth = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
    root = c['graph_base'] + '/v1.0/drives/' + quote(c['drive_id'], safe='')
    parent = root + '/items/' + quote(c['folder_id'], safe='')
    with send(parent, headers=auth) as response:
        folder = json.load(response)
    if folder.get('id') != c['folder_id'] or folder.get('name') != 'ACO_UPG_Test' or 'folder' not in folder:
        raise ValueError('Configured destination is not the expected test folder')
    name = 'ACO_Cloud_Only_' + p['run_id'] + '.xlsx'
    body = json.dumps({'item': {'@microsoft.graph.conflictBehavior': 'fail', 'name': name}}).encode()
    with send(parent + ':/' + quote(name, safe='') + ':/createUploadSession', 'POST', body, auth) as response:
        session = json.load(response)
    upload = session['uploadUrl']
    parsed = urlparse(upload)
    # Preauthenticated URL returned by Graph; never attach Graph Authorization to it.
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError('Invalid upload session URL')
    size = report.stat().st_size
    item = None
    with report.open('rb') as source:
        offset = 0
        while offset < size:
            block = source.read(CHUNK)
            if not block:
                raise ValueError('Report truncated during upload')
            headers = {'Content-Length': str(len(block)),
                       'Content-Range': 'bytes {}-{}/{}'.format(offset, offset + len(block) - 1, size)}
            with send(upload, 'PUT', block, headers) as response:
                status = response.getcode()
                result = json.load(response)
            offset += len(block)
            if offset < size:
                if status != 202 or result.get('nextExpectedRanges', [''])[0].split('-')[0] != str(offset):
                    raise RuntimeError('Upload offset not confirmed; no automatic retry')
            elif status in (200, 201):
                item = result
            else:
                raise RuntimeError('Upload completion unconfirmed')
    if not item or item.get('name') != name or item.get('size') != size:
        raise RuntimeError('Cloud file identity/size mismatch')
    item_url = root + '/items/' + quote(item['id'], safe='')
    with send(item_url, headers=auth) as response:
        metadata = json.load(response)
    download = metadata['@microsoft.graph.downloadUrl']
    d = urlparse(download)
    allowed_host = c['onedrive_host'].lower()
    if (d.scheme != 'https' or d.hostname != allowed_host or d.username or d.password
            or d.port not in (None, 443)):
        raise ValueError('Unexpected OneDrive readback host')
    hasher = hashlib.sha256()
    read_bytes = 0
    with send(download) as response:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            hasher.update(block)
            read_bytes += len(block)
    expected = p['artifacts']['report']['sha256']
    if read_bytes != size or hasher.hexdigest() != expected or digest(report) != expected:
        raise RuntimeError('Cloud readback or immutable source checksum mismatch')
    with send(item_url, headers=auth) as response:
        after = json.load(response)
    if after.get('eTag') != metadata.get('eTag') or not after.get('eTag'):
        raise RuntimeError('Cloud file changed during verification')
    record = {'status': 'CLOUD_BYTES_VERIFIED', 'run_id': p['run_id'], 'report_date': p['report_date'],
              'report_sha256': expected, 'cloud_sha256': hasher.hexdigest(), 'bytes': size,
              'drive_id': c['drive_id'], 'folder_id': c['folder_id'], 'item_id': item['id'],
              'filename': name, 'etag': after['eTag'], 'qc_decision': p['qc_decision'],
              'package_sha256': digest(package_path), 'production_publication': False,
              'distribution_email_sent': False,
              'verified_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    with receipt.open('x') as target:
        json.dump(record, target, indent=2)
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--package', required=True)
    parser.add_argument('--receipt', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(publish(json.loads(Path(args.config).read_text()), args.package, args.receipt), indent=2))
    except Exception as exc:
        # Do not disclose authenticated URLs, assertions, tokens or remote response bodies.
        print('CLOUD_PUBLICATION_FAILED: ' + type(exc).__name__)
        raise SystemExit(1)
