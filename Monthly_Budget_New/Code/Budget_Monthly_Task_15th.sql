USE WAREHOUSE MHA_WH;
USE DATABASE MHTEAM;
USE SCHEMA MHA;
USE ROLE MHA_TEAM_ROLE;


/*======================================================================
  MONTHLY BUDGET REPORT - SNOWFLAKE TASK

  PURPOSE:
    Automatically runs the Monthly Budget master procedure once per month.

  SCHEDULE:
    - Runs on the 15th day of every month
    - Runs at 9:00 AM Eastern Time
    - Time zone: America/New_York
    - Snowflake automatically handles Eastern Standard / Daylight Time
      because the named time zone is used in the CRON schedule.

  PROCESS CALLED:
    MHTEAM.MHA.BUDGET_MONTHLY_MASTER()

  MASTER PROCEDURE RUN ORDER:
    1. P1_BUILD_TRANSACTIONS
    2. P2_COMBINE_FEEDS
    3. P3_BUILD_MEM_MONTHS
    4. P4_AGGREGATE_MEASURES
    5. P5_PMPM_MEASURES
    6. P6_LTM
    7. ROLL_FORWARD_LTM_PATCH_TABLE

  IMPORTANT:
    CREATE OR REPLACE TASK creates/replaces the task.
    The task is then RESUMED at the end of this script so the schedule
    becomes active.

  CURRENT AUTOMATION DESIGN:
    The child procedures are not scheduled separately.
    Only this task is scheduled, and it calls the single master procedure.
======================================================================*/


/*----------------------------------------------------------------------
  1. CREATE THE MONTHLY TASK

  CRON FORMAT:
      minute hour day-of-month month day-of-week time-zone

      0 9 15 * * America/New_York

      = 9:00 AM on the 15th of every month, Eastern Time.
----------------------------------------------------------------------*/

CREATE OR REPLACE TASK MHTEAM.MHA.BUDGET_MONTHLY_MASTER_TASK
    WAREHOUSE = MHA_WH
    SCHEDULE = 'USING CRON 0 9 15 * * America/New_York'
    USER_TASK_TIMEOUT_MS = 7200000
    COMMENT = 'Runs the full Monthly Budget refresh on the 15th of each month at 9:00 AM Eastern Time.'
AS
    CALL MHTEAM.MHA.BUDGET_MONTHLY_MASTER();


/*----------------------------------------------------------------------
  2. ACTIVATE THE TASK

  New/replaced Snowflake tasks are suspended until resumed.
  This command activates the monthly schedule.
----------------------------------------------------------------------*/

ALTER TASK MHTEAM.MHA.BUDGET_MONTHLY_MASTER_TASK RESUME;


/*----------------------------------------------------------------------
  3. VERIFY TASK STATUS AND SCHEDULE

  Run SHOW TASKS after creation to confirm:
    - state = started
    - schedule = USING CRON 0 9 15 * * America/New_York
----------------------------------------------------------------------*/

SHOW TASKS LIKE 'BUDGET_MONTHLY_MASTER_TASK'
IN SCHEMA MHTEAM.MHA;


/*----------------------------------------------------------------------
  OPTIONAL MANUAL TEST

  DO NOT run this unless you intentionally want to execute the complete
  Monthly Budget refresh immediately.

  EXECUTE TASK MHTEAM.MHA.BUDGET_MONTHLY_MASTER_TASK;
----------------------------------------------------------------------*/


/*----------------------------------------------------------------------
  OPTIONAL: VIEW RECENT / UPCOMING TASK HISTORY

  Snowflake TASK_HISTORY can be used after the task is created to review
  execution status and scheduled runs.

  SELECT *
  FROM TABLE(
      INFORMATION_SCHEMA.TASK_HISTORY(
          TASK_NAME => 'BUDGET_MONTHLY_MASTER_TASK',
          RESULT_LIMIT => 20
      )
  )
  ORDER BY SCHEDULED_TIME DESC;
----------------------------------------------------------------------*/


/*----------------------------------------------------------------------
  OPTIONAL: SUSPEND THE AUTOMATION

  Use only if the monthly automatic run must be temporarily stopped.

  ALTER TASK MHTEAM.MHA.BUDGET_MONTHLY_MASTER_TASK SUSPEND;
----------------------------------------------------------------------*/
