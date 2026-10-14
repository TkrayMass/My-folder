import importlib.util,tempfile,unittest,json
from pathlib import Path

root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('compare',root.parent/'src/linux'/'compare_distributed_baseline.py')
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
temp_root=root/'Validation'/'baseline_tests';temp_root.mkdir(exist_ok=True)
assert temp_root.resolve().is_relative_to(root)
class BaselineChecks(unittest.TestCase):
    def fixture(self,t):
        b=t/'baseline';c=t/'candidate';b.mkdir();c.mkdir()
        text='REPORT_SECTION,CATEGORY,PLAN_TYPE,MONTH_ID,MBRS\nCASELOAD,All,TOTAL,20260901,100\n'
        bp=b/'Distributed_Baseline_Matrix.csv';bp.write_text(text)
        cp=c/'QC_Current_Matrix.csv';cp.write_text(text.replace(',100',',101'))
        (b/'BASELINE_MANIFEST.json').write_text(json.dumps({'baseline_id':'seed','report_date':'20261007','limitations':[],'artifacts':[{'name':bp.name,'bytes':bp.stat().st_size,'sha256':mod.sha(bp)}]}))
        r=t/'RUN_MANIFEST.json';r.write_text(json.dumps({'run_id':'test_run','report_date':'20261013','technical_status':'PASS','artifacts':[{'path':str(cp),'sha256':mod.sha(cp)}]}))
        return b,c,r,bp,cp
    def test_changed_files_rejected(self):
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);b,c,r,bp,cp=self.fixture(t)
            bp.write_text(bp.read_text().replace(',100',',999'))
            with self.assertRaisesRegex(ValueError,'Baseline hash mismatch'):mod.compare(b,c,r,t/'out')
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);b,c,r,bp,cp=self.fixture(t)
            cp.write_text(cp.read_text().replace(',101',',999'))
            with self.assertRaisesRegex(ValueError,'Run matrix hash mismatch'):mod.compare(b,c,r,t/'out')
    def test_change_evidence_never_authorizes_distribution(self):
        with tempfile.TemporaryDirectory(dir=temp_root) as tmp:
            t=Path(tmp);b,c,r,bp,cp=self.fixture(t)
            result=mod.compare(b,c,r,t/'out')
            self.assertEqual(result['historical'],{'CHANGED':1})
            self.assertFalse(result['publication_allowed'])
            with self.assertRaises(FileExistsError):mod.compare(b,c,r,t/'out')
if __name__=='__main__':unittest.main()
