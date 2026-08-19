#!/bin/bash
export LD_LIBRARY_PATH="/usr/lib64/snowflake:/usr/lib64/snowflake/odbc/lib:${LD_LIBRARY_PATH:-}"

# ACO Weekly Enrollment Report
# Runs up to 3 times if SAS fails or the log contains an ERROR.

MAX_ATTEMPTS=3
RETRY_WAIT_SECONDS=600

SAS_EXE="/sas/grid/94M7/SASHome/SASFoundation/9.4/sasexe/sas"
SAS_PROGRAM="/sas_mass_health/shared/pgm/ACOWeeklyReport/Monthly_View_Report_Automated_Production.sas"
LOG_DIR="/sas_mass_health/shared/tkray/Enrollment/Reports"

mkdir -p "$LOG_DIR"

for ATTEMPT in 1 2 3
do
    RUN_TS=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="${LOG_DIR}/ACO_Weekly_${RUN_TS}_attempt${ATTEMPT}.log"
    LST_FILE="${LOG_DIR}/ACO_Weekly_${RUN_TS}_attempt${ATTEMPT}.lst"

    echo "$(date): Starting ACO report attempt ${ATTEMPT} of ${MAX_ATTEMPTS}" \
        >> "${LOG_DIR}/ACO_Weekly_Master.log"

    "$SAS_EXE" \
        -nodms \
        -noterminal \
        -sysin "$SAS_PROGRAM" \
        -log "$LOG_FILE" \
        -print "$LST_FILE"

    SAS_RC=$?

    # Success requires:
    # 1. SAS exit code of zero
    # 2. No SAS ERROR lines in the log
    if [ "$SAS_RC" -eq 0 ] && ! grep -q "^ERROR:" "$LOG_FILE"
    then
        echo "$(date): Attempt ${ATTEMPT} completed successfully. Log: ${LOG_FILE}" \
            >> "${LOG_DIR}/ACO_Weekly_Master.log"

        exit 0
    fi

    echo "$(date): Attempt ${ATTEMPT} failed. SAS return code=${SAS_RC}. Log: ${LOG_FILE}" \
        >> "${LOG_DIR}/ACO_Weekly_Master.log"

    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]
    then
        echo "$(date): Waiting 10 minutes before retry." \
            >> "${LOG_DIR}/ACO_Weekly_Master.log"

        sleep "$RETRY_WAIT_SECONDS"
    fi
done

echo "$(date): All 3 ACO report attempts failed." \
    >> "${LOG_DIR}/ACO_Weekly_Master.log"

exit 1
