import importlib.util,json,tempfile,unittest
from pathlib import Path
root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('qc',root.parent/'src/linux'/'finalize_business_qc.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
temp_root=root/'Validation'/'business_qc_tests';temp_root.mkdir(exist_ok=True)
assert temp_root.resolve().is_relative_to(root)
class QCGate(unittest.TestCase):
    def fixture(self,t):
        run=t/'RUN_MANIFEST.json';run.write_text(json.dumps({'run_id':'run1','report_date':'20261013','technical_status':'PASS','artifacts':[{'path':'fixture_REGXSA.xlsx','sha256':'fixture-report-hash'}]}))
        comp=t/'comparison';comp.mkdir();csv=comp/'Distributed_Baseline_Comparison.csv';csv.write_text('evidence')
        (comp/'BASELINE_COMPARISON.json').write_text(json.dumps({'run_id':'run1','run_manifest_sha256':m.sha(run),'comparison_sha256':m.sha(csv)}))
        return run,comp
    def test_missing_controls_block_technical_pass(self):
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);run,comp=self.fixture(t);r=m.finalize(run,comp,None,t/'final')
            self.assertEqual(r['final_qc_decision'],'FAIL');self.assertEqual(len(r['not_run_checks']),len(m.REQUIRED));self.assertFalse(r['qc_complete'])
    def test_hash_verified_review_kept_visible(self):
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);run,comp=self.fixture(t);e=t/'evidence.json';e.write_text('control evidence')
            controls=t/'Business_Checks.json';controls.write_text(json.dumps({'run_id':'run1','run_manifest_sha256':m.sha(run),'report_sha256':'fixture-report-hash','checks':[{'check':c,'status':'REVIEW' if c=='baseline_business_policy' else 'PASS','evidence':[{'name':e.name,'sha256':m.sha(e)}]} for c in m.REQUIRED]}))
            r=m.finalize(run,comp,controls,t/'final');self.assertEqual(r['final_qc_decision'],'REVIEW');self.assertTrue(r['qc_complete']);self.assertFalse(r['publication_allowed'])
    def test_other_run_cannot_authorize_current_run(self):
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);run,comp=self.fixture(t);controls=t/'Business_Checks.json';controls.write_text(json.dumps({'run_id':'old_run','checks':[]}))
            with self.assertRaisesRegex(ValueError,'another run'):m.finalize(run,comp,controls,t/'final')
if __name__=='__main__':unittest.main()
