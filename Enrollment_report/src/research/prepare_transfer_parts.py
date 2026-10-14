"""Prepare lossless test pieces and verify reconstruction. No network or mail."""
import argparse,base64,hashlib,json
from pathlib import Path

def prepare(source,destination):
    source=Path(source);destination=Path(destination)
    if destination.exists():raise FileExistsError('Keep prior test pieces')
    raw=source.read_bytes();sha=hashlib.sha256(raw).hexdigest()
    if sha!='f4883f08c3a3fb2ed51df78ffaba31a270ebe22dcac43a3e228bc78baaf04d9e':raise ValueError('Reviewed report differs')
    encoded=base64.b64encode(raw);size=12_000_000
    destination.mkdir();parts=[]
    for i,start in enumerate(range(0,len(encoded),size),1):
        data=encoded[start:start+size];name='ACO_TEST_20261013_213300_part'+str(i).zfill(3)+'.txt'
        (destination/name).write_bytes(data)
        parts.append({'name':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    reconstructed=base64.b64decode(b''.join((destination/p['name']).read_bytes() for p in parts),validate=True)
    if reconstructed!=raw:raise ValueError('Reconstruction differs')
    result={'run_id':'20261013T213300_8474','report_name':source.name,'report_bytes':len(raw),'report_sha256':sha,'encoding':'Concatenate numbered ASCII base64 pieces in order, then decode once','parts':parts,'reconstruction_verified':True,'email_sent':False,'publication_allowed':False}
    (destination/'TRANSFER_MANIFEST.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='encoding'},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--destination',required=True);a=p.parse_args();prepare(a.source,a.destination)
