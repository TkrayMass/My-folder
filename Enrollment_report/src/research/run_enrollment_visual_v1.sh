#!/bin/bash
# Isolated formatting test. No refresh, publication, mail or schedule changes.
set -u
umask 077
export LD_LIBRARY_PATH="/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:${LD_LIBRARY_PATH:-}"
ROOT="/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX"
OUTPUT_ROOT="/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX"
SAS_EXE="/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas"
PYTHON="${ENROLLMENT_PYTHON:-python3}"
exec 9>"/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/launcher.lock" || exit 1
flock -n 9 || { echo 'Another isolated candidate run is active.'; exit 1; }
RUN_ID="$(date -u +%Y%m%dT%H%M%S)_$$"
AUDIT_DIR="$ROOT/runs/$RUN_ID"
mkdir -p "$ROOT/runs" || exit 1
mkdir "$AUDIT_DIR" || exit 1
cp -- "$ROOT/code/ACO_Weekly_Enrollment_Visual_Match.sas" "$AUDIT_DIR/Executed_Report.sas" || exit 1
cp -- "$ROOT/code/normalize_full_report.py" "$AUDIT_DIR/Executed_Normalizer.py" || exit 1
cp -- "$ROOT/code/finalize_enrollment_run.py" "$AUDIT_DIR/Executed_Finalizer.py" || exit 1
LOG="$AUDIT_DIR/SAS.log"
printf 'STARTED %s\n' "$RUN_ID"
"$SAS_EXE" -memsize 32G -fullstimer -nodms -noterminal -sysin "$AUDIT_DIR/Executed_Report.sas" -sysparm "$RUN_ID" -log "$LOG" -print "$AUDIT_DIR/SAS.lst"
SAS_RC=$?
if [ "$SAS_RC" = 0 ]; then
    paths=("$OUTPUT_ROOT/$RUN_ID"/ReportTestMonthly-????????_REBUILD_REGXSA.xlsx)
    if [ "${#paths[@]}" = 1 ] && [ -s "${paths[0]}" ]; then
        REPORT="${paths[0]}"
        NAME="${REPORT##*/}"
        REPORT_DATE="${NAME#ReportTestMonthly-}"
        REPORT_DATE="${REPORT_DATE%%_*}"
        RAW="$AUDIT_DIR/SAS_Raw_REGXSA.xlsx"
        FORMATTED="$OUTPUT_ROOT/$RUN_ID/Formatted_REGXSA.pending.xlsx"
        if cp -- "$REPORT" "$RAW" && "$PYTHON" "$AUDIT_DIR/Executed_Normalizer.py" --source "$RAW" --destination "$FORMATTED" --program "$AUDIT_DIR/Executed_Report.sas" --report-date "$REPORT_DATE" > "$AUDIT_DIR/Formatting.log" 2>&1; then
            if mv -- "$FORMATTED" "$REPORT"; then
                cp -- "$OUTPUT_ROOT/$RUN_ID/Formatted_REGXSA.pending.format_receipt.json" "$AUDIT_DIR/FORMAT_RECEIPT.json" || SAS_RC=1
            else
                SAS_RC=1
            fi
        else
            SAS_RC=1
        fi
    else
        SAS_RC=1
    fi
    if [ "$SAS_RC" != 0 ]; then
        printf '\nERROR: Isolated native report formatting failed; see Formatting.log.\n' >> "$LOG"
    fi
fi
"$PYTHON" "$AUDIT_DIR/Executed_Finalizer.py" --run-id "$RUN_ID" --sas-rc "$SAS_RC" --log "$LOG" --output-root "$OUTPUT_ROOT" --audit-dir "$AUDIT_DIR" --program "$AUDIT_DIR/Executed_Report.sas" --output-format xlsx
exit $?
