#!/bin/bash
# Explicit entry point for validated fresh-data generation and release handoff.
set -euo pipefail
ROOT=/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX
export ENROLLMENT_CODE_DIR="$ROOT/integrated_scheduled_v1"
export ENROLLMENT_PYTHON=/usr/bin/python3
export ENROLLMENT_ALERTS_ENABLED=1
export ENROLLMENT_QC_EMAIL_ENABLED=1
IFS= read -r ENROLLMENT_BASELINE_DIR < "$ROOT/CURRENT_DISTRIBUTED_BASELINE.txt"
export ENROLLMENT_BASELINE_DIR
test -s "$ENROLLMENT_BASELINE_DIR/BASELINE_MANIFEST.json"
exec bash "$ENROLLMENT_CODE_DIR/run_enrollment_integrated_candidate.sh"
