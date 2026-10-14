"""Exercise cloud protocol and safety failures without credentials or network."""
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent / 'src/linux'))
import upload_report_graph as uploader


class Response(io.BytesIO):
    def __init__(self, value, status=200):
        super().__init__(value if isinstance(value, bytes) else json.dumps(value).encode())
        self.status = status

    def getcode(self):
        return self.status


class UploadTests(unittest.TestCase):
    def run_case(self, corrupt=False, changed=False, wrong_folder=False, incomplete=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            content = b'A' * (uploader.CHUNK + 17)
            report = root / 'report.xlsx'
            report.write_bytes(content)
            package = root / 'package.json'
            package.write_text('{}')
            p = {'run_id': '20261014T170002_11198', 'report_date': '20261014', 'qc_decision': 'PASS',
                 'artifacts': {'report': {'sha256': hashlib.sha256(content).hexdigest()}}}
            config = {'mode': 'isolated_test', 'destination_folder': 'ACO_UPG_Test',
                      'graph_base': 'https://graph.microsoft.com', 'drive_id': 'drive', 'folder_id': 'folder',
                      'onedrive_host': 'massgov-my.sharepoint.com'}
            calls = []
            reads = [0]

            def send(url, method='GET', payload=None, headers=None):
                calls.append((url, method, headers))
                if url.endswith('/items/folder'):
                    return Response({'id': 'folder', 'name': 'WRONG' if wrong_folder else 'ACO_UPG_Test', 'folder': {}})
                if url.endswith('/createUploadSession'):
                    self.assertEqual(json.loads(payload)['item']['@microsoft.graph.conflictBehavior'], 'fail')
                    return Response({'uploadUrl': 'https://massgov-my.sharepoint.com/upload'})
                if method == 'PUT':
                    self.assertNotIn('Authorization', headers)
                    if headers['Content-Range'].startswith('bytes 0-'):
                        return Response({'nextExpectedRanges': [str(uploader.CHUNK) + '-']}, 202)
                    return Response({'id': 'item', 'name': 'ACO_Cloud_Only_' + p['run_id'] + '.xlsx',
                                     'size': len(content)}, 202 if incomplete else 201)
                if url.endswith('/items/item'):
                    reads[0] += 1
                    return Response({'eTag': 'changed' if changed and reads[0] > 1 else 'stable',
                                     '@microsoft.graph.downloadUrl': 'https://massgov-my.sharepoint.com/download'})
                if url.endswith('/download'):
                    self.assertIsNone(headers)
                    return Response(b'corrupt' if corrupt else content)
                raise AssertionError('Unexpected endpoint')

            receipt = root / 'receipt.json'
            with patch.object(uploader, 'approved_report', return_value=(p, report)):
                if corrupt or changed or wrong_folder or incomplete:
                    with self.assertRaises((ValueError, RuntimeError)):
                        uploader.publish(config, package, receipt, lambda _: 'TEST_TOKEN', send)
                    self.assertFalse(receipt.exists())
                else:
                    result = uploader.publish(config, package, receipt, lambda _: 'TEST_TOKEN', send)
                    self.assertEqual(result['status'], 'CLOUD_BYTES_VERIFIED')
                    self.assertEqual(result['cloud_sha256'], p['artifacts']['report']['sha256'])
                    self.assertFalse(result['production_publication'])
                    self.assertNotIn('TEST_TOKEN', receipt.read_text())
                    with self.assertRaises(ValueError):
                        uploader.publish(config, package, receipt, lambda _: 'TEST_TOKEN', send)

    def test_verified_chunked_upload_and_readback(self):
        self.run_case()

    def test_corrupt_cloud_copy_rejected(self):
        self.run_case(corrupt=True)

    def test_concurrent_cloud_edit_rejected(self):
        self.run_case(changed=True)

    def test_wrong_destination_rejected(self):
        self.run_case(wrong_folder=True)

    def test_unconfirmed_final_chunk_rejected(self):
        self.run_case(incomplete=True)

    def test_failed_release_never_authenticates(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'blocked.json'
            p.write_text('{"release_allowed": false}')
            with self.assertRaises(ValueError):
                uploader.approved_report(p)


if __name__ == '__main__':
    unittest.main()
