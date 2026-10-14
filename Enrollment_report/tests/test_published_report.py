import sys,tempfile,unittest
from pathlib import Path
from zipfile import ZipFile
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
from verify_published_report import verify
from check_transfer_gate import digest

def fixture(path,count='1000.123456789',rate='0.123456789',label='Members',formula='',sheet='Summary',merge='A1:B1'):
    m='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    with ZipFile(path,'w') as z:
        z.writestr('xl/workbook.xml','<workbook xmlns="'+m+'" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="'+sheet+'" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
        z.writestr('xl/worksheets/sheet1.xml','<worksheet xmlns="'+m+'"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>'+label+'</t></is></c><c r="C1"><v>'+count+'</v></c><c r="D1">'+formula+'<v>'+rate+'</v></c></row></sheetData><mergeCells><mergeCell ref="'+merge+'"/></mergeCells></worksheet>')

class PublishedReportTests(unittest.TestCase):
    def test_content_and_rejections(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            folder=Path(folder);source=folder/'source.xlsx';target=folder/'published.xlsx';out=folder/'receipt.json'
            fixture(source)
            fixture(target,count='1000.1234567891',rate='0.12345678900000003',label=' Members ')
            receipt=verify(source,target,digest(source),'fixture','20261014',out)
            self.assertEqual(receipt['method'],'CONTENT');self.assertEqual(receipt['differences'],0)
            for change in ({'count':'1001.123456789'},{'count':'1000.123456889'},
                           {'rate':'0.123456889'},{'label':'Other members'},
                           {'formula':'<f>1/8</f>'},{'sheet':'Different'},{'merge':'A1:C1'}):
                fixture(target,**change)
                with self.assertRaises(ValueError,msg=str(change)):verify(source,target,digest(source),'fixture','20261014',out)
            with self.assertRaises(ValueError):verify(source,target,'0'*64,'fixture','20261014',out)
    def test_byte_identical(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent/'Validation') as folder:
            folder=Path(folder);source=folder/'source.xlsx';fixture(source)
            self.assertEqual(verify(source,source,digest(source),'fixture','20261014',folder/'receipt.json')['method'],'SHA256')
if __name__=='__main__':unittest.main()
