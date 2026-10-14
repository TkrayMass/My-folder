#!/bin/bash
# Existing candidate evidence only. Does not run SAS, publish, or send mail.
set -u
ROOT="/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD"
RUN_ID="${1:-}"
case "$RUN_ID" in ''|*[!A-Za-z0-9_]*) echo 'Invalid run ID'; exit 1;; esac
[ "${#RUN_ID}" -le 80 ] || exit 1
AUDIT="$ROOT/runs/$RUN_ID"
OUTPUT="/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD/$RUN_ID"
BASELINE="${ENROLLMENT_BASELINE_DIR:-$ROOT/baselines/20261007_seed_20261013}"
CHECKS="${ENROLLMENT_BUSINESS_CHECKS:-$AUDIT/business_evidence/Business_Checks.json}"
PYTHON="${ENROLLMENT_PYTHON:-python3}"
[ -s "$AUDIT/RUN_MANIFEST.json" ] || { echo 'Technical run manifest missing'; exit 1; }
VERSION="$(date -u +%Y%m%dT%H%M%S)_$$"
FINAL_DIR="$AUDIT/qc_versions/$VERSION"
mkdir -p "$FINAL_DIR" || exit 1
"$PYTHON" "$ROOT/code/compare_distributed_baseline.py" --baseline-dir "$BASELINE" \
 --candidate-dir "$OUTPUT" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
 --destination "$FINAL_DIR/comparison" > "$FINAL_DIR/comparison.log" 2>&1
COMPARE_RC=$?
if [ "$COMPARE_RC" -ne 0 ]; then echo "Baseline comparison failed; evidence retained in $FINAL_DIR/comparison.log"; fi
"$PYTHON" "$ROOT/code/finalize_business_qc.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" \
 --comparison-dir "$FINAL_DIR/comparison" --checks "$CHECKS" \
 --destination "$FINAL_DIR" > "$FINAL_DIR/finalization.log" 2>&1
QC_RC=$?
cat "$FINAL_DIR/finalization.log"
echo "QC_EVIDENCE=$FINAL_DIR"
exit "$QC_RC"
