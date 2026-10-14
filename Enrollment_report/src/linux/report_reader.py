"""Read report rows from XML2003 or native XLSX using Python's standard library.

The XLSX adapter preserves stored numeric precision. It does not rewrite files,
evaluate formulas, or make an incomplete workbook eligible for distribution.
"""
import posixpath
import re
import xml.etree.ElementTree as ET
from decimal import Decimal
from zipfile import ZipFile, is_zipfile

SS = 'urn:schemas-microsoft-com:office:spreadsheet'
X = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

def colindex(ref):
    result = 0
    for c in re.match(r'[A-Z]+', ref).group():
        result = result * 26 + ord(c) - 64
    return result

def report_events(path):
    if not is_zipfile(path):
        yield from ET.iterparse(path, events=('start', 'end'))
        return
    with ZipFile(path) as z:
        strings = []
        if 'xl/sharedStrings.xml' in z.namelist():
            with z.open('xl/sharedStrings.xml') as stream:
                for _, e in ET.iterparse(stream, events=('end',)):
                    if e.tag == '{'+X+'}si':
                        strings.append(''.join(t.text or '' for t in e.iter('{'+X+'}t')))
                        e.clear()
        styles = ET.fromstring(z.read('xl/styles.xml'))
        formats = {9: '0%', 10: '0.00%'}
        for e in styles.findall('{'+X+'}numFmts/{'+X+'}numFmt'):
            formats[int(e.get('numFmtId'))] = e.get('formatCode')
        style_formats = [formats.get(int(e.get('numFmtId', '0')), '')
                         for e in styles.find('{'+X+'}cellXfs')]
        rels = {e.get('Id'): e.get('Target')
                for e in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        workbook = ET.fromstring(z.read('xl/workbook.xml'))
        for item in workbook.find('{'+X+'}sheets'):
            target = rels[item.get('{'+REL+'}id')]
            entry = target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/'+target)
            sheet = ET.Element('{'+SS+'}Worksheet', {'{'+SS+'}Name': item.get('name')})
            table = ET.SubElement(sheet, '{'+SS+'}Table')
            yield 'start', sheet
            yield 'start', table
            previous = 0
            with z.open(entry) as stream:
                for _, row in ET.iterparse(stream, events=('end',)):
                    if row.tag != '{'+X+'}row':
                        continue
                    row_number = int(row.get('r'))
                    for _ in range(previous+1, row_number):
                        blank = ET.SubElement(table, '{'+SS+'}Row')
                        yield 'end', blank
                    adapted = ET.SubElement(table, '{'+SS+'}Row')
                    for c in row:
                        if c.tag != '{'+X+'}c':
                            continue
                        if c.find('{'+X+'}f') is not None:
                            raise ValueError('Unexpected formula in SAS report: '+c.get('r'))
                        value = c.find('{'+X+'}v')
                        if c.get('t') == 's':
                            text = strings[int(value.text)] if value is not None and value.text else ''
                        elif c.get('t') == 'inlineStr':
                            text = ''.join(t.text or '' for t in c.iter('{'+X+'}t'))
                        elif c.get('t') == 'e':
                            raise ValueError('XLSX cell error: '+c.get('r'))
                        else:
                            text = value.text if value is not None and value.text else ''
                            fmt = style_formats[int(c.get('s', '0'))]
                            if text and '%' in fmt and c.get('t') not in ('str', 'b'):
                                text = str(Decimal(text)*100)+'%'
                        if text:
                            cell = ET.SubElement(adapted, '{'+SS+'}Cell', {'{'+SS+'}Index': str(colindex(c.get('r')))})
                            ET.SubElement(cell, '{'+SS+'}Data').text = text.replace('\u00a0', ' ')
                    yield 'end', adapted
                    previous = row_number
                    row.clear()
            yield 'end', sheet
