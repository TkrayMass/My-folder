"""Validate same-run QC and report identity before native XLSX transfer."""
import argparse
import hashlib
import json
from pathlib import Path

REQUIRED = {'technical_completion', 'baseline_comparison_identity', 'workbook_structure',
            'upstream_totals', 'row_preservation', 'percentage_denominators',
            'detail_reconciliation', 'cross_sheet_reconciliation', 'baseline_business_policy'}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def validate(manifest_path, qc_path, report_path, format_receipt=None):
    run = json.loads(Path(manifest_path).read_text(encoding='utf-8-sig'))
    qc = json.loads(Path(qc_path).read_text(encoding='utf-8-sig'))
    if run.get('technical_status') != 'PASS' or run.get('failures'):
        raise ValueError('Technical run failed')
    if not run.get('run_id') or not run.get('report_date'):
        raise ValueError('Missing run identity')
    if (qc.get('run_id'), qc.get('report_date')) != (run['run_id'], run['report_date']):
        raise ValueError('QC belongs to another run/date')
    checks = qc.get('checks', [])
    ids = [c.get('check') for c in checks]
    if len(ids) != len(set(ids)) or not REQUIRED.issubset(ids):
        raise ValueError('Missing or duplicate required QC controls')
    if qc.get('qc_complete') is not True or qc.get('failed_checks') or qc.get('not_run_checks'):
        raise ValueError('QC incomplete or failed')
    if any(c.get('status') not in ('PASS', 'REVIEW') for c in checks):
        raise ValueError('Blocking or unknown control status')
    expected_decision = 'REVIEW' if any(c['status'] == 'REVIEW' for c in checks) else 'PASS'
    if qc.get('final_qc_decision') != expected_decision:
        raise ValueError('QC decision contradicts controls')
    technical = next(c for c in checks if c['check'] == 'technical_completion')
    if technical.get('evidence_sha256') != digest(manifest_path):
        raise ValueError('QC is bound to a different manifest')
    reports = [a for a in run.get('artifacts', [])
               if Path(a['path']).name.endswith('_REGXSA.xlsx')]
    if len(reports) != 1:
        raise ValueError('Expected one completed native report')
    actual = digest(report_path)
    if actual != reports[0]['sha256']:
        if not format_receipt:
            raise ValueError('Report checksum differs')
        receipt = json.loads(Path(format_receipt).read_text(encoding='utf-8-sig'))
        if (receipt.get('source_sha256') != reports[0]['sha256'] or
                receipt.get('result_sha256') != actual or
                receipt.get('all_nonstyle_members_identical') is not True):
            raise ValueError('Formatting receipt does not bind report to completed run')
    return {'run_id': run['run_id'], 'report_date': run['report_date'],
            'qc_decision': expected_decision, 'report_sha256': actual,
            'staging_allowed': True,
            'publication_allowed': run.get('publication_allowed') is True and
                                   qc.get('publication_allowed') is True,
            'cloud_sync_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-manifest', required=True)
    parser.add_argument('--final-qc', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--format-receipt')
    args = parser.parse_args()
    print(json.dumps(validate(args.run_manifest, args.final_qc, args.report,
                              args.format_receipt), indent=2))
