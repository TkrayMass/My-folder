#!/bin/bash
# Full fresh-data rehearsal. No publication, email, or schedule changes.
set -euo pipefail
umask 077
export LD_LIBRARY_PATH="/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:${LD_LIBRARY_PATH:-}"
ROOT=/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX
OUTPUT_ROOT=/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX
CODE="${ENROLLMENT_CODE_DIR:-$ROOT/code}"
BASELINE="${ENROLLMENT_BASELINE_DIR:?Set the verified distributed baseline archive directory}"
PYTHON="${ENROLLMENT_PYTHON:-python3}"
SAS_EXE=/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas
test -s "$BASELINE/BASELINE_MANIFEST.json"
exec 9>/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/launcher.lock
flock -n 9 || { echo 'Another enrollment candidate is active'; exit 1; }
RUN_ID="$(date -u +%Y%m%dT%H%M%S)_$$"
AUDIT="$ROOT/runs/$RUN_ID"
mkdir "$AUDIT"
on_exit() {
  rc=$?
  printf "EXIT_CODE=%s\nRUN_ID=%s\n" "$rc" "$RUN_ID" > "$AUDIT/PIPELINE_STATUS.txt"
  if [ "$rc" != 0 ] && [ "${ENROLLMENT_ALERTS_ENABLED:-0}" = 1 ]; then
    "$PYTHON" "$CODE/send_failure_alert.py" --run-id "$RUN_ID" || true
  fi
  exit "$rc"
}
trap on_exit EXIT
mkdir "$AUDIT/code" "$AUDIT/source_controls"
cp -- "$CODE/"*.py "$AUDIT/code/"
cp -- "$CODE/ACO_Weekly_Enrollment_Integrated.sas" "$AUDIT/Executed_Report.sas"
cp -- "$CODE/Validate_Integrated_Run_Sources.sas" "$AUDIT/source_controls/Validate_Combined_Run_Sources.sas"
cp -- "$CODE/Render_Private_QC.sas" "$AUDIT/Render_Private_QC.sas"
cp -- "$CODE/Render_Primary_QC.sas" "$AUDIT/Render_Primary_QC.sas"
LOG="$AUDIT/SAS.log"
SAS_RC=0
"$PYTHON" "$AUDIT/code/run_sas_logged.py" "$SAS_EXE" -memsize 32G -fullstimer -nodms -noterminal \
  -sysin "$AUDIT/Executed_Report.sas" -sysparm "$RUN_ID" \
  -log "$LOG" -print "$AUDIT/SAS.lst" || SAS_RC=$?
OUTPUT="$OUTPUT_ROOT/$RUN_ID"
if [ "$SAS_RC" = 0 ]; then
  paths=("$OUTPUT"/ReportTestMonthly-????????_REBUILD_REGXSA.xlsx)
  if [ "${#paths[@]}" != 1 ] || [ ! -s "${paths[0]}" ]; then exit 1; fi
  REPORT="${paths[0]}"
  NAME="${REPORT##*/}"; REPORT_DATE="${NAME#ReportTestMonthly-}"; REPORT_DATE="${REPORT_DATE%%_*}"
  cp -- "$REPORT" "$AUDIT/SAS_Raw_REGXSA.xlsx"
  "$PYTHON" "$AUDIT/code/normalize_full_report.py" --source "$AUDIT/SAS_Raw_REGXSA.xlsx" \
    --destination "$OUTPUT/Formatted_REGXSA.pending.xlsx" --program "$AUDIT/Executed_Report.sas" \
    --report-date "$REPORT_DATE" > "$AUDIT/Formatting.log" 2>&1
  mv -- "$OUTPUT/Formatted_REGXSA.pending.xlsx" "$REPORT"
fi
"$PYTHON" "$AUDIT/code/finalize_enrollment_run.py" --run-id "$RUN_ID" --sas-rc "$SAS_RC" \
  --log "$LOG" --output-root "$OUTPUT_ROOT" --audit-dir "$AUDIT" \
  --program "$AUDIT/Executed_Report.sas" --output-format xlsx
"$PYTHON" "$AUDIT/code/run_sas_logged.py" "$SAS_EXE" -nodms -noterminal -sysin "$AUDIT/source_controls/Validate_Combined_Run_Sources.sas" \
  -sysparm "$AUDIT/source_controls" -log "$AUDIT/source_controls/Source_Checks.log" \
  -print "$AUDIT/source_controls/Source_Checks.lst"
