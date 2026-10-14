"""Download a completed native XLSX release and publish directly to OneDrive."""
import argparse
import datetime
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from check_transfer_gate import validate, digest
from verify_published_report import verify as verify_publication

HOST='dph-pr-sgn-lap09.hhs.comacloud.net'
ROOT='/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX'

def remote_options():
    return ['-i',str(Path.home()/'.ssh/aco_linux_transfer'),'-o','BatchMode=yes',
            '-o','StrictHostKeyChecking=yes','-o','HostKeyAlias=dph-pr-sgn-lap09',
            '-o','ConnectTimeout=10']

def command(argv):
    result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True)
    if result.returncode:raise RuntimeError(result.stderr.strip())
    return result.stdout

def eligible_release(package,date,not_before=None):
    if package.get('report_date')!=date:raise ValueError('Latest release does not match requested date')
    if package.get('release_allowed') is not True:raise ValueError('Release blocked')
    if not_before is not None:
        started=datetime.datetime.strptime(package['run_id'].split('_')[0],'%Y%m%dT%H%M%S').replace(tzinfo=datetime.timezone.utc)
        if started<not_before:raise ValueError('Waiting for a new run started at or after the scheduled 1 PM time')

def selected_report_date(explicit=None,latest_wednesday=False,today=None):
    today=today or datetime.date.today()
    if explicit and latest_wednesday:raise ValueError('Choose explicit date or latest Wednesday')
    if explicit:
        datetime.datetime.strptime(explicit,'%Y%m%d')
        return explicit
    if latest_wednesday:
        today-=datetime.timedelta(days=(today.weekday()-2)%7)
    return today.strftime('%Y%m%d')

def fetch_package(path,date,wait_minutes,not_before=None):
    deadline=time.monotonic()+wait_minutes*60
    while True:
        try:
            text=command(['ssh']+remote_options()+['tkray@'+HOST,'cat '+shlex.quote(path)])
            package=json.loads(text)
            eligible_release(package,date,not_before)
            return text,package
        except (RuntimeError,ValueError) as exc:
            if time.monotonic()>=deadline:raise
            print('Waiting for verified release: '+str(exc),flush=True)
            time.sleep(30)

def copy_verified(source,destination,expected,replace=False,backup_root=None):
    source,destination=Path(source),Path(destination)
    if digest(source)!=expected:raise ValueError('Source hash changed')
    destination.parent.mkdir(parents=True,exist_ok=True)
    if destination.exists() and digest(destination)==expected:return
    partial=destination.parent/('.'+uuid.uuid4().hex+'.partial')
    shutil.copyfile(str(source),str(partial))
    if digest(partial)!=expected:raise ValueError('Copied file checksum differs; partial retained')
    if destination.exists():
        if not replace:raise FileExistsError('Different destination exists; original retained')
        archive=Path(backup_root) if backup_root else destination.parent
        archive.mkdir(parents=True,exist_ok=True)
        backup=archive/(destination.stem+'.previous_'+uuid.uuid4().hex+destination.suffix)
        shutil.copyfile(str(destination),str(backup))
        if digest(backup)!=digest(destination):raise ValueError('Backup differs')
    os.replace(str(partial),str(destination))
    if digest(destination)!=expected:raise ValueError('Final copy checksum differs')

def publish_to_onedrive(source,folder,name,gate,staging,replace_existing=False):
    destination=Path(folder).resolve()/name
    if replace_existing:
        copy_verified(source,destination,gate['report_sha256'],True,staging/'Previous_Destinations')
    elif destination.exists() and digest(destination)!=gate['report_sha256']:
        # Keep a previously published, equivalent Excel save instead of overwriting an open workbook.
        verify_publication(source,destination,gate['report_sha256'],gate['run_id'],gate['report_date'],
                           staging/'Existing_Publication_Verification.json')
    else:
        copy_verified(source,destination,gate['report_sha256'])
    return destination

