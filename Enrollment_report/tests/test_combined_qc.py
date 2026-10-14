import csv,json,sys,tempfile,unittest
from zipfile import ZipFile
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
from check_transfer_gate import digest
from prepare_combined_qc import prepare
from normalize_combined_qc import normalize

class CombinedQCTests(unittest.TestCase):
    def test_normalization_clears_only_expected_missing_placeholders(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            root=Path(folder);(root/'COMBINED_QC_INPUTS.json').write_text(json.dumps({'report_date':'20261014','sheets':[{'name':'Fixture','rows':[[None,None,1,None]]}]}))
            file=root/'ACO_Weekly_Enrollment_QC_20261014.xlsx'
            ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
            with ZipFile(file,'w') as z:
                z.writestr('xl/sharedStrings.xml','<sst xmlns="'+ns+'"><si><t>..</t></si><si><t>unexpected value</t></si></sst>')
                z.writestr('xl/worksheets/sheet1.xml','<worksheet xmlns="'+ns+'"><sheetData><row r="4"><c r="A4" t="s"><v>0</v></c><c r="B4"><v>.</v></c><c r="C4"><v>1</v></c><c r="D4" t="s"><v>1</v></c></row></sheetData></worksheet>')
            self.assertEqual(normalize(root)['blank_cells_normalized'],2)
            with ZipFile(file) as z:cells=list(ET.fromstring(z.read('xl/worksheets/sheet1.xml')).iter('{'+ns+'}c'))
            self.assertIsNone(cells[0].find('{'+ns+'}v'));self.assertIsNone(cells[1].find('{'+ns+'}v'))
            self.assertEqual(cells[2].find('{'+ns+'}v').text,'1')
            self.assertEqual(cells[3].get('t'),'s')
    def fixture(self,root):
        run=root/'RUN_MANIFEST.json';run.write_text(json.dumps({'run_id':'fixture','report_date':'20261014'}))
        policy=root/'Baseline_Policy.csv'
        headers=['REPORT_SECTION','CATEGORY','MONTH_ID','BASELINE','CANDIDATE','DIFFERENCE','MONTH_GROUP','WARNING_THRESHOLD','FAIL_THRESHOLD','POLICY_STATUS']
        with policy.open('w',newline='') as handle:
            writer=csv.writer(handle);writer.writerow(headers)
            writer.writerows([['CASELOAD','All','20260901','100','110','10','PREVIOUS_MONTH','5','50','REVIEW'],
              ['CASELOAD','All','20261001','0','5','5','CURRENT_MTD','5','50','PASS']])
        qc=root/'FINAL_QC.json';qc.write_text(json.dumps({'run_id':'fixture','report_date':'20261014','final_qc_decision':'REVIEW',
          'checks':[{'check':'baseline_business_policy','status':'REVIEW','evidence':[{'name':policy.name,'sha256':digest(policy)}]}]}))
        comp=root/'BASELINE_COMPARISON.json';comp.write_text(json.dumps({'run_id':'fixture','run_manifest_sha256':digest(run),'baseline_report_date':'20261007'}))
        private=root/'private';private.mkdir()
        summary=private/'QC_Display_Summary.csv';summary.write_text('CHECK,RESULT,EVIDENCE\nDistributed baseline,REVIEW,Comparison warning\n')
        detail=private/'QC_Display_Detail.csv';detail.write_text('STATUS,CHECK,WORKSHEET,MEMBER_GROUP,CATEGORY,MONTH,MEASURE,REFERENCE,CURRENT,DIFFERENCE,TOLERANCE,BLOCKING_THRESHOLD,REASON\nREVIEW,Baseline provenance,Archived baseline,,,20261001,,,,,,,No original receipt\n')
        (private/'QC_DISPLAY_INPUTS.json').write_text(json.dumps({'run_id':'fixture','qc_sha256':digest(qc),
          'files':{p.name:digest(p) for p in (summary,detail)}}))
        return run,qc,policy,comp,private
    def test_comparison_and_technical_counts_remain_separate(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            root=Path(folder);args=self.fixture(root);result=prepare(*args,root/'combined')
            self.assertEqual(result['comparison_counts'],{'REVIEW':1,'PASS':1})
            self.assertEqual(result['comparison_rows'],2);self.assertEqual(result['technical_rows'],1)
            self.assertEqual(result['baseline_report_date'],'20261007')
            self.assertEqual([s['name'] for s in result['sheets']],['QC_Summary','QC_Matrix','QC_Detail','Technical_Detail'])
            detail=result['sheets'][2]['rows']
            self.assertAlmostEqual(detail[0][10],.1)
            self.assertIsNone(detail[1][10]);self.assertIsNone(detail[1][12])
            self.assertEqual(detail[1][13],'PASS')
    def test_changed_policy_and_technical_input_are_rejected(self):
        for kind in ('policy','technical','identity'):
            with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
                root=Path(folder);args=self.fixture(root)
                if kind=='policy':args[2].write_text(args[2].read_text()+'changed')
                elif kind=='technical':(args[4]/'QC_Display_Detail.csv').write_text('changed')
                else:
                    doc=json.loads(args[3].read_text());doc['run_id']='other';args[3].write_text(json.dumps(doc))
                with self.assertRaises(ValueError):prepare(*args,root/'combined')

if __name__=='__main__':unittest.main()

