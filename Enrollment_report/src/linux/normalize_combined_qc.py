"""Remove SAS missing-number serialization only where evidence expects blank."""
import argparse,json,os,re,math,copy
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED
import xml.etree.ElementTree as ET
from check_transfer_gate import digest
NS={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
ET.register_namespace('',NS['m'])

def normalize(folder):
    folder=Path(folder);data=json.loads((folder/'COMBINED_QC_INPUTS.json').read_text())
    workbook=folder/('ACO_Weekly_Enrollment_QC_'+data['report_date']+'.xlsx')
    original=digest(workbook);changes=[]
    temporary=workbook.with_suffix('.pending.xlsx')
    with ZipFile(workbook) as source,ZipFile(temporary,'w',ZIP_DEFLATED) as destination:
        styles=ET.fromstring(source.read('xl/styles.xml')) if 'xl/styles.xml' in source.namelist() else None
        style_cache={};bold_fonts={}
        if styles is not None:
            xfs=styles.find('m:cellXfs',NS);fonts=styles.find('m:fonts',NS);borders=styles.find('m:borders',NS)
            border=ET.Element('{'+NS['m']+'}border')
            for side in ('left','right','top','bottom'):
                ET.SubElement(ET.SubElement(border,'{'+NS['m']+'}'+side,{'style':'thin'}),'{'+NS['m']+'}color',{'rgb':'FF808080'})
            ET.SubElement(border,'{'+NS['m']+'}diagonal')
            border_id=len(borders);borders.append(border);borders.set('count',str(len(borders)))
        def cell_style(cell,horizontal,bold=False,bordered=True):
            if styles is None:return
            original=int(cell.get('s','0'));key=(original,horizontal,bold,bordered)
            if key not in style_cache:
                xf=copy.deepcopy(xfs[original]);alignment=xf.find('m:alignment',NS)
                if alignment is None:alignment=ET.SubElement(xf,'{'+NS['m']+'}alignment')
                alignment.set('horizontal',horizontal);alignment.set('vertical','center');alignment.set('wrapText','1')
                xf.set('applyAlignment','1')
                if bordered:xf.set('borderId',str(border_id));xf.set('applyBorder','1')
                if bold:
                    font_id=int(xf.get('fontId','0'))
                    if font_id not in bold_fonts:
                        font=copy.deepcopy(fonts[font_id])
                        if font.find('m:b',NS) is None:ET.SubElement(font,'{'+NS['m']+'}b')
                        bold_fonts[font_id]=len(fonts);fonts.append(font);fonts.set('count',str(len(fonts)))
                    xf.set('fontId',str(bold_fonts[font_id]));xf.set('applyFont','1')
                style_cache[key]=len(xfs);xfs.append(xf);xfs.set('count',str(len(xfs)))
            cell.set('s',str(style_cache[key]))
        strings=[]
        if 'xl/sharedStrings.xml' in source.namelist():strings=[''.join(s.itertext()) for s in ET.fromstring(source.read('xl/sharedStrings.xml'))]
        for info in source.infolist():
            if info.filename=='xl/styles.xml' and styles is not None:continue
            body=source.read(info.filename)
            match=re.fullmatch(r'xl/worksheets/sheet(\d+)\.xml',info.filename)
            if match:
                spec=data['sheets'][int(match.group(1))-1];root=ET.fromstring(body);modified=False
                for row in root.findall('m:sheetData/m:row',NS):
                    row_number=int(row.get('r'))
                    height=32 if row_number in (1,3) else 12 if row_number==2 else 30 if spec.get('name')=='QC_Summary' else 24
                    if row_number>=4 and row_number-4<len(spec['rows']) and 'widths' in spec:
                        height=max(height,max((math.ceil(len(str(v))/max(1,spec['widths'][i]))*18+6 if isinstance(v,str) else height for i,v in enumerate(spec['rows'][row_number-4]))))
                    row.set('ht',str(height));row.set('customHeight','1');modified=True
                    for cell in row:
                        letters=re.sub(r'\d','',cell.get('r'));ci=0
                        for letter in letters:ci=ci*26+ord(letter)-64
                        ci-=1
                        expected=spec['rows'][row_number-4][ci] if row_number>=4 and row_number-4<len(spec['rows']) and ci<len(spec['rows'][row_number-4]) else None
                        value=cell.find('m:v',NS)
                        if isinstance(expected,(int,float)) and cell.get('t')=='s' and value is not None:
                            value.text=strings[int(value.text)].strip();cell.attrib.pop('t',None)
                        cell_style(cell,'center' if row_number==3 else 'right' if isinstance(expected,(int,float)) else 'left',
                          bold=row_number in (1,3) or spec.get('name')=='QC_Summary' and ci==0,bordered=row_number>=3)
                    if int(row.get('r'))==3:
                        for cell in row:
                            letters=re.sub(r'\d','',cell.get('r'));ci=0
                            for letter in letters:ci=ci*26+ord(letter)-64
                            ci-=1
                            headers=spec.get('headers',[])
                            value=cell.find('m:v',NS)
                            if ci<len(headers) and '/' in headers[ci] and cell.get('t')=='s' and value is not None:
                                raw=strings[int(value.text)]
                                if ' '.join(raw.split())==' '.join(headers[ci].replace('/',' ').split()):
                                    cell.remove(value);cell.set('t','inlineStr')
                                    ET.SubElement(ET.SubElement(cell,'{'+NS['m']+'}is'),'{'+NS['m']+'}t').text=headers[ci]
                                    modified=True
                        continue
                    ri=int(row.get('r'))-4
                    if not 0<=ri<len(spec['rows']):continue
                    for cell in row:
                        letters=re.sub(r'\d','',cell.get('r'));ci=0
                        for letter in letters:ci=ci*26+ord(letter)-64
                        ci-=1
                        if ci>=len(spec['rows'][ri]) or spec['rows'][ri][ci] not in (None,''):continue
                        value=cell.find('m:v',NS)
                        raw=value.text if value is not None else None
                        if cell.get('t')=='s' and raw is not None:raw=strings[int(raw)]
                        if value is not None and (raw or '').strip() in ('.','..',''):
                            cell.remove(value);cell.attrib.pop('t',None);modified=True
                            changes.append(spec['name']+'!'+cell.get('r'))
                if modified:body=b'<?xml version="1.0" encoding="utf-8"?>\n'+ET.tostring(root,encoding='utf-8')
            destination.writestr(info,body)
        if styles is not None:destination.writestr(source.getinfo('xl/styles.xml'),b'<?xml version="1.0" encoding="utf-8"?>\n'+ET.tostring(styles,encoding='utf-8'))
    os.replace(str(temporary),str(workbook))
    receipt={'source_sha256':original,'result_sha256':digest(workbook),'blank_cells_normalized':len(changes),
      'policy':'Clear expected blank SAS placeholders, restore matching slash headers, type numeric cells, and fit rows/alignment/borders without changing evidence values.'}
    (folder/'COMBINED_QC_NORMALIZATION.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--folder',required=True)
    print(json.dumps(normalize(parser.parse_args().folder),indent=2))