def main(a):
    date=selected_report_date(a.report_date,getattr(a,'latest_wednesday',False))
    datetime.datetime.strptime(date,'%Y%m%d')
    not_before=None
    if getattr(a,'not_before_local',None):
        not_before=datetime.datetime.strptime(date+a.not_before_local,'%Y%m%d%H:%M').astimezone().astimezone(datetime.timezone.utc)
    text,package=fetch_package(a.package,date,a.wait_minutes,not_before)
    run_id=package['run_id']
    if not run_id or any(c not in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_' for c in run_id):
        raise ValueError('Invalid run identifier')
    staging=Path(a.staging).resolve()/run_id
    staging.mkdir(parents=True,exist_ok=True)
    lock=staging/'TRANSFER.lock'
    with lock.open('x') as handle:handle.write(str(os.getpid()))
    try:
        (staging/'TRANSFER_PACKAGE.json').write_text(text)
        files={}
        for kind,item in package['artifacts'].items():
            path=item['path']
            if not (path.startswith(ROOT+'/runs/') or path.startswith('/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/')):
                raise ValueError('Artifact outside enrollment run roots')
            target=staging/Path(path).name
            if not target.exists() or digest(target)!=item['sha256']:
                partial=target.with_name(target.name+'.download')
                command(['scp']+remote_options()+['tkray@'+HOST+':'+path,str(partial)])
                if partial.stat().st_size!=item['bytes'] or digest(partial)!=item['sha256']:
                    raise ValueError('Downloaded artifact differs: '+kind)
                os.replace(str(partial),str(target))
            files[kind]=target
        gate=validate(files['run_manifest'],files['final_qc'],files['report'])
        render=json.loads(files['qc_render_receipt'].read_text())
        inputs=json.loads(files['qc_input_receipt'].read_text())
        if (render.get('run_id')!=run_id or render.get('qc_render_status')!='PASS' or
            render.get('fail_rows')!=0 or render.get('workbook_sha256')!=digest(files['private_qc']) or
            render.get('input_receipt_sha256')!=digest(files['qc_input_receipt']) or
            inputs.get('run_id')!=run_id or inputs.get('qc_sha256')!=digest(files['final_qc'])):
            raise ValueError('QC render binding differs')
        primary=json.loads(files['primary_qc_receipt'].read_text())
        if (primary.get('run_id')!=run_id or primary.get('primary_qc_status')!='PASS' or
            primary.get('failures')!=0 or primary.get('final_qc_sha256')!=digest(files['final_qc']) or
            primary.get('workbook_sha256')!=digest(files['primary_qc']) or
            primary.get('inputs_sha256')!=digest(files['primary_qc_inputs'])):
            raise ValueError('Primary QC binding differs')
        report_name='ReportTestMonthly-{}_REGXSA.xlsx'.format(date)
        backups=staging/'Previous_Destinations'
        qc_target=Path(a.qc_folder).resolve()/('ACO_Weekly_Enrollment_Technical_QC_'+date+'.xlsx')
        copy_verified(files['private_qc'],qc_target,digest(files['private_qc']),a.publish,backups)
        primary_target=Path(a.qc_folder).resolve()/('ACO_Enrollment_Comparison_QC_'+date+'.xlsx')
        copy_verified(files['primary_qc'],primary_target,digest(files['primary_qc']),a.publish,backups)
        published=None
        if a.publish:
            published=publish_to_onedrive(files['report'],a.publish_folder,report_name,gate,staging,getattr(a,'replace_existing',False))
        receipt={'run_id':run_id,'report_date':date,'qc_decision':gate['qc_decision'],
                 'release_package_path':a.package,
                 'package_snapshot':str(staging/'TRANSFER_PACKAGE.json'),
                 'report_sha256':gate['report_sha256'],'approved_source':str(files['report']),
                 'transfer_route':'LINUX_TO_ONEDRIVE',
                 'private_qc':str(qc_target),'primary_qc':str(primary_target),
                 'published_file':str(published) if published else None,
                 'cloud_sync_verified':False,'distribution_email_sent':False}
        (staging/'TRANSFER_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if published:
            latest=Path(a.staging).resolve()/'LATEST_TRANSFER_RECEIPT.json'
            temporary=latest.with_suffix('.partial')
            temporary.write_text(json.dumps(receipt,indent=2)+'\n');os.replace(str(temporary),str(latest))
        print(json.dumps(receipt,indent=2),flush=True)
    finally:
        lock.unlink()

if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--package',default=ROOT+'/LATEST_RELEASE.json')
    dates=p.add_mutually_exclusive_group()
    dates.add_argument('--report-date')
    dates.add_argument('--latest-wednesday',action='store_true',help='Transfer the most recent Wednesday report, including Thursday retries')
    p.add_argument('--wait-minutes',type=int,default=90)
    p.add_argument('--not-before-local',help='Ignore releases started before this local report-date HH:MM time')
    p.add_argument('--replace-existing',action='store_true',help='Preserve a verified backup before replacing the same-date publication')
    for name in ('staging','qc-folder'):p.add_argument('--'+name,required=True)
    p.add_argument('--publish-folder');p.add_argument('--publish',action='store_true')
    a=p.parse_args()
    if a.publish and not a.publish_folder:p.error('--publish requires --publish-folder')
    main(a)
