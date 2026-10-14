#!/bin/bash
# Isolated candidate only. No production schedule, transfer, or email.
set -u
umask 077
export LD_LIBRARY_PATH="/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:${LD_LIBRARY_PATH:-}"
SAS_EXE="/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas"
ROOT="/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD"
SAS_PROGRAM="$ROOT/code/ACO_Weekly_Enrollment_Rebuild.sas"
OUTPUT_ROOT="/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD"
FINALIZER="$ROOT/code/finalize_enrollment_run.py"
PYTHON="${ENROLLMENT_PYTHON:-python3}"
mkdir -p "$ROOT" || exit 1
command -v flock >/dev/null || exit 1
command -v "$PYTHON" >/dev/null || exit 1
exec 9>"$ROOT/launcher.lock" || exit 1
flock -n 9 || { echo 'Another candidate launcher is active.'; exit 1; }
RUN_ID="$(date -u +%Y%m%dT%H%M%S)_$$"
AUDIT_DIR="$ROOT/runs/$RUN_ID"
mkdir -p "$ROOT/runs" || exit 1
mkdir "$AUDIT_DIR" || exit 1
LOG="$AUDIT_DIR/SAS.log"
SAS_RC=1
if [ -x "$SAS_EXE" ] && [ -r "$SAS_PROGRAM" ] && [ -r "$FINALIZER" ]; then
    if cp -- "$SAS_PROGRAM" "$AUDIT_DIR/Executed_Report.sas"; then
        "$SAS_EXE" -nodms -noterminal -sysin "$AUDIT_DIR/Executed_Report.sas" -sysparm "$RUN_ID" -log "$LOG" -print "$AUDIT_DIR/SAS.lst"
        SAS_RC=$?
    else
        printf '%s\n' 'ERROR: Cannot preserve candidate program snapshot.' > "$LOG"
    fi
else
    printf '%s\n' 'ERROR: Candidate executable, SAS program, or finalizer missing.' > "$LOG"
fi
# Always finalize available evidence, including a failed SAS attempt. No full-run retry.
"$PYTHON" "$FINALIZER" --run-id "$RUN_ID" --sas-rc "$SAS_RC" --log "$LOG" \
    --output-root "$OUTPUT_ROOT" --audit-dir "$AUDIT_DIR" --program "$AUDIT_DIR/Executed_Report.sas"
exit $?
