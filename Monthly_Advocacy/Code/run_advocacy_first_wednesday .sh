#!/bin/bash
#===============================================================================
# Monthly Advocacy Report
# FIRST-WEDNESDAY SERVER RUNNER v2
#
# PURPOSE
#   Launch the validated Monthly Advocacy SAS automation wrapper unattended.
#
# NORMAL USE
#   Cron calls this script every Wednesday at 10:00 AM Eastern.
#   The script runs SAS only when today is the FIRST Wednesday of the month:
#     - weekday = Wednesday
#     - calendar day = 1 through 7
#
# SAS WRAPPER
#   /sas_mass_health/shared/Advocacy_Dynamic/Code/
#   Advocacy_First_Wednesday_Run_Wrapper_v1.sas
#
# NOTES
#   - Proc 0 through Proc 10 are run by the SAS wrapper.
#   - Detailed SAS log is written by the wrapper to Advocacy_Dynamic/Logs.
#   - QC status CSV and SUCCESS flag are written to Advocacy_Dynamic/QC.
#   - This shell runner always writes a small launcher log, including SKIPPED runs.
#===============================================================================

set -u

#-------------------------------------------------------------------------------
# 1. Production paths
#-------------------------------------------------------------------------------
SAS_EXE="/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas"

ADV_BASE="/sas_mass_health/shared/Advocacy_Dynamic"
SAS_PROGRAM="${ADV_BASE}/Code/Advocacy_First_Wednesday_Run_Wrapper_v1.sas"
RUNNER_LOG_DIR="${ADV_BASE}/Logs"

#-------------------------------------------------------------------------------
# 2. Create launcher log first so every invocation is auditable
#-------------------------------------------------------------------------------
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUNNER_LOG="${RUNNER_LOG_DIR}/Advocacy_First_Wednesday_Launcher_${RUN_STAMP}.log"

if [ ! -d "${RUNNER_LOG_DIR}" ]; then
    echo "ERROR: Log directory not found: ${RUNNER_LOG_DIR}" >&2
    exit 12
fi

{
    echo "=================================================================="
    echo "MONTHLY ADVOCACY FIRST-WEDNESDAY RUNNER"
    echo "START: $(date)"
    echo "HOST: $(hostname)"
    echo "SAS PROGRAM: ${SAS_PROGRAM}"
    echo "=================================================================="
} >> "${RUNNER_LOG}"

#-------------------------------------------------------------------------------
# 3. First-Wednesday safety gate
#    date +%u: Monday=1 ... Wednesday=3 ... Sunday=7
#-------------------------------------------------------------------------------
DAY_OF_MONTH=$(date +%d)
DAY_OF_MONTH=$((10#$DAY_OF_MONTH))
DAY_OF_WEEK=$(date +%u)

if [ "${DAY_OF_WEEK}" -ne 3 ] || [ "${DAY_OF_MONTH}" -gt 7 ]; then
    {
        echo "STATUS: SKIPPED"
        echo "REASON: Today is not the first Wednesday of the month."
        echo "DAY_OF_WEEK=${DAY_OF_WEEK}"
        echo "DAY_OF_MONTH=${DAY_OF_MONTH}"
        echo "END: $(date)"
        echo "=================================================================="
    } >> "${RUNNER_LOG}"
    exit 0
fi

#-------------------------------------------------------------------------------
# 4. Pre-flight checks
#-------------------------------------------------------------------------------
if [ ! -x "${SAS_EXE}" ]; then
    echo "ERROR: SAS executable not found or not executable: ${SAS_EXE}" >> "${RUNNER_LOG}"
    exit 10
fi

if [ ! -f "${SAS_PROGRAM}" ]; then
    echo "ERROR: SAS wrapper not found: ${SAS_PROGRAM}" >> "${RUNNER_LOG}"
    exit 11
fi

#-------------------------------------------------------------------------------
# 5. Run SAS unattended
#-------------------------------------------------------------------------------
SAS_LAUNCH_LOG="${RUNNER_LOG_DIR}/Advocacy_First_Wednesday_SAS_${RUN_STAMP}.log"

{
    echo "STATUS: RUNNING"
    echo "SAS LAUNCH LOG: ${SAS_LAUNCH_LOG}"
} >> "${RUNNER_LOG}"

"${SAS_EXE}" \
    -sysin "${SAS_PROGRAM}" \
    -log "${SAS_LAUNCH_LOG}" \
    -noterminal

SAS_RC=$?

#-------------------------------------------------------------------------------
# 6. Record completion
#-------------------------------------------------------------------------------
{
    echo "SAS RETURN CODE: ${SAS_RC}"
    echo "END: $(date)"
    echo "=================================================================="
} >> "${RUNNER_LOG}"

exit "${SAS_RC}"
