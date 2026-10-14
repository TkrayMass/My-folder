import argparse,csv,json,re
from decimal import Decimal
from pathlib import Path
from zipfile import ZipFile
import xml.etree.ElementTree as ET
from check_transfer_gate import digest

def validate(folder):
    folder=Path(folder);inputs=json.loads((folder/'PRIMARY_QC_INPUTS.json').read_text())
    for name,sha in inputs['files'].items():
        if digest(folder/name)!=sha:raise ValueError('Primary inputs changed')
    if 'NOTE: PRIMARY_QC_RENDER_COMPLETE' not in (folder/'Render.log').read_text():
        raise ValueError('Missing primary render completion')
    if re.search(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:',(folder/'Render.log').read_text(),re.M):
        raise ValueError('Primary render error')
    report=folder/'ACO_Enrollment_Comparison_QC.xlsx';ns={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    with ZipFile(report) as z:
        if z.testzip():raise ValueError('Corrupt ZIP')
        strings=[''.join(e.itertext()) for e in ET.fromstring(z.read('xl/sharedStrings.xml'))]
        styles=ET.fromstring(z.read('xl/styles.xml'));fills=styles.find('m:fills',ns);xfs=styles.find('m:cellXfs',ns)
        if [s.get('name') for s in ET.fromstring(z.read('xl/workbook.xml')).find('m:sheets',ns)]!=['QC Summary','QC Detail']:
            raise ValueError('Primary sheets differ')
        for index,name in enumerate(('Primary_All.csv','Primary_Flags.csv'),1):
            with (folder/name).open(newline='') as f:expected=list(csv.reader(f))[1:]
            sheet=ET.fromstring(z.read('xl/worksheets/sheet{}.xml'.format(index)))
            def value(cell):
                if cell is None:return ''
                if cell.get('t') in ('e','str') or cell.find('m:f',ns) is not None:raise ValueError('Unexpected error/formula cell')
                node=cell.find('m:v',ns)
                if node is None:return ''
                return strings[int(node.text)] if cell.get('t')=='s' else node.text or ''
            actual=[]
            for row in sheet.findall('m:sheetData/m:row',ns):
                cells={re.sub(r'\d+$','',c.get('r')):c for c in row}
                status=value(cells.get('J'))
                if status not in ('PASS','REVIEW','FAIL'):continue
                values=[value(cells.get(c)) for c in 'ABCDEFGHIJ'];actual.append(values)
                if status!='PASS':
                    wanted='FFFFF2CC' if status=='REVIEW' else 'FFFF9999'
                    for c in cells.values():
                        fill=fills[int(xfs[int(c.get('s','0'))].get('fillId','0'))].find('m:patternFill/m:fgColor',ns)
                        if fill is None or fill.get('rgb')!=wanted:raise ValueError('Primary status fill differs')
            if len(actual)!=len(expected):raise ValueError('Primary row count differs')
            for actual_row,expected_row in zip(actual,expected):
                for col,(a,b) in enumerate(zip(actual_row,expected_row)):
                    if col in (0,1,2,9):
                        if a.strip()!=b.strip():raise ValueError('Primary text differs')
                    elif b:
                        # This ODS percentage format stores fractions to nine decimal places.
                        # This bound is far below the displayed 0.01 percentage point.
                        tolerance=Decimal('0.00000000051') if col==6 else Decimal('0.000001')
                        if not a or abs(Decimal(a)-Decimal(b))>tolerance:
                            raise ValueError('Primary numeric value differs: column {} actual={} expected={}'.format(col,a,b))
                    elif a.strip() not in ('','.'):
                        raise ValueError('Expected missing primary value: column {} actual={!r}'.format(col,a))
            if sheet.find('m:autoFilter',ns) is None or sheet.find('m:sheetViews/m:sheetView/m:pane',ns) is None:
                raise ValueError('Primary filters/panes missing')
    receipt={'run_id':inputs['run_id'],'report_date':inputs['report_date'],
             'primary_qc_status':'PASS','comparison_rows':inputs['rows'],
             'warnings':inputs['warnings'],'failures':inputs['failures'],
             'final_qc_sha256':inputs['final_qc_sha256'],
             'workbook_sha256':digest(report),'inputs_sha256':digest(folder/'PRIMARY_QC_INPUTS.json')}
    with (folder/'PRIMARY_QC_VALIDATION.json').open('x') as f:json.dump(receipt,f,indent=2)
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--folder',required=True)
    print(json.dumps(validate(p.parse_args().folder),indent=2))
