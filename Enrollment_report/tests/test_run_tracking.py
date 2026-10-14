import importlib.util,tempfile,unittest,csv,json
from pathlib import Path

source=Path(__file__).resolve().parent.parent/'src/linux'/'finalize_enrollment_run.py'
spec=importlib.util.spec_from_file_location('finalizer',source)
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
test_root=Path(__file__).resolve().parent/'Validation'/'run_tracking_tests'
test_root.mkdir(parents=True,exist_ok=True)
assert test_root.resolve().is_relative_to(Path(__file__).resolve().parent)

class RunTracking(unittest.TestCase):
    def fixture(self,root):
        rid='20261013T120000_123';out=root/'output'/rid;out.mkdir(parents=True)
        for name in ('QC_Current_Matrix.csv','QC_Check_Matrix.csv','Freshness.csv','ReportTestMonthly-20261013_REBUILD_REGXSA.xls','ReportTestMonthly-20261013_REBUILD_SASQA.xls'):
            (out/name).write_text('fixture evidence')
        with (out/'QC_Summary.csv').open('w',newline='') as f:
            w=csv.writer(f);w.writerows([['ITEM','VALUE'],['Technical QC Status','BASELINE_ONLY'],['Distribution Decision','REVIEW BEFORE DISTRIBUTION']])
        (out/'TECHNICAL_COMPLETE.txt').write_text(f'RunID={rid}\nReportDate=20261013\nQCStatus=BASELINE_ONLY\nDistributionDecision=REVIEW BEFORE DISTRIBUTION\n')
        log=root/'SAS.log';log.write_text(f'NOTE: ACO_REBUILD_RUN_COMPLETE REPDT=20261013 RUNID={rid}\n')
        return rid,out,log
    def test_complete_candidate_hashes_evidence_but_never_authorizes_publication(self):
        with tempfile.TemporaryDirectory(dir=test_root) as tmp:
            root=Path(tmp);rid,out,log=self.fixture(root)
            result=mod.finalize(rid,0,log,root/'output',root/'audit',None)
            self.assertEqual(result['technical_status'],'PASS')
            self.assertFalse(result['publication_allowed'])
            self.assertEqual(len(result['artifacts']),8)
            self.assertTrue(all(len(a['sha256'])==64 for a in result['artifacts']))
            with self.assertRaises(FileExistsError):mod.finalize(rid,0,log,root/'output',root/'audit',None)
    def test_numbered_error_retains_qc_and_blocks_completion(self):
        with tempfile.TemporaryDirectory(dir=test_root) as tmp:
            root=Path(tmp);rid,out,log=self.fixture(root)
            with log.open('a') as f:f.write(' ERROR 180-322: Invalid statement\n')
            result=mod.finalize(rid,0,log,root/'output',root/'audit',None)
            self.assertEqual(result['technical_status'],'FAIL')
            self.assertTrue((out/'QC_Summary.csv').exists())
    def test_missing_output_or_mismatched_identity_fails(self):
        with tempfile.TemporaryDirectory(dir=test_root) as tmp:
            root=Path(tmp);rid,out,log=self.fixture(root)
            (out/'ReportTestMonthly-20261013_REBUILD_REGXSA.xls').unlink()
            log.write_text('NOTE: ACO_REBUILD_RUN_COMPLETE REPDT=20261013 RUNID=another_run\n')
            result=mod.finalize(rid,0,log,root/'output',root/'audit',None)
            self.assertEqual(result['technical_status'],'FAIL')
    def test_conflicting_qc_decision_fails(self):
        with tempfile.TemporaryDirectory(dir=test_root) as tmp:
            root=Path(tmp);rid,out,log=self.fixture(root)
            (out/'TECHNICAL_COMPLETE.txt').write_text(f'RunID={rid}\nReportDate=20261013\nQCStatus=FAIL\nDistributionDecision=DO NOT DISTRIBUTE\n')
            result=mod.finalize(rid,0,log,root/'output',root/'audit',None)
            self.assertIn('QC decision disagreement',result['failures'])

if __name__=='__main__':unittest.main()
