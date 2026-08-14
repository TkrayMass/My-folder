USE ROLE MHA_TEAM_ROLE;
USE WAREHOUSE MHA_WH;
USE DATABASE MHTEAM;
USE SCHEMA MHA;

-- ============================================================
-- Main monthly Snapshot procedure
-- ============================================================

CREATE OR REPLACE PROCEDURE MHTEAM.MHA.SNAPSHOT_MONTHLY_DYNAMIC()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
var transactionStarted = false;
var resultMessage = '';

try {
    /* Determine reporting dates and dynamic monthly table name */
    var dateStmt = snowflake.createStatement({
        sqlText: `
            SELECT
                TO_CHAR(
                    LAST_DAY(DATEADD(MONTH, -1, CURRENT_DATE())),
                    'YYYY-MM-DD'
                ) AS SNAPDT_STR,
                TO_CHAR(
                    DATE_TRUNC('MONTH', CURRENT_DATE()),
                    'YYYY-MM-DD'
                ) AS EXTRDT_STR,
                TO_NUMBER(
                    TO_CHAR(
                        LAST_DAY(DATEADD(MONTH, -1, CURRENT_DATE())),
                        'YYYYMM'
                    )
                ) AS YR_MTH,
                'SNAPSHOT_ELIGENR_' ||
                TO_CHAR(
                    LAST_DAY(DATEADD(MONTH, -1, CURRENT_DATE())),
                    'YYYYMMDD'
                ) ||
                '_DISAB_FIX' AS TABLE_NAME
        `
    });

    var dateResult = dateStmt.execute();

    if (!dateResult.next()) {
        throw new Error('Unable to determine monthly snapshot dates.');
    }

    var snapDtStr = dateResult.getColumnValue('SNAPDT_STR');
    var extrDtStr = dateResult.getColumnValue('EXTRDT_STR');
    var yrMth = dateResult.getColumnValue('YR_MTH');
    var tableName = dateResult.getColumnValue('TABLE_NAME');
    var fullTableName = 'MHTEAM.MHA.' + tableName;

    /* Create monthly eligibility Snapshot */
    var createStmt = snowflake.createStatement({
        sqlText: `
            CREATE OR REPLACE TABLE ${fullTableName} AS
            SELECT
                ?::NUMBER AS YR_MTH,
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
                COUNT(DISTINCT se.ID_MEDICAID) AS MEMBERS
            FROM MHDWPROD.NW.NW_STATE_ELIGIBILITY_HIST se
            WHERE TO_TIMESTAMP_NTZ(?::VARCHAR) >= se.VALID_FROM_DT_TM
              AND TO_TIMESTAMP_NTZ(?::VARCHAR) < se.VALID_THRU_DT_TM
              AND se.IND_ACTIVE = 'Y'
              AND TO_DATE(?::VARCHAR)
                  BETWEEN TO_DATE(se.DTE_EFFECTIVE)
                      AND TO_DATE(se.DTE_END)
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
        `,
        binds: [
            yrMth,
            extrDtStr,
            extrDtStr,
            snapDtStr
        ]
    });

    createStmt.execute();

    /* QC monthly Snapshot */
    var qcStmt = snowflake.createStatement({
        sqlText: `
            SELECT
                MIN(YR_MTH) AS QC_YR_MTH,
                COUNT(*) AS ROWS_LOADED,
                COALESCE(SUM(MEMBERS), 0) AS TOTAL_MEMBERS,
                COALESCE(
                    SUM(
                        CASE
                            WHEN CDE_BUDGET_GROUP NOT IN ('44', '87', '99')
                            THEN MEMBERS
                            ELSE 0
                        END
                    ),
                    0
                ) AS TOTAL_EXCL_44_87_99
            FROM ${fullTableName}
        `
    });

    var qcResult = qcStmt.execute();

    if (!qcResult.next()) {
        throw new Error('Snapshot was created, but QC returned no results.');
    }

    var qcYrMth = qcResult.getColumnValue('QC_YR_MTH');
    var rowsLoaded = qcResult.getColumnValue('ROWS_LOADED');
    var totalMembers = qcResult.getColumnValue('TOTAL_MEMBERS');
    var totalExcluding = qcResult.getColumnValue('TOTAL_EXCL_44_87_99');

    if (Number(rowsLoaded) === 0 || Number(totalMembers) === 0) {
        throw new Error('Snapshot table is empty: ' + fullTableName);
    }

    if (Number(qcYrMth) !== Number(yrMth)) {
        throw new Error(
            'Monthly-table QC month does not match expected month. ' +
            'Expected=' + yrMth +
            ', Found=' + qcYrMth
        );
    }

    /* Update history transactionally */
    snowflake.createStatement({
        sqlText: `BEGIN TRANSACTION`
    }).execute();

    transactionStarted = true;

    var deleteHistoryStmt = snowflake.createStatement({
        sqlText: `
            DELETE
            FROM MHTEAM.MHA.SNAPSHOT_ELIGENR_HISTORY
            WHERE YR_MTH = ?::NUMBER
        `,
        binds: [yrMth]
    });

    deleteHistoryStmt.execute();

    var insertHistoryStmt = snowflake.createStatement({
        sqlText: `
            INSERT INTO MHTEAM.MHA.SNAPSHOT_ELIGENR_HISTORY
            (
                YR_MTH,
                CDE_BUDGET_GROUP,
                MEMBERS
            )
            SELECT
                YR_MTH,
                CDE_BUDGET_GROUP,
                MEMBERS
            FROM ${fullTableName}
        `
    });

    insertHistoryStmt.execute();

    /* Validate current month in history */
    var historyQcStmt = snowflake.createStatement({
        sqlText: `
            SELECT
                COUNT(*) AS HISTORY_ROWS,
                COALESCE(SUM(MEMBERS), 0) AS HISTORY_TOTAL
            FROM MHTEAM.MHA.SNAPSHOT_ELIGENR_HISTORY
            WHERE YR_MTH = ?::NUMBER
        `,
        binds: [yrMth]
    });

    var historyQcResult = historyQcStmt.execute();

    if (!historyQcResult.next()) {
        throw new Error(
            'Historical-table QC returned no results for YR_MTH=' + yrMth
        );
    }

    var historyRows = historyQcResult.getColumnValue('HISTORY_ROWS');
    var historyTotal = historyQcResult.getColumnValue('HISTORY_TOTAL');

    if (
        Number(historyRows) !== Number(rowsLoaded) ||
        Number(historyTotal) !== Number(totalMembers)
    ) {
        throw new Error(
            'Historical-table QC failed. ' +
            'YR_MTH=' + yrMth +
            ', Monthly rows=' + rowsLoaded +
            ', History rows=' + historyRows +
            ', Monthly total=' + totalMembers +
            ', History total=' + historyTotal
        );
    }

    snowflake.createStatement({
        sqlText: `COMMIT`
    }).execute();

    transactionStarted = false;

    resultMessage =
        'Snapshot completed successfully. ' +
        'Table=' + fullTableName +
        ', SNAPDT=' + snapDtStr +
        ', EXTRDT=' + extrDtStr +
        ', YR_MTH=' + yrMth +
        ', Rows=' + rowsLoaded +
        ', Total=' + totalMembers +
        ', Total excluding 44/87/99=' + totalExcluding +
        ', History rows=' + historyRows +
        ', History total=' + historyTotal +
        ', Historical table updated successfully.';

} catch (err) {

    if (transactionStarted) {
        try {
            snowflake.createStatement({
                sqlText: `ROLLBACK`
            }).execute();
        } catch (rollbackErr) {
            throw new Error(
                'Original error: ' + err.message +
                ' | Rollback error: ' + rollbackErr.message
            );
        }
    }

    throw new Error(
        'SNAPSHOT_MONTHLY_DYNAMIC failed. ' +
        'Code=' + err.code +
        ', State=' + err.state +
        ', Message=' + err.message +
        ', Stack=' + err.stackTraceTxt
    );
}

