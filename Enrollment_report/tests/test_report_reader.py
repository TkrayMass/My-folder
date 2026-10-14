import io
import unittest
from pathlib import Path
from zipfile import ZipFile
from report_reader import report_events, SS, X, REL

class NativeReaderTests(unittest.TestCase):
    def fixture(self, directory, cell):
        p = io.BytesIO()
        with ZipFile(p, 'w') as z:
            z.writestr('xl/workbook.xml', f'<workbook xmlns="{X}" xmlns:r="{REL}"><sheets><sheet name="Summary" r:id="rId1"/></sheets></workbook>')
            z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
            z.writestr('xl/styles.xml', f'<styleSheet xmlns="{X}"><cellXfs><xf numFmtId="0"/><xf numFmtId="10"/></cellXfs></styleSheet>')
            z.writestr('xl/sharedStrings.xml', f'<sst xmlns="{X}"><si><t>Plan&#160;Type</t></si></sst>')
            z.writestr('xl/worksheets/sheet1.xml', f'<worksheet xmlns="{X}"><sheetData><row r="3">{cell}</row></sheetData></worksheet>')
        p.seek(0)
        return p

    def test_sparse_addresses_precision_and_percent(self):
        with io.BytesIO() as d:
            p = self.fixture(d, '<c r="B3" t="s"><v>0</v></c><c r="D3"><v>12.345678901234</v></c><c r="F3" s="1"><v>0.123456789</v></c>')
            rows = [e for event,e in report_events(p) if event=='end' and e.tag=='{'+SS+'}Row']
            self.assertEqual(len(rows), 3)
            actual = [(c.get('{'+SS+'}Index'), c.find('{'+SS+'}Data').text) for c in rows[-1]]
            self.assertEqual(actual, [('2','Plan Type'),('4','12.345678901234'),('6','12.345678900%')])

    def test_unexpected_formulas_are_rejected(self):
        with io.BytesIO() as d:
            with self.assertRaisesRegex(ValueError, 'Unexpected formula'):
                list(report_events(self.fixture(d, '<c r="A3"><f>1+1</f><v>2</v></c>')))

    def test_excel_error_is_rejected(self):
        with io.BytesIO() as d:
            with self.assertRaisesRegex(ValueError, 'cell error'):
                list(report_events(self.fixture(d, '<c r="A3" t="e"><v>#REF!</v></c>')))

if __name__=='__main__':
    unittest.main()
