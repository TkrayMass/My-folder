import argparse,json,shlex
from pathlib import Path
from transfer_rebuilt_windows import ROOT,HOST,command,remote_options
from check_transfer_gate import digest

def promote(receipt_path,marker):
    receipt=json.loads(Path(receipt_path).read_text(encoding='utf-8-sig'))
    marker=Path(marker)
    fields=dict(line.split('=',1) for line in marker.read_text(encoding='utf-8-sig').splitlines() if '=' in line)
    if fields.get('RunID')!=receipt['run_id']:raise ValueError('Sent marker run differs')
    remote_verification=None
    if fields.get('ContentVerificationReceipt'):
        verification=Path(fields['ContentVerificationReceipt'])
        if digest(verification)!=fields.get('ContentVerificationSHA256','').lower():raise ValueError('Publication verification receipt changed')
        remote_verification=ROOT+'/notification_receipts/'+receipt['run_id']+'.verification.json'
        command(['scp']+remote_options()+[str(verification),'tkray@'+HOST+':'+remote_verification])
    remote_marker=ROOT+'/notification_receipts/'+receipt['run_id']+'.ok'
    command(['scp']+remote_options()+[str(marker),'tkray@'+HOST+':'+remote_marker])
    remote_package=ROOT+'/notification_receipts/'+receipt['run_id']+'.package.json'
    command(['scp']+remote_options()+[receipt['package_snapshot'],'tkray@'+HOST+':'+remote_package])
    argv=['/usr/bin/python3',ROOT+'/integrated_scheduled_v1/promote_distributed_baseline.py',
          '--package',remote_package,'--marker',remote_marker,'--run-id',receipt['run_id']]
    if remote_verification:argv+=['--verification',remote_verification]
    print(command(['ssh']+remote_options()+['tkray@'+HOST,' '.join(shlex.quote(x) for x in argv)]))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--receipt',required=True);p.add_argument('--marker',required=True)
    a=p.parse_args();promote(a.receipt,a.marker)
