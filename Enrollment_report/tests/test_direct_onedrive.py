import argparse,json,shutil,sys,tempfile,unittest
import datetime
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
import transfer_rebuilt_windows as transfer
from check_transfer_gate import digest
from test_published_report import fixture

class DirectOneDriveTests(unittest.TestCase):
    def test_thursday_selects_wednesday_and_handles_boundaries(self):
        cases=[('2026-10-15','20261014'),('2026-10-16','20261014'),
               ('2026-10-14','20261014'),('2026-10-20','20261014'),
               ('2026-10-21','20261021'),('2026-01-01','20251231')]
        for current,expected in cases:
            today=datetime.datetime.strptime(current,'%Y-%m-%d').date()
            self.assertEqual(transfer.selected_report_date(latest_wednesday=True,today=today),expected)
        with self.assertRaises(ValueError):transfer.selected_report_date('20261014',True)

    def test_direct_copy_and_equivalent_save_without_z_drive(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            folder=Path(folder);source=folder/'approved.xlsx';fixture(source)
            gate={'report_sha256':digest(source),'run_id':'fixture','report_date':'20261014'}
            published=transfer.publish_to_onedrive(source,folder/'OneDrive','Report.xlsx',gate,folder)
            self.assertEqual(digest(published),digest(source))
            fixture(published,count='1000.1234567891',rate='0.12345678900000003')
            saved=digest(published)
            transfer.publish_to_onedrive(source,folder/'OneDrive','Report.xlsx',gate,folder)
            self.assertEqual(digest(published),saved)
            fixture(published,count='2000')
            changed=digest(published)
            with self.assertRaises(ValueError):transfer.publish_to_onedrive(source,folder/'OneDrive','Report.xlsx',gate,folder)
            self.assertEqual(digest(published),changed)
            transfer.publish_to_onedrive(source,folder/'OneDrive','Report.xlsx',gate,folder,replace_existing=True)
            self.assertEqual(digest(published),digest(source))
            backups=list((folder/'Previous_Destinations').glob('*.xlsx'))
            self.assertEqual(len(backups),1);self.assertEqual(digest(backups[0]),changed)

    def test_scheduled_transfer_rejects_morning_release(self):
        threshold=datetime.datetime(2026,10,14,17,tzinfo=datetime.timezone.utc)
        old={'report_date':'20261014','release_allowed':True,'run_id':'20261014T140541_5343'}
        with self.assertRaises(ValueError):transfer.eligible_release(old,'20261014',threshold)
        fresh=dict(old,run_id='20261014T170000_123')
        transfer.eligible_release(fresh,'20261014',threshold)
        with self.assertRaises(ValueError):transfer.eligible_release(dict(fresh,release_allowed=False),'20261014',threshold)

    @unittest.skip('Requires private installed report cache; run separately on deployment host')
    def test_real_release_rehearsal_writes_local_receipt_without_z(self):
        root=Path(__file__).parent/'Validation'/'Direct_OneDrive_Rehearsal_20261014'
        root.mkdir(exist_ok=True)
        existing=Path(r'C:\Users\TKray\ACO_Weekly_Rebuilt_Staging\20261014T140541_5343')
        package_text=(existing/'TRANSFER_PACKAGE.json').read_text()
        package=json.loads(package_text);staging=root/'staging'/package['run_id'];staging.mkdir(parents=True,exist_ok=True)
        for artifact in package['artifacts'].values():
            filename=Path(artifact['path']).name
            shutil.copyfile(existing/filename,staging/filename)
        original=transfer.fetch_package
        transfer.fetch_package=lambda *args:(package_text,package)
        try:
            args=argparse.Namespace(report_date='20261014',package='fixture_cached_verified_release',wait_minutes=0,
                  staging=str(root/'staging'),qc_folder=str(root/'private_QC'),publish_folder=str(root/'OneDrive'),publish=True)
            transfer.main(args)
        finally:transfer.fetch_package=original
        receipt=json.loads((root/'staging'/'LATEST_TRANSFER_RECEIPT.json').read_text())
        self.assertEqual(receipt['transfer_route'],'LINUX_TO_ONEDRIVE')
        self.assertNotIn('z_report',receipt)
        self.assertEqual(digest(receipt['published_file']),receipt['report_sha256'])
        self.assertEqual(digest(receipt['approved_source']),receipt['report_sha256'])
        self.assertNotIn('Z:',(Path(__file__).parent.parent/'src/windows').joinpath('run_rebuilt_enrollment_wednesday.bat').read_text())

if __name__=='__main__':unittest.main()
