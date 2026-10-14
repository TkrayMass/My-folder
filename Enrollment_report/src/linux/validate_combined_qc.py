"""Verify every combined QC cell against the bound prepared evidence."""
import argparse,json,re
from decimal import Decimal
from pathlib import Path
from zipfile import ZipFile
import xml.etree.ElementTree as ET
from check_transfer_gate import digest

NS={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
REL='http://schemas.openxmlformats.org/officeDocument/2006/relationships'

def validate(folder,workbook=None,require_log=True):
    folder=Path(folder);input_path=folder/'COMBINED_QC_INPUTS.json';data=json.loads(input_path.read_text())
    workbook=Path(workbook) if workbook else folder/('ACO_Weekly_Enrollment_QC_'+data['report_date']+'.xlsx')
    for source,sha in data['sources'].items():
        if digest(source)!=sha:raise ValueError('Combined QC source changed')
    if require_log:
        log=(folder/'Render.log').read_text()
        if 'NOTE: COMBINED_QC_RENDER_COMPLETE' not in log or re.search(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:',log,re.M):
            raise ValueError('Combined render failed or incomplete')
    checked=0
    with ZipFile(workbook) as archive:
        if archive.testzip():raise ValueError('Corrupt combined workbook')
        doc=ET.fromstring(archive.read('xl/workbook.xml'))
        sheets=doc.find('m:sheets',NS)
        if [s.get('name') for s in sheets]!=[s['name'] for s in data['sheets']]:raise ValueError('Combined worksheet names/order differ')
        relationships={r.get('Id'):r.get('Target') for r in ET.fromstring(archive.read('xl/_rels/workbook.xml.rels'))}
        strings=[]
        styles=ET.fromstring(archive.read('xl/styles.xml'))
        fills=styles.find('m:fills',NS);xfs=styles.find('m:cellXfs',NS)
        if 'xl/sharedStrings.xml' in archive.namelist():
            strings=[''.join(s.itertext()) for s in ET.fromstring(archive.read('xl/sharedStrings.xml'))]
        def value(cell):
            if cell is None:return None
            if cell.get('t')=='e' or cell.find('m:f',NS) is not None:raise ValueError('Unexpected formula/error in evidence snapshot')
            if cell.get('t')=='inlineStr':return ''.join(cell.find('m:is',NS).itertext())
            node=cell.find('m:v',NS)
            if node is None:return None
            return strings[int(node.text)] if cell.get('t')=='s' else node.text
        for spec,sheet in zip(data['sheets'],sheets):
            target=relationships[sheet.get('{'+REL+'}id')]
            name=target.lstrip('/') if target.startswith('/') else 'xl/'+target
            root=ET.fromstring(archive.read(name))
            rows={int(r.get('r')):{re.sub(r'\d+','',c.get('r')):c for c in r} for r in root.findall('m:sheetData/m:row',NS)}
            def column(index):
                text='';index+=1
                while index:index,rem=divmod(index-1,26);text=chr(65+rem)+text
                return text
            for row_index,expected in enumerate([spec['headers']]+spec['rows'],3):
                actual=rows.get(row_index,{})
                for index,wanted in enumerate(expected):
                    got=value(actual.get(column(index)));checked+=1
                    if isinstance(wanted,(int,float)):
                        tolerance=Decimal('0.000000001') if index in spec.get('pct_cols',[]) or spec.get('matrix') and expected[3]=='% Change' else Decimal('0.000001')
                        try: difference=abs(Decimal(got.strip())-Decimal(str(wanted))) if got is not None else None
                        except Exception:raise ValueError('Invalid numeric combined cell: '+spec['name']+' '+str(row_index)+' '+str(index)+' '+repr(got))
                        if difference is None or difference>tolerance:
                            raise ValueError('Combined numeric value differs: '+spec['name']+' '+str(row_index)+' '+str(index))
                    elif wanted in (None,''):
                        if got is not None and got.strip() not in ('','.'):raise ValueError('Expected missing combined value: '+spec['name']+' '+str(row_index)+' '+str(index)+' '+repr(got))
                    elif got is None or got.strip()!=str(wanted).strip():
                        raise ValueError('Combined text differs: '+spec['name']+' '+str(row_index)+' '+str(index))
                    if row_index>3 and root.find('m:conditionalFormatting',NS) is None:
                        status=None
                        if spec.get('matrix') and index>=4:
                            flag_row=((row_index-4)//5)*5+4
                            status=spec['rows'][flag_row][index]
                        elif 'status_col' in spec:status=expected[spec['status_col']]
                        if status in ('PASS','REVIEW','FAIL') and got is not None:
                            cell=actual[column(index)];style=xfs[int(cell.get('s','0'))]
                            fill=fills[int(style.get('fillId','0'))].find('m:patternFill/m:fgColor',NS)
                            wanted_fill={'PASS':'C6EFCE','REVIEW':'FFEB9C','FAIL':'FFC7CE'}[status]
                            if fill is None or (fill.get('rgb') or '')[-6:].upper()!=wanted_fill:
                                raise ValueError('Combined status color differs: '+spec['name']+' '+str(row_index)+' '+str(index))
            for index,row in rows.items():
                if index>len(spec['rows'])+3 and any(value(c) not in (None,'') for c in row.values()):raise ValueError('Unexpected extra combined rows')
            if root.find('m:sheetViews/m:sheetView/m:pane',NS) is None:raise ValueError('Combined frozen headers missing')
            if spec['name'] in ('QC_Detail','Technical_Detail'):
                if root.find('m:autoFilter',NS) is None and root.find('m:tableParts',NS) is None:raise ValueError('Combined filters missing')
    receipt={'run_id':data['run_id'],'report_date':data['report_date'],'baseline_report_date':data['baseline_report_date'],
      'combined_qc_status':'PASS','final_qc_sha256':data['final_qc_sha256'],'workbook_sha256':digest(workbook),
      'inputs_sha256':digest(input_path),'comparison_rows':data['comparison_rows'],
      'comparison_counts':data['comparison_counts'],'technical_rows':data['technical_rows'],'cells_checked':checked,
      'workbook':str(workbook),'qc_decision':data['qc_decision']}
    (folder/'COMBINED_QC_VALIDATION.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--folder',required=True);parser.add_argument('--workbook');parser.add_argument('--skip-render-log',action='store_true')
    args=parser.parse_args();print(json.dumps(validate(args.folder,args.workbook,not args.skip_render_log),indent=2))
