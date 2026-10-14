"""Resume QC after a known WorkspaceServer log-routing failure. Never refresh."""
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from run_sas_logged_v2 import recover_log, scope_program_log

ROOT=Path('/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX')
RID='20261014T140541_5343'
AUDIT=ROOT/'runs'/RID
RECOVERY=AUDIT/'Logging_Recovery_v3'
BASELINE='/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/baselines/20261007_seed_20261013'
WORKSPACE_LOG='/sas/grid/94M7/config/Lev2/Logs/SASAppGrid_WorkspaceServer_2026-10-14_dph-pr-sgn-lap04_5353.log'

def main():
    RECOVERY.mkdir(exist_ok=False)
    print('Waiting for existing launcher 5343; no new refresh will run',flush=True)
    deadline=time.time()+7200
    while Path('/proc/5343').exists():
        command=Path('/proc/5343/cmdline').read_bytes()
        if b'run_enrollment_integrated_candidate.sh' not in command:
            raise RuntimeError('Launcher PID identity changed; stopped')
        if time.time()>deadline:
            raise RuntimeError('Wait limit reached; original run untouched')
        time.sleep(2)
    original=json.loads((AUDIT/'RUN_MANIFEST.json').read_text())
    allowed={'Missing or empty SAS log','Missing, duplicate or mismatched completion marker',
             'Completion identity mismatch'}
    if original.get('technical_status')=='PASS':
        print('Original technical checks passed; recovery not needed',flush=True)
        return
    if original.get('sas_return_code')!=0 or not original.get('failures') or not set(original['failures']).issubset(allowed):
        raise RuntimeError('Failure is not solely log routing; do not resume automatically')
    if any((AUDIT/name).exists() for name in ['business_evidence','comparison','qc_versions']):
        raise RuntimeError('Downstream evidence already exists; preserve before review')
    log=RECOVERY/'SAS.log'
    recover_log(WORKSPACE_LOG,log)
    scope_program_log(log)
    markers=re.findall(r'^\s*NOTE: ACO_REBUILD_RUN_COMPLETE REPDT=(\d{8}) RUNID=([A-Za-z0-9_]+)\s*$',log.read_text(),re.M)
    if markers != [('20261014',RID)]:
        raise RuntimeError('Recovered log does not contain exactly the expected completion marker')
    completion=dict(line.split('=',1) for line in (Path('/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX')/RID/'TECHNICAL_COMPLETE.txt').read_text().splitlines())
    if completion.get('RunID')!=RID or completion.get('ReportDate')!='20261014':
        raise RuntimeError('Independent completion identity differs')
    code=ROOT/'integrated_candidate_20261014'
    wrapper=(code/'run_enrollment_integrated_candidate.sh').read_text()
    marker='"$PYTHON" "$AUDIT/code/finalize_enrollment_run.py"'
    if wrapper.count(marker)!=1:
        raise RuntimeError('Unexpected launcher format')
    tail=wrapper[wrapper.index(marker):]
    tail=tail.replace('--audit-dir "$AUDIT"','--audit-dir "$RECOVERY"')
    tail=tail.replace('$AUDIT/RUN_MANIFEST.json','$RECOVERY/RUN_MANIFEST.json')
    helper=Path(__file__).resolve().parent/'run_sas_logged_v2.py'
    tail=tail.replace('"$SAS_EXE"','"$PYTHON" '+shlex.quote(str(helper))+' "$SAS_EXE"')
    values={'ROOT':str(ROOT),'RUN_ID':RID,'AUDIT':str(AUDIT),'RECOVERY':str(RECOVERY),
            'OUTPUT_ROOT':'/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX',
            'OUTPUT':'/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/'+RID,
            'REPORT':'/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/'+RID+'/ReportTestMonthly-20261014_REBUILD_REGXSA.xlsx',
            'LOG':str(log),'CODE':str(code),'PYTHON':'/usr/bin/python3','SAS_RC':'0',
            'BASELINE':BASELINE,'SAS_EXE':'/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas'}
    head='#!/bin/bash\nset -euo pipefail\numask 077\n'
    head+='export LD_LIBRARY_PATH="/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:${LD_LIBRARY_PATH:-}"\n'
    head+='\n'.join(k+'='+shlex.quote(v) for k,v in values.items())+'\n'
    head+='exec 9>/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/launcher.lock\nflock -n 9\n'
    head+='trap \'rc=$?; printf "EXIT_CODE=%s\\n" "$rc" > "$RECOVERY/PIPELINE_STATUS.txt"\' EXIT\n'
    script=RECOVERY/'resume_qc.sh'
    script.write_text(head+tail)
    subprocess.run(['bash','-n',str(script)],check=True)
    subprocess.run(['bash',str(script)],check=True)
    print('LOGGING_RECOVERY_AND_QC_COMPLETE',flush=True)

if __name__=='__main__':
    main()
