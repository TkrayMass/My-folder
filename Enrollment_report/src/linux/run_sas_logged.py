"""Run SAS and recover WorkspaceServer-routed logs without changing SAS config."""
import os
import re
import subprocess
import sys
import time
import json
import hashlib
from pathlib import Path

PREFIX = re.compile(r'^\d{4}-\d\d-\d\dT\S+\s+(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+\[[^\]]+\]\s+:tkray - ?(.*)$')

def scope_program_log(path):
    """Retain startup separately; reject every actual error in program execution."""
    path=Path(path)
    full=path.read_text()
    boundary='NOTE: AUTOEXEC processing completed.\n'
    if full.count(boundary)!=1:
        raise ValueError('Cannot establish unique AUTOEXEC/program boundary')
    startup,program=full.split(boundary,1)
    error=re.compile(r'^\s*ERROR(?:\s+\d+(?:-\d+)?)?\s*:.*$',re.M)
    allowed={'ERROR: Cannot retrieve metadata from SAS Metadata Repository.',
             'ERROR: Error in the LIBNAME statement.'}
    startup_errors=[m.group().strip() for m in error.finditer(startup)]
    if not startup_errors or not set(startup_errors).issubset(allowed):
        raise ValueError('Unexpected startup errors require review')
    summary='ERROR: Errors printed on pages 1,2,3.'
    program_errors=[m.group().strip() for m in error.finditer(program)]
    if program_errors != [summary]:
        raise ValueError('Program has actual errors or unexpected summary; blocked')
    program='\n'.join(line for line in program.splitlines() if line.strip()!=summary)+'\n'
    retained=Path(str(path)+'.full_with_startup')
    with retained.open('x') as handle:handle.write(full)
    receipt={'full_log_sha256':hashlib.sha256(full.encode()).hexdigest(),
             'program_log_sha256':hashlib.sha256(program.encode()).hexdigest(),
             'startup_error_count':len(startup_errors),'startup_errors':startup_errors,
             'program_error_count':0,'summary_attributed_to_startup':summary,
             'scope':'Program log starts after explicit AUTOEXEC completion. Full original retained.'}
    Path(str(path)+'.scope_receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    path.write_text(program)

def recover_log(source, destination):
    source, destination = Path(source), Path(destination)
    raw = source.read_bytes()
    if not raw:
        raise ValueError('Workspace log is empty')
    text = raw.decode('utf-8', errors='replace')
    lines = []
    count = 0
    for line in text.splitlines():
        match = PREFIX.match(line)
        if match:
            count += 1
            line = match.group(1)
        lines.append(line)
    if not count:
        raise ValueError('Workspace log format was not recognized')
    with Path(str(destination) + '.workspace_raw').open('xb') as handle:
        handle.write(raw)
    with destination.open('x') as handle:
        handle.write('\n'.join(lines) + '\n')

def main(argv):
    # These jobs explicitly initialize WORK and their Snowflake connection.
    # Avoid inheriting SAS Studio's unrelated metadata-library AUTOEXEC.
    if '-autoexec' not in argv[1:]:
        argv=argv[:1]+['-autoexec','/dev/null']+argv[1:]
    args = argv[1:]
    log_index = args.index('-log')
    desired = Path(args[log_index + 1])
    if desired.exists():
        raise FileExistsError('Preserve existing requested SAS log')
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL)
    actual = None
    while process.poll() is None:
        try:
            for fd in Path('/proc/{}/fd'.format(process.pid)).iterdir():
                try:
                    target = os.readlink(str(fd))
                    if 'WorkspaceServer_' in target and target.endswith('.log'):
                        actual = Path(target)
                except OSError:
                    pass
        except OSError:
            pass
        time.sleep(0.25)
    if not desired.is_file():
        if actual is None:
            raise RuntimeError('SAS log missing and alternate log was not found')
        recover_log(actual, desired)
    return process.returncode

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
