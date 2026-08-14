USE WAREHOUSE MHA_WH;
USE DATABASE MHTEAM;
USE SCHEMA MHA;
USE ROLE MHA_TEAM_ROLE;


/*======================================================================
  MONTHLY BUDGET REPORT - MASTER PROCEDURE

  PURPOSE:
    Runs the complete Monthly Budget refresh in the required sequence.

  RUN ORDER:
    1. BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS
    2. BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS
    3. BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS
    4. BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES
    5. BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES
    6. BUDGET_MONTHLY_REWRITE_P6_LTM
    7. ROLL_FORWARD_LTM_PATCH_TABLE

  AUTOMATION BEHAVIOR:
    - P1 uses CURRENT_DATE(), so no manual monthly run-date change is needed.
    - Procedures are called one at a time in dependency order.
    - If any procedure fails, execution stops immediately.
    - The error is returned with the step number and procedure name.
    - A failure email is sent through MHA_EMAIL_NI to
      Tatyana.Kray@mass.gov.
    - If every step succeeds, the procedure returns one SUCCESS message.

  INTENDED SCHEDULE:
    After manual validation, this master procedure can be called by a
    Snowflake Task scheduled for the 15th of each month.

  IMPORTANT:
    This procedure does not recreate or modify the child procedures.
    It only orchestrates the existing production procedures.
======================================================================*/


CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_MASTER()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_start_ts       TIMESTAMP_LTZ := CURRENT_TIMESTAMP();
    v_end_ts         TIMESTAMP_LTZ;
    v_step           NUMBER := 0;
    v_step_name      STRING := '';
    v_result         STRING := '';
    v_message        STRING := '';
BEGIN

    /*------------------------------------------------------------------
      STEP 1
      Build source transaction feeds and establish the dynamic time config.
    ------------------------------------------------------------------*/
    v_step := 1;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS()
      INTO :v_result;

    v_message := 'Step 1 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 2
      Combine FFS and managed care feeds into the consolidated
      BUDGET_MONTHLY_TRANSACTIONS table.
    ------------------------------------------------------------------*/
    v_step := 2;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS()
      INTO :v_result;

    v_message := v_message ||
                 'Step 2 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 3
      Build eligibility/member-month denominators used by PMPM reporting.
    ------------------------------------------------------------------*/
    v_step := 3;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS()
      INTO :v_result;

    v_message := v_message ||
                 'Step 3 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 4
      Build provider category/group/type spending and utilization measures.
    ------------------------------------------------------------------*/
    v_step := 4;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES()
      INTO :v_result;

    v_message := v_message ||
                 'Step 4 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 5
      Build monthly and quarterly PMPM measures.
    ------------------------------------------------------------------*/
    v_step := 5;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES()
      INTO :v_result;

    v_message := v_message ||
                 'Step 5 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 6
      Build LTM, fiscal-year rollups, variance outputs, and snapshot history.
    ------------------------------------------------------------------*/
    v_step := 6;
    v_step_name := 'BUDGET_MONTHLY_REWRITE_P6_LTM';

    CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P6_LTM()
      INTO :v_result;

    v_message := v_message ||
                 'Step 6 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      STEP 7
      Roll the LTM comparison forward and refresh the Tableau patch table.
    ------------------------------------------------------------------*/
    v_step := 7;
    v_step_name := 'ROLL_FORWARD_LTM_PATCH_TABLE';

    CALL MHTEAM.MHA.ROLL_FORWARD_LTM_PATCH_TABLE()
      INTO :v_result;

    v_message := v_message ||
                 'Step 7 complete: ' || v_step_name || '. ' ||
                 COALESCE(v_result, 'No return message.') || '\n';


    /*------------------------------------------------------------------
      SUCCESS
    ------------------------------------------------------------------*/
    v_end_ts := CURRENT_TIMESTAMP();

    RETURN
        'SUCCESS: Monthly Budget master refresh completed.' || '\n' ||
        'Start: ' || TO_VARCHAR(v_start_ts) || '\n' ||
        'End: '   || TO_VARCHAR(v_end_ts) || '\n' ||
        'Elapsed seconds: ' ||
        TO_VARCHAR(DATEDIFF('second', v_start_ts, v_end_ts)) || '\n\n' ||
        v_message;


EXCEPTION
    WHEN OTHER THEN
        v_end_ts := CURRENT_TIMESTAMP();

        /*--------------------------------------------------------------
          FAILURE EMAIL NOTIFICATION

          Sends an email immediately when any child procedure fails.

          Notification integration:
            MHA_EMAIL_NI

          Recipient:
            Tatyana.Kray@mass.gov

          The email includes:
            - failed step number
            - failed procedure name
            - Snowflake error code/state/message
            - master start/end timestamps
            - elapsed time
            - successfully completed steps before the failure
        --------------------------------------------------------------*/
        CALL SYSTEM$SEND_EMAIL(
            'MHA_EMAIL_NI',
            'Tatyana.Kray@mass.gov',
            'Monthly Budget Automation FAILED',
            'FAILED: Monthly Budget master refresh stopped.' || '\n' ||
            'Failed step: ' || TO_VARCHAR(v_step) || '\n' ||
            'Procedure: ' || v_step_name || '\n' ||
            'Error code: ' || TO_VARCHAR(SQLCODE) || '\n' ||
            'SQL state: ' || SQLSTATE || '\n' ||
            'Error message: ' || SQLERRM || '\n' ||
            'Start: ' || TO_VARCHAR(v_start_ts) || '\n' ||
            'End: ' || TO_VARCHAR(v_end_ts) || '\n' ||
            'Elapsed seconds: ' ||
            TO_VARCHAR(DATEDIFF('second', v_start_ts, v_end_ts)) || '\n\n' ||
            'Completed steps before failure:' || '\n' ||
            v_message
        );

        RETURN
            'FAILED: Monthly Budget master refresh stopped.' || '\n' ||
            'Failure email sent to Tatyana.Kray@mass.gov.' || '\n' ||
            'Failed step: ' || TO_VARCHAR(v_step) || '\n' ||
            'Procedure: ' || v_step_name || '\n' ||
            'Error code: ' || TO_VARCHAR(SQLCODE) || '\n' ||
            'SQL state: ' || SQLSTATE || '\n' ||
            'Error message: ' || SQLERRM || '\n' ||
            'Start: ' || TO_VARCHAR(v_start_ts) || '\n' ||
            'End: ' || TO_VARCHAR(v_end_ts) || '\n' ||
            'Elapsed seconds: ' ||
            TO_VARCHAR(DATEDIFF('second', v_start_ts, v_end_ts)) || '\n\n' ||
            'Completed steps before failure:' || '\n' ||
            v_message;
END;
$$;


/*======================================================================
  MANUAL TEST

  Run this once after creating the master procedure.

  IMPORTANT:
    This executes the full production refresh chain.
======================================================================*/

CALL MHTEAM.MHA.BUDGET_MONTHLY_MASTER();
