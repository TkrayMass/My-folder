import json,sys,unittest,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
import promote_distributed_baseline as promotion
from check_transfer_gate import digest

class BaselinePromotionTests(unittest.TestCase):
    def test_only_matching_notified_publication_advances_baseline(self):
        root=Path(__file__).parent/'Validation'/('p_'+uuid.uuid4().hex[:8])
        root.mkdir();previous=root/'previous';previous.mkdir()
        (previous/'BASELINE_MANIFEST.json').write_text(json.dumps({'report_date':'20261007'}))
        pointer=root/'CURRENT_DISTRIBUTED_BASELINE.txt';pointer.write_text(str(previous)+'\n')
        report=root/'report.xlsx';report.write_bytes(b'verified report fixture')
        qc=root/'primary.xlsx';qc.write_bytes(b'verified QC fixture')
        matrix=root/'QC_Current_Matrix.csv';matrix.write_text('REPORT_SECTION,CATEGORY,PLAN_TYPE,MONTH_ID,MBRS\n')
        manifest=root/'RUN_MANIFEST.json'
        manifest.write_text(json.dumps({'artifacts':[{'path':str(matrix),'sha256':digest(matrix)}]}))
        package=root/'package.json'
        package.write_text(json.dumps({'run_id':'fixture','report_date':'20261014','release_allowed':True,
          'artifacts':{name:{'path':str(path),'sha256':digest(path)} for name,path in
                       [('report',report),('primary_qc',qc),('run_manifest',manifest)]}}))
        marker=root/'sent.ok'
        marker.write_text('ReportDate=20261014\nRunID=fixture\nPublishedSHA256=wrong\nQCDecision=READY TO DISTRIBUTE\nSentAt=2026-10-16 09:30:00\n')
        old=promotion.ROOT;promotion.ROOT=root
        try:
            with self.assertRaises(ValueError):promotion.promote(package,marker,'fixture')
            self.assertEqual(pointer.read_text().strip(),str(previous))
            marker.write_text(marker.read_text().replace('PublishedSHA256=wrong','PublishedSHA256='+digest(report)))
            result=promotion.promote(package,marker,'fixture')
            self.assertEqual(result['status'],'PROMOTED')
            self.assertEqual(digest(Path(result['baseline'])/'ReportTestMonthly-20261014_REGXSA.xlsx'),digest(report))
            self.assertEqual(pointer.read_text().strip(),result['baseline'])
            self.assertEqual(promotion.promote(package,marker,'fixture')['status'],'ALREADY_ARCHIVED')
            # A reserialized publication must retain both its actual hash and a bound, passing comparison.
            changed=json.loads(package.read_text());changed.update(run_id='fixture2',report_date='20261021')
            package.write_text(json.dumps(changed))
            marker.write_text('ReportDate=20261021\nRunID=fixture2\nReleaseSHA256='+digest(report)+'\nPublishedSHA256='+'1'*64+'\nQCDecision=READY TO DISTRIBUTE\nSentAt=2026-10-23 09:30:00\n')
            with self.assertRaises(ValueError):promotion.promote(package,marker,'fixture2')
            certificate=root/'verification.json'
            verified={'policy':'enrollment_content_v1','status':'FAIL','differences':0,'method':'CONTENT',
                      'run_id':'fixture2','report_date':'20261021','source_sha256':digest(report),
                      'published_sha256':'1'*64,'sheets':[{'name':'Summary','differences':0}]}
            certificate.write_text(json.dumps(verified))
            original_marker=marker.read_text()
            marker.write_text(original_marker+'ContentVerificationSHA256='+digest(certificate)+'\n')
            with self.assertRaises(ValueError):promotion.promote(package,marker,'fixture2',certificate)
            verified['status']='PASS';certificate.write_text(json.dumps(verified))
            with self.assertRaises(ValueError):promotion.promote(package,marker,'fixture2',certificate)
            marker.write_text(original_marker+'ContentVerificationSHA256='+digest(certificate)+'\n')
            result2=promotion.promote(package,marker,'fixture2',certificate)
            self.assertEqual(result2['status'],'PROMOTED')
            archive=Path(result2['baseline'])
            self.assertEqual(digest(archive/'Published_Content_Verification.json'),digest(certificate))
            archived=json.loads((archive/'BASELINE_MANIFEST.json').read_text())
            self.assertEqual(archived['observed_published_sha256'],'1'*64)
        finally:promotion.ROOT=old

if __name__=='__main__':unittest.main()
