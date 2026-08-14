USE ROLE MHA_TEAM_ROLE;
USE WAREHOUSE MHA_WH;
USE DATABASE MHTEAM;
USE SCHEMA MHA;

-- ============================================================
-- Main full-history Caseload procedure
-- ============================================================

CREATE OR REPLACE PROCEDURE MHTEAM.MHA.CASELOAD_MONTHLY_DB3(
    "START_MONTH" DATE DEFAULT '2006-07-01',
    "END_MONTH" DATE DEFAULT CURRENT_DATE()
)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
function ymdUTC(d) {
    var year = d.getUTCFullYear();
    var month = String(d.getUTCMonth() + 1).padStart(2, '0');
    var day = String(d.getUTCDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

var months_inserted = 0;
var current_month_being_processed = null;

try {
    var asof_stmt = snowflake.execute({
        sqlText: `
            SELECT DATE_TRUNC('MONTH', CURRENT_DATE())::DATE
        `
    });

    asof_stmt.next();

    var as_of_dt = asof_stmt.getColumnValue(1);
    var asof_str = ymdUTC(as_of_dt);
    var asof_ts = `${asof_str} 00:00:00`;

    var start_stmt = snowflake.execute({
        sqlText: `
            SELECT DATE_TRUNC(
                'MONTH',
                TO_DATE(?, 'YYYY-MM-DD')
            )::DATE
        `,
        binds: [ymdUTC(START_MONTH)]
    });

    start_stmt.next();

    var begm = start_stmt.getColumnValue(1);
    var normalized_start_str = ymdUTC(begm);

    var true_end_stmt = snowflake.execute({
        sqlText: `
            SELECT LEAST(
                LAST_DAY(
                    DATEADD(
                        MONTH,
                        -1,
                        TO_DATE(?, 'YYYY-MM-DD')
                    )
                )::DATE,
                LAST_DAY(
                    TO_DATE(?, 'YYYY-MM-DD')
                )::DATE
            )
        `,
        binds: [
            asof_str,
            ymdUTC(END_MONTH)
        ]
    });

    true_end_stmt.next();

    var true_end = true_end_stmt.getColumnValue(1);
    var true_end_str = ymdUTC(true_end);

    if (begm > true_end) {
        throw new Error(
            `Invalid processing period. START_MONTH=${normalized_start_str}` +
            ` is later than TRUE_END=${true_end_str}.`
        );
    }

    snowflake.execute({
        sqlText: `
            CREATE OR REPLACE TABLE
            MHTEAM.MHA.CASELOAD_MEMBER_DAYS_TEMP
            (
                YR_MTH NUMBER,
                CDE_BUDGET_GROUP VARCHAR,
                MEM_DAYS NUMBER
            )
        `
    });

    while (begm <= true_end) {
        var begm_str = ymdUTC(begm);
        current_month_being_processed = begm_str;

        var endm_stmt = snowflake.execute({
            sqlText: `
                SELECT LAST_DAY(
                    TO_DATE(?, 'YYYY-MM-DD')
                )::DATE
            `,
            binds: [begm_str]
        });

        endm_stmt.next();

        var endm = endm_stmt.getColumnValue(1);

        if (endm > true_end) {
            endm = true_end;
        }

        var endm_str = ymdUTC(endm);

        var ym_stmt = snowflake.execute({
            sqlText: `
                SELECT TO_NUMBER(
                    TO_CHAR(
                        TO_DATE(?, 'YYYY-MM-DD'),
                        'YYYYMM'
                    )
                )
            `,
            binds: [begm_str]
        });

        ym_stmt.next();

        var yr_mth = ym_stmt.getColumnValue(1);

        var insert_sql = `
            INSERT INTO MHTEAM.MHA.CASELOAD_MEMBER_DAYS_TEMP
            (
                YR_MTH,
                CDE_BUDGET_GROUP,
                MEM_DAYS
            )
            SELECT
                ${yr_mth} AS YR_MTH,
                LPAD(
                    TRIM(
                        COALESCE(
                            se.CDE_BUDGET_GROUP,
                            '00'
                        )
                    ),
                    2,
                    '0'
                ) AS CDE_BUDGET_GROUP,
                SUM(
                    CASE
                        WHEN TO_DATE(se.DTE_EFFECTIVE)
                             < TO_DATE('${begm_str}')
                         AND TO_DATE(se.DTE_END)
                             > TO_DATE('${endm_str}')
                        THEN
                            DATEDIFF(
                                DAY,
                                TO_DATE('${begm_str}'),
                                TO_DATE('${endm_str}')
                            ) + 1

                        WHEN TO_DATE(se.DTE_EFFECTIVE)
                             < TO_DATE('${begm_str}')
                        THEN
                            DATEDIFF(
                                DAY,
                                TO_DATE('${begm_str}'),
                                TO_DATE(se.DTE_END)
                            ) + 1

                        WHEN TO_DATE(se.DTE_END)
                             > TO_DATE('${endm_str}')
                        THEN
                            DATEDIFF(
                                DAY,
                                TO_DATE(se.DTE_EFFECTIVE),
                                TO_DATE('${endm_str}')
                            ) + 1

                        ELSE
                            DATEDIFF(
                                DAY,
                                TO_DATE(se.DTE_EFFECTIVE),
                                TO_DATE(se.DTE_END)
                            ) + 1
                    END
                ) AS MEM_DAYS
            FROM MHDWPROD.NW.NW_STATE_ELIGIBILITY_HIST se
            WHERE TO_TIMESTAMP_NTZ('${asof_ts}') >= se.VALID_FROM_DT_TM
              AND TO_TIMESTAMP_NTZ('${asof_ts}') < se.VALID_THRU_DT_TM
              AND se.IND_ACTIVE = 'Y'
              AND TO_DATE(se.DTE_EFFECTIVE) <= TO_DATE('${endm_str}')
              AND TO_DATE(se.DTE_END) >= TO_DATE('${begm_str}')
            GROUP BY
                LPAD(
                    TRIM(
                        COALESCE(
                            se.CDE_BUDGET_GROUP,
                            '00'
                        )
                    ),
                    2,
                    '0'
                )
        `;

        snowflake.execute({
            sqlText: insert_sql
        });

        months_inserted++;

        var next_month_stmt = snowflake.execute({
            sqlText: `
                SELECT DATEADD(
                    MONTH,
                    1,
                    TO_DATE(?, 'YYYY-MM-DD')
                )::DATE
            `,
            binds: [begm_str]
        });

        next_month_stmt.next();
        begm = next_month_stmt.getColumnValue(1);
    }

    var temp_qc_stmt = snowflake.execute({
        sqlText: `
            SELECT
                COUNT(*) AS ROW_COUNT,
                COUNT(DISTINCT YR_MTH) AS MONTH_COUNT,
                MIN(YR_MTH) AS MIN_YR_MTH,
                MAX(YR_MTH) AS MAX_YR_MTH,
                COALESCE(SUM(MEM_DAYS), 0) AS TOTAL_MEM_DAYS
            FROM MHTEAM.MHA.CASELOAD_MEMBER_DAYS_TEMP
        `
    });

    temp_qc_stmt.next();

    var temp_row_count = temp_qc_stmt.getColumnValue(1);
    var temp_month_count = temp_qc_stmt.getColumnValue(2);
    var temp_min_yr_mth = temp_qc_stmt.getColumnValue(3);
    var temp_max_yr_mth = temp_qc_stmt.getColumnValue(4);
    var temp_total_mem_days = temp_qc_stmt.getColumnValue(5);

    if (temp_row_count === 0) {
        throw new Error(
            'QC FAILED: CASELOAD_MEMBER_DAYS_TEMP contains zero rows.'
        );
    }

    if (temp_month_count !== months_inserted) {
        throw new Error(
            `QC FAILED: Procedure processed ${months_inserted} months, ` +
            `but the working table contains ${temp_month_count} months.`
        );
    }

    if (Number(temp_total_mem_days) <= 0) {
        throw new Error(
            'QC FAILED: Total member-days is zero or negative.'
        );
    }

    snowflake.execute({
        sqlText: `
            CREATE OR REPLACE TABLE
            MHTEAM.MHA.CASELOAD_MEMBER_DAYS
            AS
            SELECT
                YR_MTH,
                CDE_BUDGET_GROUP,
                MEM_DAYS
            FROM MHTEAM.MHA.CASELOAD_MEMBER_DAYS_TEMP
        `
    });

    var final_qc_stmt = snowflake.execute({
        sqlText: `
            SELECT
                COUNT(*) AS ROW_COUNT,
                COUNT(DISTINCT YR_MTH) AS MONTH_COUNT,
                MIN(YR_MTH) AS MIN_YR_MTH,
                MAX(YR_MTH) AS MAX_YR_MTH,
                COALESCE(SUM(MEM_DAYS), 0) AS TOTAL_MEM_DAYS
            FROM MHTEAM.MHA.CASELOAD_MEMBER_DAYS
        `
    });

    final_qc_stmt.next();

    var final_row_count = final_qc_stmt.getColumnValue(1);
    var final_month_count = final_qc_stmt.getColumnValue(2);
    var final_min_yr_mth = final_qc_stmt.getColumnValue(3);
    var final_max_yr_mth = final_qc_stmt.getColumnValue(4);
    var final_total_mem_days = final_qc_stmt.getColumnValue(5);

    if (final_row_count !== temp_row_count) {
        throw new Error(
            `QC FAILED: Working table has ${temp_row_count} rows, ` +
            `but final table has ${final_row_count} rows.`
        );
    }

    if (final_month_count !== temp_month_count) {
        throw new Error(
            `QC FAILED: Working table has ${temp_month_count} months, ` +
            `but final table has ${final_month_count} months.`
        );
    }

    return (
        'SUCCESS: CASELOAD_MEMBER_DAYS rebuilt.' +
        ' | ASOFDT=' + asof_str +
        ' | START_MONTH=' + normalized_start_str +
        ' | END_DATE=' + true_end_str +
        ' | FIRST_YR_MTH=' + final_min_yr_mth +
        ' | LAST_YR_MTH=' + final_max_yr_mth +
        ' | MONTHS_PROCESSED=' + months_inserted +
        ' | MONTHS_IN_TABLE=' + final_month_count +
        ' | ROWS=' + final_row_count +
        ' | TOTAL_MEM_DAYS=' + final_total_mem_days
    );

} catch (err) {

    var error_message =
        'FAILED: CASELOAD_MONTHLY_DB3' +
        ' | CURRENT_MONTH=' +
        (current_month_being_processed === null
            ? 'NOT_STARTED'
            : current_month_being_processed) +
        ' | MONTHS_COMPLETED=' + months_inserted +
        ' | ERROR=' + err.message;

    throw new Error(error_message);
}
$$;


-- ============================================================
-- First-Tuesday scheduling wrapper
-- ============================================================

CREATE OR REPLACE PROCEDURE MHTEAM.MHA.CASELOAD_MONTHLY_SCHEDULED_RUN()
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
try {
    var date_stmt = snowflake.execute({
        sqlText: `
            SELECT
                CURRENT_DATE()::DATE AS RUN_DATE,
                DAYOFWEEKISO(CURRENT_DATE()) AS ISO_DAY_OF_WEEK,
                DAY(CURRENT_DATE()) AS DAY_OF_MONTH
        `
    });

    date_stmt.next();

    var run_date = date_stmt.getColumnValue(1);
    var iso_day_of_week = date_stmt.getColumnValue(2);
    var day_of_month = date_stmt.getColumnValue(3);

    if (iso_day_of_week == 2 && day_of_month >= 1 && day_of_month <= 7) {

        var call_stmt = snowflake.execute({
            sqlText: `
                CALL MHTEAM.MHA.CASELOAD_MONTHLY_DB3()
            `
        });

        call_stmt.next();

        var procedure_result = call_stmt.getColumnValue(1);

        return (
            'SUCCESS: First-Tuesday scheduled Caseload run completed.' +
            ' | RUN_DATE=' + run_date +
            ' | RESULT=' + procedure_result
        );

    } else {

        return (
            'SKIPPED: ' + run_date +
            ' is not the first Tuesday of the month.'
        );
    }

} catch (err) {

    throw new Error(
        'FAILED: CASELOAD_MONTHLY_SCHEDULED_RUN' +
        ' | ERROR=' + err.message
    );
}
$$;


-- ============================================================
-- Snowflake task
-- ============================================================

CREATE OR REPLACE TASK MHTEAM.MHA.CASELOAD_MONTHLY_REFRESH_TASK
    WAREHOUSE = MHA_WH
    SCHEDULE = 'USING CRON 0 10 * * TUE America/New_York'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    COMMENT = 'Rebuilds the full Monthly Caseload table on the first Tuesday of each month at 10:00 AM Eastern'
AS
    CALL MHTEAM.MHA.CASELOAD_MONTHLY_SCHEDULED_RUN();

ALTER TASK MHTEAM.MHA.CASELOAD_MONTHLY_REFRESH_TASK RESUME;

SHOW TASKS LIKE 'CASELOAD_MONTHLY_REFRESH_TASK'
IN SCHEMA MHTEAM.MHA;
