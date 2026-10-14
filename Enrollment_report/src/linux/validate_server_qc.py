#!/usr/bin/env python3
"""Verify server-native private QC output; never publish or send mail."""
import argparse
import csv
import hashlib
import json
import re
import datetime
from decimal import Decimal
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

NS={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def validate(folder):
    folder=Path(folder);receipt=json.loads((folder/'QC_DISPLAY_INPUTS.json').read_text())
    for name,digest in receipt['files'].items():
        if Path(name).name!=name or sha(folder/name)!=digest:raise ValueError('Prepared QC input changed')
    log=(folder/'Render.log').read_text(errors='replace')
    if re.search(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:',log,re.M):raise ValueError('Actual SAS render error')
    if len(re.findall(r'^NOTE: PRIVATE_QC_RENDER_COMPLETE\s*$',log,re.M))!=1:raise ValueError('Missing render completion')
    with (folder/'QC_Display_Detail.csv').open(newline='') as f:expected=list(csv.DictReader(f))
    with (folder/'QC_Display_Summary.csv').open(newline='') as f:summary_expected=list(csv.DictReader(f))
    if len(expected)!=receipt['detail_rows']:raise ValueError('Input row-count disagreement')
    report=folder/'ACO_Weekly_Final_QC_Colored.xlsx'
    with ZipFile(report) as z:
        if z.testzip():raise ValueError('Corrupt workbook ZIP')
        sheets=ET.fromstring(z.read('xl/workbook.xml')).find('m:sheets',NS)
        if [s.get('name') for s in sheets]!=['QC Summary','QC Detail']:raise ValueError('QC worksheet names/order differ')
        strings=[''.join(t.text or '' for t in si.findall('.//m:t',NS)) for si in ET.fromstring(z.read('xl/sharedStrings.xml'))]
        styles=ET.fromstring(z.read('xl/styles.xml'));fills=styles.find('m:fills',NS);xfs=styles.find('m:cellXfs',NS)
        def text(c):
            v=c.find('m:v',NS)
            if c.get('t')=='e':raise ValueError('Cell error')
            return strings[int(v.text)] if c.get('t')=='s' and v is not None and v.text else (v.text if v is not None else '')
        def color(c):
            fill=fills[int(xfs[int(c.get('s','0'))].get('fillId'))].find('m:patternFill/m:fgColor',NS)
            return fill.get('rgb') if fill is not None else None
        summary=ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
        labels={r['CHECK'] for r in summary_expected};summary_actual=[]
        for row in summary.findall('m:sheetData/m:row',NS):
            cells={re.sub(r'\d+$','',c.get('r')):c for c in row}
            if 'A' not in cells or text(cells['A']) not in labels:continue
            values=[text(cells[column]).strip() if column in cells else '' for column in ('A','B','C')]
            summary_actual.append(values)
            if values[1] in ('REVIEW','FAIL'):
                wanted='FFFFF2CC' if values[1]=='REVIEW' else 'FFFF9999'
                if any(color(c)!=wanted for c in cells.values()):raise ValueError('Summary row color mismatch')
        if summary_actual!=[[r[k] for k in ('CHECK','RESULT','EVIDENCE')] for r in summary_expected]:
            raise ValueError('Summary content or order changed')
        detail=ET.fromstring(z.read('xl/worksheets/sheet2.xml'))
        actual=[]
        for row in detail.findall('m:sheetData/m:row',NS):
            cells={re.sub(r'\d+$','',c.get('r')):c for c in row}
            status=text(cells['A']) if 'A' in cells else ''
            if status not in ('REVIEW','FAIL'):continue
            wanted='FFFFF2CC' if status=='REVIEW' else 'FFFF9999'
            if any(color(c)!=wanted for c in cells.values()):raise ValueError('Flagged QC row color mismatch')
            if len(actual)>=len(expected):raise ValueError('Unexpected extra QC finding')
            source=expected[len(actual)]
            for column,field in [('A','STATUS'),('B','CHECK'),('C','WORKSHEET'),('D','MEMBER_GROUP'),('E','CATEGORY'),('G','MEASURE'),('M','REASON')]:
                value=text(cells[column]).strip() if column in cells else ''
                if value.strip()!=source[field].strip():raise ValueError('QC text changed: '+field)
            month=(datetime.datetime(1899,12,30)+datetime.timedelta(days=float(text(cells['F'])))).strftime('%Y%m%d')
            if month!=source['MONTH']:raise ValueError('QC month changed')
            for column,field in [('H','REFERENCE'),('I','CURRENT'),('J','DIFFERENCE'),('K','TOLERANCE'),('L','BLOCKING_THRESHOLD')]:
                value=text(cells[column]).strip() if column in cells else ''
                if source[field]=='':
                    if value not in ('','.'):raise ValueError('Missing QC value became populated: '+field)
                elif value in ('','.') or abs(Decimal(value)-Decimal(source[field]))>Decimal('0.000001'):
                    raise ValueError('Numeric QC value changed: '+field)
            actual.append((status,text(cells['B']),text(cells['C'])))
        if actual!=[(r['STATUS'],r['CHECK'],r['WORKSHEET']) for r in expected]:raise ValueError('Flagged row identity/order differs')
        if detail.find('m:autoFilter',NS) is None:raise ValueError('Detail filter missing')
        if detail.find('m:sheetViews/m:sheetView/m:pane',NS) is None:raise ValueError('Detail frozen panes missing')
    result={'run_id':receipt['run_id'],'qc_render_status':'PASS','detail_rows':len(actual),
        'review_rows':sum(r[0]=='REVIEW' for r in actual),'fail_rows':sum(r[0]=='FAIL' for r in actual),
        'workbook_sha256':sha(report),'input_receipt_sha256':sha(folder/'QC_DISPLAY_INPUTS.json'),
        'validation_scope':'Every summary/detail field, row order/count, REVIEW/FAIL full-row fills, worksheet names, filter and frozen panes.',
        'candidate_only':True,'publication_allowed':False}
    target=folder/'QC_RENDER_VALIDATION_FULL.json'
    with target.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--folder',required=True)
    print(json.dumps(validate(p.parse_args().folder),indent=2))
