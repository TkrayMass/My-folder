"""Existing business floors, mean+2/3 sample SD after eight archived pairs."""
import csv,json,hashlib
from decimal import Decimal
from pathlib import Path

def load_history(baseline):
    path=Path(baseline)/'ADAPTIVE_HISTORY.csv'
    groups={};seen=set()
    if not path.exists():return groups
    manifest=json.loads((Path(baseline)/'BASELINE_MANIFEST.json').read_text())
    bound=[a for a in manifest['artifacts'] if a['name']=='ADAPTIVE_HISTORY.csv']
    if len(bound)!=1 or hashlib.sha256(path.read_bytes()).hexdigest()!=bound[0]['sha256']:
        raise ValueError('Adaptive history is not bound to distributed baseline')
    with path.open(newline='') as f:
        for row in csv.DictReader(f):
            identity=(row['PAIR_ID'],row['REPORT_SECTION'],row['CATEGORY'],row['MONTH_ID'])
            if identity in seen:raise ValueError('Duplicate archived comparison pair')
            seen.add(identity)
            value=Decimal(row['ABS_DIFF'])
            if not value.is_finite() or value<0:raise ValueError('Invalid archived comparison difference')
            key=(row['REPORT_SECTION'],row['CATEGORY'],row['MONTH_GROUP'])
            groups.setdefault(key,[]).append(value)
    return groups

def thresholds(values,warning_floor,fail_floor):
    warning,blocking=Decimal(warning_floor),Decimal(fail_floor)
    if len(values)<8:return warning,blocking,False
    average=sum(values)/len(values)
    sd=(sum((v-average)**2 for v in values)/(len(values)-1)).sqrt()
    return max(warning,average+2*sd),max(blocking,average+3*sd),True
