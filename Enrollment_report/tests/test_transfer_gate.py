import copy
import json
import sys
from contextlib import nullcontext
import uuid
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / 'src/linux'))
from check_transfer_gate import REQUIRED, digest, validate


class TransferGateTests(unittest.TestCase):
    def test_warning_allowed_but_candidate_not_published_and_invalid_evidence_blocked(self):
        fixture_dir = Path(__file__).parent / 'Validation' / ('transfer_gate_' + uuid.uuid4().hex)
        fixture_dir.mkdir()
        with nullcontext(str(fixture_dir)) as directory:
            root = Path(directory)
            report = root / 'report.xlsx'
            report.write_bytes(b'transport fixture')
            manifest = root / 'RUN_MANIFEST.json'
            manifest.write_text(json.dumps({'run_id': 'test_run', 'report_date': '20261013',
                'technical_status': 'PASS', 'failures': [], 'publication_allowed': False,
                'artifacts': [{'path': 'test_REGXSA.xlsx', 'sha256': digest(report)}]}))
            qc_path = root / 'FINAL_QC.json'
            qc = {'run_id': 'test_run', 'report_date': '20261013', 'qc_complete': True,
                  'failed_checks': [], 'not_run_checks': [], 'final_qc_decision': 'REVIEW',
                  'checks': [{'check': key, 'status': 'REVIEW' if key == 'detail_reconciliation' else 'PASS',
                              'evidence_sha256': digest(manifest)} for key in sorted(REQUIRED)]}
            qc_path.write_text(json.dumps(qc))
            result = validate(manifest, qc_path, report)
            self.assertTrue(result['staging_allowed'])
            self.assertFalse(result['publication_allowed'])
            for field, value in [('run_id', 'another_run'), ('qc_complete', False),
                                 ('failed_checks', ['upstream_totals'])]:
                changed = copy.deepcopy(qc)
                changed[field] = value
                qc_path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    validate(manifest, qc_path, report)
            qc_path.write_text(json.dumps(qc))
            report.write_bytes(b'changed report')
            with self.assertRaises(ValueError):
                validate(manifest, qc_path, report)
            manifest.write_text(manifest.read_text() + '\n')
            with self.assertRaises(ValueError):
                validate(manifest, qc_path, report)


if __name__ == '__main__':
    unittest.main()
