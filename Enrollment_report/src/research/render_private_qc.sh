#!/bin/bash
# Completed private QC only. No report refresh, mail, publication or schedules.
set -eu
umask 077
ROOT="${ENROLLMENT_AUDIT_ROOT:-/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD}"
case "$ROOT" in /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD|/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX) ;; *) echo 'Invalid audit root'; exit 1;; esac
RUN_ID="${1:-}"; QC_VERSION="${2:-}"
for VALUE in "$RUN_ID" "$QC_VERSION"; do
 case "$VALUE" in ''|*[!A-Za-z0-9_]*) echo 'Invalid run/version'; exit 1;; esac
 [ "${#VALUE}" -le 80 ] || exit 1
done
AUDIT="$ROOT/runs/$RUN_ID"
QC="$AUDIT/qc_versions/$QC_VERSION"
EVIDENCE="$AUDIT/business_evidence"
PYTHON="${ENROLLMENT_PYTHON:-python3}"
DEST="$QC/Render_$(date -u +%Y%m%dT%H%M%S)_$$"
"$PYTHON" "$ROOT/code/prepare_server_qc.py" --qc-folder "$QC" --evidence "$EVIDENCE" --destination "$DEST"
cp -- "$ROOT/code/Render_Private_QC.sas" "$DEST/Executed_Render.sas"
if /sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas -memsize 2G -nodms -noterminal \
 -sysin "$DEST/Executed_Render.sas" -sysparm "$DEST" -log "$DEST/Render.log" -print "$DEST/Render.lst"; then
 "$PYTHON" "$ROOT/code/validate_server_qc.py" --folder "$DEST"
else
 echo "Private QC render failed; evidence retained: $DEST"
 exit 1
fi
