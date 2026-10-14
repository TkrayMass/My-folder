#!/bin/bash
# Finalize and render completed evidence only. No mail or publication.
set -eu
umask 077
ROOT=/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX
RID=20261013T213300_8474
AUDIT="$ROOT/runs/$RID"
EVIDENCE="$AUDIT/business_evidence_v1"
QC="$AUDIT/qc_versions/Final_v1"
BASELINE=/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD/baselines/20261007_seed_20261013
test -s "$EVIDENCE/Business_Checks.json"
mkdir -p "$AUDIT/qc_versions"
mkdir "$QC"
python3 "$ROOT/code/compare_distributed_baseline.py" --baseline-dir "$BASELINE" --candidate-dir "/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/$RID" --run-manifest "$AUDIT/RUN_MANIFEST.json" --destination "$QC/comparison" > "$QC/comparison.log" 2>&1
python3 "$ROOT/code/finalize_business_qc.py" --run-manifest "$AUDIT/RUN_MANIFEST.json" --comparison-dir "$QC/comparison" --checks "$EVIDENCE/Business_Checks.json" --destination "$QC"
python3 "$ROOT/code/prepare_server_qc.py" --qc-folder "$QC" --evidence "$EVIDENCE" --destination "$QC/Private_Render_v1"
cp -- "$ROOT/code/Render_Private_QC.sas" "$QC/Private_Render_v1/Executed_Render.sas"
/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas -memsize 2G -nodms -noterminal -sysin "$QC/Private_Render_v1/Executed_Render.sas" -sysparm "$QC/Private_Render_v1" -log "$QC/Private_Render_v1/Render.log" -print "$QC/Private_Render_v1/Render.lst"
python3 "$ROOT/code/validate_server_qc.py" --folder "$QC/Private_Render_v1"