return resultMessage;
$$;


-- ============================================================
-- First-Tuesday scheduling wrapper
-- ============================================================

CREATE OR REPLACE PROCEDURE MHTEAM.MHA.SNAPSHOT_MONTHLY_FIRST_TUESDAY()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
var resultMessage = '';

try {
    var checkStmt = snowflake.createStatement({
        sqlText: `
            SELECT
                TO_CHAR(CURRENT_DATE(), 'YYYY-MM-DD') AS RUN_DATE,
                DAYOFWEEKISO(CURRENT_DATE()) AS ISO_DAY_OF_WEEK,
                DAY(CURRENT_DATE()) AS DAY_OF_MONTH,
                IFF(
                    DAYOFWEEKISO(CURRENT_DATE()) = 2
                    AND DAY(CURRENT_DATE()) BETWEEN 1 AND 7,
                    'Y',
                    'N'
                ) AS FIRST_TUESDAY_FLAG
        `
    });

    var checkResult = checkStmt.execute();

    if (!checkResult.next()) {
        throw new Error(
            'Unable to determine whether today is the first Tuesday.'
        );
    }

    var runDate = checkResult.getColumnValue('RUN_DATE');
    var dayOfWeek = checkResult.getColumnValue('ISO_DAY_OF_WEEK');
    var dayOfMonth = checkResult.getColumnValue('DAY_OF_MONTH');
    var firstTuesdayFlag = checkResult.getColumnValue('FIRST_TUESDAY_FLAG');

    if (firstTuesdayFlag !== 'Y') {
        resultMessage =
            'SKIPPED. Run date=' + runDate +
            ', ISO weekday=' + dayOfWeek +
            ', day of month=' + dayOfMonth +
            '. This is not the first Tuesday.';
    } else {
        var runStmt = snowflake.createStatement({
            sqlText: `
                CALL MHTEAM.MHA.SNAPSHOT_MONTHLY_DYNAMIC()
            `
        });

        var runResult = runStmt.execute();

        if (!runResult.next()) {
            throw new Error(
                'SNAPSHOT_MONTHLY_DYNAMIC completed without a result.'
            );
        }

        var procedureResult = runResult.getColumnValue(1);

        if (procedureResult === null || procedureResult === undefined) {
            throw new Error(
                'SNAPSHOT_MONTHLY_DYNAMIC returned NULL.'
            );
        }

        resultMessage =
            'FIRST TUESDAY AUTOMATION COMPLETED. ' +
            'Run date=' + runDate + '. ' +
            procedureResult;
    }

} catch (err) {
    throw new Error(
        'SNAPSHOT_MONTHLY_FIRST_TUESDAY failed. ' +
        'Code=' + err.code +
        ', State=' + err.state +
        ', Message=' + err.message +
        ', Stack=' + err.stackTraceTxt
    );
}

return resultMessage;
$$;


-- ============================================================
-- Snowflake task
-- ============================================================

CREATE OR REPLACE TASK MHTEAM.MHA.SNAPSHOT_MONTHLY_TASK
    WAREHOUSE = MHA_WH
    SCHEDULE = 'USING CRON 0 6 * * TUE America/New_York'
AS
    CALL MHTEAM.MHA.SNAPSHOT_MONTHLY_FIRST_TUESDAY();

ALTER TASK MHTEAM.MHA.SNAPSHOT_MONTHLY_TASK RESUME;

SHOW TASKS LIKE 'SNAPSHOT_MONTHLY_TASK'
IN SCHEMA MHTEAM.MHA;