"$PYTHON" "$AUDIT/code/assemble_source_checks.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --evidence-dir "$AUDIT/source_controls" --current-matrix "$OUTPUT/QC_Current_Matrix.csv"
"$PYTHON" "$AUDIT/code/compare_distributed_baseline.py" --baseline-dir "$BASELINE" \
  --candidate-dir "$OUTPUT" --run-manifest "$AUDIT/RUN_MANIFEST.json" --destination "$AUDIT/comparison"
"$PYTHON" "$AUDIT/code/run_workbook_checks.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --baseline-dir "$BASELINE" --report "$REPORT" --source-checks "$AUDIT/source_controls/Business_Checks.json" \
  --destination "$AUDIT/business_evidence"
QC="$AUDIT/qc_versions/Integrated_v1"
"$PYTHON" "$AUDIT/code/finalize_business_qc.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --comparison-dir "$AUDIT/comparison" --checks "$AUDIT/business_evidence/Business_Checks.json" --destination "$QC"
"$PYTHON" "$AUDIT/code/prepare_server_qc.py" --qc-folder "$QC" \
  --evidence "$AUDIT/business_evidence" --destination "$QC/Private_Render"
"$PYTHON" "$AUDIT/code/run_sas_logged.py" "$SAS_EXE" -nodms -noterminal -sysin "$AUDIT/Render_Private_QC.sas" \
  -sysparm "$QC/Private_Render" -log "$QC/Private_Render/Render.log" -print "$QC/Private_Render/Render.lst"
"$PYTHON" "$AUDIT/code/validate_server_qc.py" --folder "$QC/Private_Render"
"$PYTHON" "$AUDIT/code/prepare_primary_qc.py" --final-qc "$QC/FINAL_QC.json" \
  --evidence "$AUDIT/business_evidence" --destination "$QC/Primary_Render"
"$PYTHON" "$AUDIT/code/run_sas_logged.py" "$SAS_EXE" -nodms -noterminal \
  -sysin "$AUDIT/Render_Primary_QC.sas" -sysparm "$QC/Primary_Render" \
  -log "$QC/Primary_Render/Render.log" -print "$QC/Primary_Render/Render.lst"
mv -- "$QC/Primary_Render/ACO_Enrollment_Comparison_QC.xlsx" "$QC/Primary_Render/Primary_Raw.xlsx"
"$PYTHON" "$AUDIT/code/normalize_report_font.py" --source "$QC/Primary_Render/Primary_Raw.xlsx" \
  --destination "$QC/Primary_Render/ACO_Enrollment_Comparison_QC.xlsx"
"$PYTHON" "$AUDIT/code/validate_primary_qc.py" --folder "$QC/Primary_Render"
COMBINED="$QC/Combined_Render"
"$PYTHON" "$AUDIT/code/prepare_combined_qc.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --final-qc "$QC/FINAL_QC.json" --policy "$AUDIT/business_evidence/Baseline_Policy.csv" \
  --comparison "$AUDIT/comparison/BASELINE_COMPARISON.json" --private-folder "$QC/Private_Render" --destination "$COMBINED"
"$PYTHON" "$AUDIT/code/run_sas_logged.py" "$SAS_EXE" -nodms -noterminal \
  -sysin "$COMBINED/Render_Combined_QC.sas" -sysparm "$COMBINED" \
  -log "$COMBINED/Render.log" -print "$COMBINED/Render.lst"
"$PYTHON" "$AUDIT/code/normalize_combined_qc.py" --folder "$COMBINED"
"$PYTHON" "$AUDIT/code/validate_combined_qc.py" --folder "$COMBINED"
"$PYTHON" "$AUDIT/code/check_transfer_gate.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --final-qc "$QC/FINAL_QC.json" --report "$REPORT" > "$AUDIT/TRANSFER_GATE.json"
printf 'INTEGRATED_CANDIDATE_COMPLETE RUN_ID=%s\n' "$RUN_ID"
"$PYTHON" "$AUDIT/code/prepare_transfer_package.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
  --final-qc "$QC/FINAL_QC.json" --report "$REPORT" --render-folder "$QC/Private_Render" \
  --destination "$ROOT/releases/$RUN_ID"
if [ "${ENROLLMENT_QC_EMAIL_ENABLED:-0}" = 1 ]; then
  "$PYTHON" "$AUDIT/code/send_qc_email.py" --run-id "$RUN_ID"
fi
cp -- "$ROOT/releases/$RUN_ID/TRANSFER_PACKAGE.json" "$ROOT/LATEST_RELEASE.json.$RUN_ID.partial"
mv -- "$ROOT/LATEST_RELEASE.json.$RUN_ID.partial" "$ROOT/LATEST_RELEASE.json"
