/* FORMAT-ONLY TEST: reuses existing REBUILD source tables; no source refresh. */
/* NATIVE XLSX ISOLATED CANDIDATE. No production scheduling/publication/email.
   Uses existing ACOENR_REBUILD test objects; do not run alongside another REBUILD job.
   Separate ACO_REBUILD_XLSX output root. Full runtime and format validation pending.
*/
/* ISOLATED UPGRADE BASELINE. Use a separate SAS session.
   Install ACO_REBUILD_Refresh.sql first. Production schedules remain unchanged.
   ExcelXP XLS output is preserved for comparison; XLSX migration is next.
*/
/* Candidate only: run in a separate SAS session. No automatic email. */
%global U_RUN_ID U_RUN_DIR;
%let U_RUN_ID=%superq(sysparm);
%macro U_SET_RUN_ID;
 %if %length(%superq(U_RUN_ID))=0 %then
  %let U_RUN_ID=%sysfunc(compress(%sysfunc(datetime(),hex16.)))_&sysjobid.;
 %if %sysfunc(prxmatch(%str(/^[A-Za-z0-9_]{1,80}$/),%superq(U_RUN_ID))) ne 1 %then %do;
  %put ERROR: Invalid candidate run ID.; %abort cancel;
 %end;
%mend;
%U_SET_RUN_ID;
%let U_RUN_DIR=/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/&U_RUN_ID.;
data _null_;
    length base child $1024;
    base='/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX';
    if not fileexist(base) then child=dcreate('ACO_REBUILD_XLSX','/sas_mass_health/shared/output/ACOWeeklyReport');
    if not fileexist(base) then do; put 'ERROR: Cannot create candidate base directory.'; abort cancel; end;
    child=dcreate(symget('U_RUN_ID'),base);
    if missing(child) then do; put 'ERROR: Cannot create a new attempt directory.'; abort cancel; end;
run;


/******************************************************************************************
 ACO Weekly Enrollment Report - UPGRADE ISOLATION BASELINE - CALCULATIONS PRESERVED

 Purpose:
   - Preserves the validated manual report calculations.
   - Retains the working v3 Snowflake table-creation method:
       CREATE OR REPLACE TABLE through Snowflake pass-through.
   - Reads dynamic run dates from Snowflake.
   - Calls ACOENR_REBUILD_WEEKLY_REFRESH().
   - Validates ACOENR_REBUILD_02_ENRDIS.
   - Rebuilds ACOENR_00 through ACOENR_06.
   - Produces the required Excel worksheets.
   - Restores validated TOTAL-category weekly QC with QC_Summary, QC_Matrix, and QC_Detail.
   - Adds QC history comparison and QC workbook without changing report calculations.
   - QC email includes QC issues and the completed QC workbook.
   - Current-MTD movement can generate WARNING but cannot by itself force overall FAIL.
   - Overall FAIL is reserved for blocking RED/NEW/MISSING rows outside CURRENT_MTD.
   - Adds an operational Distribution Decision:
       READY TO DISTRIBUTE
       REVIEW BEFORE DISTRIBUTION
       DO NOT DISTRIBUTE
   - Separates blocking failures, review warnings, and informational MTD flags.
   - Uses a 500-member blocking threshold for older CASELOAD revisions.

 Important:
   - Tables ACOENR_03 through ACOENR_06 are created with Snowflake
     CREATE OR REPLACE TABLE. Do not convert these statements back to
     SAS LIBNAME CREATE TABLE statements.
******************************************************************************************/

ods _all_ close; /* Close all open ODS destinations */
/* filename _HTMLOUT clear; */
/* filename _RTFOUT clear; */

options notes source mprint mlogic symbolgen;

/* Local SAS library used by report work tables */
libname data "%sysfunc(pathname(work))"; /* Upgrade tables are session-local. */

/* Snowflake connection */
options nosymbolgen nomprint nosource;

/* Load Snowflake credentials */
%include "/sas_mass_health/shared/tkray/private/snowflake_credentials.sas";

options source;

libname upgsnow snow
    datasrc=MHDWPROD
    database=MHDWPROD
    schema=MHA
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="
        AUTHENTICATOR=SNOWFLAKE_JWT;
        ROLE=MHA_TEAM_ROLE;
        WAREHOUSE=MHA_WH;
        PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
        PRIV_KEY_FILE_PWD=&SF_KEY_PWD."
;
/* Valid macro wrapper for step-level SQL error handling */
%macro U_stop_if_sql_error(step=);
    %if &sqlrc ne 0 %then %do;
        %put ERROR: &step failed. Program stopped.;
        %abort cancel;
    %end;
%mend U_stop_if_sql_error;

/******************************************************************************************
 STEP 1 - DYNAMIC RUN DATES FROM SNOWFLAKE

 Note:
   Snowflake owns the business run dates. SAS reads equivalent values from Snowflake
   and uses them only for snapshot filters, filenames, report titles, and display labels.
******************************************************************************************/

proc sql noprint;
    connect using upgsnow;

    select startdate_char,
           lastweek_char,
           enddate_char,
           today_char,
           wh_thru_dt_char,
           running_dt_char,
           repdt_char
      into :StartDate_char trimmed,
           :lastweek_char trimmed,
           :EndDate_char trimmed,
           :today_char trimmed,
           :wh_thru_dt_char trimmed,
           :Running_DT_char trimmed,
           :repdt trimmed
      from connection to upgsnow
      (
        select to_char(to_date('2023-03-01'), 'YYYY-MM-DD') as startdate_char,
               to_char(dateadd(day,-7,current_date()), 'YYYY-MM-DD') as lastweek_char,
               to_char(current_date(), 'YYYY-MM-DD') as enddate_char,
               to_char(current_date(), 'YYYY-MM-DD') as today_char,
               to_char(current_date(), 'YYYY-MM-DD') as wh_thru_dt_char,
               to_char(current_date(), 'YYYY-MM-DD') as running_dt_char,
               to_char(current_date(), 'YYYYMMDD') as repdt_char
      );

    disconnect from upgsnow;
quit;

%let StartDate  = %str(%')&StartDate_char.%str(%');
%let lastweek   = %str(%')&lastweek_char.%str(%');
%let EndDate    = %str(%')&EndDate_char.%str(%');
%let today      = %str(%')&today_char.%str(%');
%let wh_thru_dt = %str(%')&wh_thru_dt_char.%str(%');
%let Running_DT = %str(%')&Running_DT_char.%str(%');

/* The active ExcelXP output filename is configured below. */

/* QC workbook and email configuration */
%let OUTFILE=&U_RUN_DIR./ReportTestMonthly-&repdt._REBUILD_REGXSA.xlsx;
%let QC_EMAIL_TO=Tatyana.Kray@mass.gov;
%let QC_EMAIL_CC=;

%put NOTE: ===== ACO WEEKLY REPORT v2.0 DYNAMIC DATES =====;
%put NOTE: &=StartDate;
%put NOTE: &=lastweek;
%put NOTE: &=EndDate;
%put NOTE: &=today;
%put NOTE: &=wh_thru_dt;
%put NOTE: &=Running_DT;
%put NOTE: &=repdt;
%put NOTE: &=OUTFILE;
%put NOTE: ==================================================;

/*WORKS*/
/************** 11 ***************/
/**Create a snapshot and enrollment agg tables to flow into the report********************************/
/***recast region/svc area variables to work for now**************************************************/

/* IMPORTANT:
   Build the permanent SAS report datasets using the same LIBNAME method as the
   trusted manual report. The prior pass-through extraction changed the numeric
   representation of MBRS in SAS and caused the false 112,020,077 validation total.
   The Snowflake table itself was correct at 1,120,077. */

proc sql;
    create table data.myEnrAgg2 as
    select a.*,
           a.DSC_MC_REGION_CAP as MCO_REGION,
           a.dsc_mc_region_enroll as SERVICE_AREA
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC a
    where type ne 'snapshot';
quit;

%U_stop_if_sql_error(step=Create current-run DATA.MYENRAGG2);

proc sql;
    create table data.myCaseload2 as
    select a.*,
           a.DSC_MC_REGION_CAP as MCO_REGION,
           a.dsc_mc_region_enroll as SERVICE_AREA
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC a
    where type = 'snapshot';
quit;

%U_stop_if_sql_error(step=Create current-run DATA.MYCASELOAD2);

proc sql;
    create table data.code_xwalk as
    select *
    from upgsnow.XWALK_ACOENRRPT_ENRDIS;
quit;

%U_stop_if_sql_error(step=Create DATA.CODE_XWALK);

/* Verify that the local SAS report datasets were rebuilt in this run. */
proc sql noprint;
    select count(*) into :LOCAL_CASELOAD_ROWS trimmed
    from data.myCaseload2;

    select count(*) into :LOCAL_ENR_ROWS trimmed
    from data.myEnrAgg2;
quit;

%macro U_stop_if_local_tables_empty;
    %if %length(%superq(LOCAL_CASELOAD_ROWS)) = 0 or
        %length(%superq(LOCAL_ENR_ROWS)) = 0 %then %do;
        %put ERROR: Local report table row counts were not populated.;
        %abort cancel;
    %end;

    %if %sysevalf(&LOCAL_CASELOAD_ROWS <= 0) %then %do;
        %put ERROR: DATA.MYCASELOAD2 has zero rows. Program stopped.;
        %abort cancel;
    %end;

    %if %sysevalf(&LOCAL_ENR_ROWS <= 0) %then %do;
        %put ERROR: DATA.MYENRAGG2 has zero rows. Program stopped.;
        %abort cancel;
    %end;
%mend U_stop_if_local_tables_empty;

%U_stop_if_local_tables_empty;

%put NOTE: CURRENT-RUN LOCAL TABLES: MYCASELOAD2=&LOCAL_CASELOAD_ROWS rows;
%put NOTE: CURRENT-RUN LOCAL TABLES: MYENRAGG2=&LOCAL_ENR_ROWS rows;

/*CHECK NUMBERS  1,258,071*/
proc sql;
    connect using upgsnow;

    create table data.myCaseload2A as
    select *
    from connection to upgsnow
    (
        select sum(MBRS) / 2 as adjusted_mb_count
        from MHDWPROD.MHA.ACOENR_REBUILD_01_SNAPSHOT
        where type = 'snapshot'
          and FIRSTDTWEEK = 20240601
    );

    disconnect from upgsnow;
quit;


/******************************************************************************************
 STEP 4A - FRESHNESS / CURRENT-MONTH VALIDATION BEFORE QC AND EXCEL

 This check proves that:
   - ACOENR_REBUILD_01_SNAPSHOT was rebuilt;
   - ACOENR_REBUILD_06_REP_W_PERC contains the current report month;
   - DATA.MYCASELOAD2 contains the same current-month rows;
   - the report will not continue on a stale prior-week SAS dataset.
******************************************************************************************/

proc sql noprint;
    connect using upgsnow;

    create table data.current_run_validation as
    select *
    from connection to upgsnow
    (
        with current_month as
        (
            select to_number(to_char(date_trunc('month', current_date()), 'YYYYMMDD')) as month_id
        )
        select
            c.month_id,
            count(*) as current_month_rows,
            round(sum(case when r.membertype='All' then r.mbrs else 0 end),0) as current_month_total,
            min(r.Running_DT) as min_running_dt,
            max(r.Running_DT) as max_running_dt
        from current_month c
        left join MHDWPROD.MHA.ACOENR_REBUILD_06_REP_W_PERC r
          on r.firstdtweek=c.month_id
         and r.type='snapshot'
         and r.provtype2 not in ('ZZ - ACOB PCCB')
        group by c.month_id
    );

    disconnect from upgsnow;
quit;

%U_stop_if_sql_error(step=Current-month Snowflake validation);

proc sql;
    create table data.local_current_validation as
    select
        v.month_id,
        count(c.firstdtweek) as local_current_month_rows,
        round(sum(case when c.membertype='All' then c.mbrs else 0 end),1)
            as local_current_month_total
    from data.current_run_validation v
    left join data.myCaseload2 c
      on c.firstdtweek=v.month_id
     and c.provtype2 not in ('ZZ - ACOB PCCB')
    group by v.month_id;
quit;

%U_stop_if_sql_error(step=Local current-month validation);

/* Create one validation result row without performing arithmetic in macro logic.
   This prevents blank or character macro values from causing %EVAL/%SYSEVALF errors. */
proc sql;
    create table data.current_run_validation_final as
    select
        s.month_id,
        coalesce(s.current_month_rows,0) as current_month_rows,
        s.current_month_total,
        s.min_running_dt,
        s.max_running_dt,
        coalesce(l.local_current_month_rows,0) as local_current_month_rows,
        l.local_current_month_total,
        (s.current_month_total-l.local_current_month_total) as total_difference,
        case
            when coalesce(s.current_month_rows,0) <= 0 then 'NO_SNOWFLAKE_ROWS'
            when coalesce(l.local_current_month_rows,0) <= 0 then 'NO_LOCAL_ROWS'
            when missing(s.current_month_total) then 'NO_SNOWFLAKE_TOTAL'
            when missing(l.local_current_month_total) then 'NO_LOCAL_TOTAL'
            when abs(round(s.current_month_total,1)-round(l.local_current_month_total,1)) >= 1 then 'TOTAL_MISMATCH'
            else 'PASS'
        end as validation_status length=30
    from data.current_run_validation s
    left join data.local_current_validation l
      on s.month_id=l.month_id;
quit;

%U_stop_if_sql_error(step=Final freshness validation);

proc sql noprint;
    select month_id,
           current_month_rows,
           current_month_total,
           min_running_dt,
           max_running_dt,
           local_current_month_rows,
           local_current_month_total,
           total_difference,
           validation_status
      into :VALID_MONTH_ID trimmed,
           :VALID_MONTH_ROWS trimmed,
           :VALID_MONTH_TOTAL trimmed,
           :VALID_MIN_RUNNING_DT trimmed,
           :VALID_MAX_RUNNING_DT trimmed,
           :LOCAL_CURRENT_MONTH_ROWS trimmed,
           :LOCAL_CURRENT_MONTH_TOTAL trimmed,
           :VALID_TOTAL_DIFFERENCE trimmed,
           :VALIDATION_STATUS trimmed
    from data.current_run_validation_final;
quit;

%macro U_stop_if_stale_or_missing;
    %if %superq(VALIDATION_STATUS) ne PASS %then %do;
        %put ERROR: Current-run freshness validation failed.;
        %put ERROR: VALIDATION_STATUS=%superq(VALIDATION_STATUS);;
        %put ERROR: MONTH=%superq(VALID_MONTH_ID);;
        %put ERROR: SNOWFLAKE_ROWS=%superq(VALID_MONTH_ROWS);;
        %put ERROR: SNOWFLAKE_TOTAL=%superq(VALID_MONTH_TOTAL);;
        %put ERROR: LOCAL_ROWS=%superq(LOCAL_CURRENT_MONTH_ROWS);;
        %put ERROR: LOCAL_TOTAL=%superq(LOCAL_CURRENT_MONTH_TOTAL);;
        %put ERROR: TOTAL_DIFFERENCE=%superq(VALID_TOTAL_DIFFERENCE);;
        %abort cancel;
    %end;
%mend U_stop_if_stale_or_missing;

%U_stop_if_stale_or_missing;

%put NOTE: ===============================================================;
%put NOTE: FRESHNESS CHECK PASSED.;
%put NOTE: CURRENT MONTH=&VALID_MONTH_ID.;
%put NOTE: CURRENT MONTH ROWS IN SNOWFLAKE=&VALID_MONTH_ROWS.;
%put NOTE: CURRENT MONTH TOTAL IN SNOWFLAKE=&VALID_MONTH_TOTAL.;
%put NOTE: CURRENT MONTH ROWS IN LOCAL SAS=&LOCAL_CURRENT_MONTH_ROWS.;
%put NOTE: CURRENT MONTH TOTAL IN LOCAL SAS=&LOCAL_CURRENT_MONTH_TOTAL.;
%put NOTE: SNOWFLAKE-LOCAL TOTAL DIFFERENCE=&VALID_TOTAL_DIFFERENCE.;
%put NOTE: RUNNING_DT RANGE=&VALID_MIN_RUNNING_DT to &VALID_MAX_RUNNING_DT.;
%put NOTE: ===============================================================;

/* Print plan totals to the SAS output/log for direct comparison with manual. */
proc sql;
    title "PRE-EXPORT CURRENT-MONTH PLAN TOTALS - &VALID_MONTH_ID";
    select provtype2,
           round(sum(mbrs),1) as members format=comma18.1
    from data.myCaseload2
    where type='snapshot'
      and membertype='All'
      and firstdtweek=&VALID_MONTH_ID
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by provtype2
    order by provtype2;
    title;
quit;


/******************************************************************************************
 STEP 5 - QC WORKBOOK, HISTORY, AND EMAIL

 This QC block:
   - Uses the most recent Snowflake history RUN_DT before today's run.
   - Does not place QC_PRIOR_RUN_DT_CHAR inside Snowflake SQL.
   - Safely handles an empty QC history table.
   - Replaces today's history rows during same-day reruns.
   - Does not modify the working report tables or calculations.
******************************************************************************************/

%macro U_SEND_ACO_QC_EMAIL;

    %global QC_EMAIL_TO QC_EMAIL_CC;
    %local QC_EMAIL_SUBJECT;

    %if not %symexist(QC_TOTAL_ROWS) %then %let QC_TOTAL_ROWS=0;
    %if not %symexist(QC_OK_COUNT) %then %let QC_OK_COUNT=0;

    /* Default recipient values so the email macro also works when run by itself. */
    %if not %symexist(QC_EMAIL_TO) %then
        %let QC_EMAIL_TO=Tatyana.Kray@mass.gov;
    %else %if %length(%superq(QC_EMAIL_TO)) = 0 %then
        %let QC_EMAIL_TO=Tatyana.Kray@mass.gov;

    %if not %symexist(QC_EMAIL_CC) %then
        %let QC_EMAIL_CC=;

    %put NOTE: ===============================================;
    %put NOTE: STARTING QC EMAIL SECTION;
    %put NOTE: QC_EMAIL_TO=&QC_EMAIL_TO.;
    %put NOTE: QCFILE=&QCFILE.;
    %put NOTE: QC_STATUS=&QC_STATUS.;
    %put NOTE: ===============================================;

    /* Do not attempt an attachment email when the workbook was not created. */
    %if not %sysfunc(fileexist(%superq(QCFILE))) %then %do;
        %put ERROR: QC workbook does not exist: &QCFILE.;
        %return;
    %end;

    /* Rebuild email detail from this run's completed QC matrix. */
    %if not %sysfunc(exist(data.QC_Check_Matrix)) %then %do;
        %put ERROR: DATA.QC_Check_Matrix is missing. Run QC before sending email.;
        %return;
    %end;

    data data.QC_Email_Issues;
        length ISSUE_LINE $600 ISSUE_LEVEL $16;
        set data.QC_Check_Matrix;
        if QC_FLAG='OK' then delete;
        if QC_FLAG='BASELINE ONLY' then
            ISSUE_LINE='REVIEW: No prior weekly QC baseline exists. Perform manual review before distribution.';
        else do;
            if QC_FLAG='YELLOW - New MTD Row' then ISSUE_LEVEL='INFORMATION';
            else if MONTH_GROUP ne 'CURRENT_MTD' and
                QC_FLAG in ('RED - Large Diff','MISSING ROW','NEW ROW') then
                ISSUE_LEVEL='BLOCKING';
            else ISSUE_LEVEL='REVIEW';
            ISSUE_LINE=catx(' | ',strip(ISSUE_LEVEL),strip(QC_FLAG),
                strip(REPORT_SECTION),strip(CATEGORY),strip(PLAN_TYPE),
                cats('Month=',put(MONTH_ID,8.)),
                cats('Group=',MONTH_GROUP),
                cats('Prior=',put(PRIOR_MBRS,comma18.2)),
                cats('Current=',put(CURRENT_MBRS,comma18.2)),
                cats('Change=',put(DIFF_MBRS,comma18.2)));
        end;
        keep ISSUE_LINE;
    run;

    %if &syserr > 4 %then %do;
        %put ERROR: Failed to build DATA.QC_Email_Issues. Email was not attempted.;
        %return;
    %end;

    %let QC_EMAIL_SUBJECT=UPG TEST - ACO Weekly Enrollment QC &QC_STATUS. - &today_char.;

    %put NOTE: OPENING QCMAIL EMAIL DEVICE;

    /* Match the email delivery setting used by the successful delivery tests. */
    options emailsys=smtp;

    filename QCMAIL email
        to=("&QC_EMAIL_TO.")
        %if %length(%superq(QC_EMAIL_CC)) > 0 %then %do;
            cc=("&QC_EMAIL_CC.")
        %end;
        subject="&QC_EMAIL_SUBJECT."
     attach=("&QCFILE." content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") 
        type="text/plain";

    /* Write the complete email in one DATA step.
       FILE ... MOD is not valid for the EMAIL access method. */
    data _null_;
        file QCMAIL lrecl=1000;
        length ISSUE_LINE $600;


        put "ACO Weekly Enrollment QC completed.";
        put;
        put "Run date: &today_char.";
        put "Prior comparison date: &QC_PRIOR_RUN_DT_CHAR.";
        put "QC status: &QC_STATUS.";
        put "Distribution decision: &DISTRIBUTION_DECISION.";
        put "Recommended action: &RECOMMENDED_ACTION.";
        put;
        put "Rows checked: &QC_TOTAL_ROWS.";
        put "Passed rows: &QC_OK_COUNT.";
        put "Yellow/warning rows: &QC_WARN_COUNT.";
        put "Red/fail rows: &QC_FAIL_COUNT.";
        put "Informational MTD rows: &QC_INFO_COUNT.";
        put;

        if "&QC_STATUS." = "FAIL" then
            put "ACTION REQUIRED: Review the red QC rows before distributing the report.";
        else if "&QC_STATUS." = "WARNING" then
            put "Please review the yellow QC rows before distributing the report.";
        else if "&QC_STATUS." = "BASELINE_ONLY" then
            put "No earlier weekly QC history was available. Today's matrix was saved as the baseline.";
        else
            put "The QC comparison completed without warning or fail rows.";

        put;
        put "Threshold method:";
        put "  Current MTD and previous month use business minimum thresholds.";
        put "  Older months use tighter thresholds.";
        put "  Adaptive thresholds activate after 8 historical weekly comparisons.";
        put;
        put "QC issues / informational flags:";

        if ISSUE_ROWS=0 then put "  None";
        do ISSUE_INDEX=1 to ISSUE_ROWS;
            set data.QC_Email_Issues point=ISSUE_INDEX nobs=ISSUE_ROWS;
            put "  - " ISSUE_LINE;
        end;

        put;
        put "QC workbook: &QCFILE.";
        put "Main report: &OUTFILE.";
        stop;
    run;

    filename QCMAIL clear;

    %put NOTE: QCMAIL EMAIL DEVICE CLOSED;
    %put NOTE: QC EMAIL SECTION FINISHED. Check the SAS log for EMAIL/SMTP errors. This message does not confirm delivery.;
    %put NOTE: ===============================================;

%mend U_SEND_ACO_QC_EMAIL;

%macro U_RUN_ACO_QC_AND_EMAIL; /* Build QC workbook, save history, and send QC email. */

/* These values must remain available after the QC macro finishes
   because the email is sent by a separate macro. */
%global QC_STATUS QC_FAIL_COUNT QC_WARN_COUNT QC_INFO_COUNT
        QC_TOTAL_ROWS QC_OK_COUNT
        DISTRIBUTION_DECISION REPORT_INTEGRITY RECOMMENDED_ACTION
        QC_PRIOR_RUN_DT_CHAR;
%local QC_HAS_PRIOR;

%let QC_STATUS=UNKNOWN;
%let QC_FAIL_COUNT=0;
%let QC_WARN_COUNT=0;
%let QC_INFO_COUNT=0;
%let DISTRIBUTION_DECISION=UNKNOWN;
%let REPORT_INTEGRITY=PASS;
%let RECOMMENDED_ACTION=Review QC results before distribution.;
%let QC_PRIOR_RUN_DT_CHAR=;
%let QC_HAS_PRIOR=0;

/* Remove work tables left by an earlier failed QC attempt. */
proc datasets library=data nolist;
    delete QC_Current_Matrix
           QC_Current_Matrix2
           QC_Prior_Matrix
           QC_Check_Matrix
           QC_Prior_Run_Info
           QC_Flag_Summary
           QC_History_Stats
           QC_Check_Base
           QC_Check_Base0
           QC_Check_Base1
           QC_Matrix_Long
           QC_Email_Issues
           QC_Summary
           QC_History_Load
           QC_History_Verify;
quit;

/* Ensure the permanent Snowflake history table exists. */
proc sql;
    connect using upgsnow;

    execute (USE DATABASE MHDWPROD) by upgsnow;
    execute (USE SCHEMA MHA) by upgsnow;
    execute (USE WAREHOUSE MHA_WH) by upgsnow;
    execute (USE ROLE MHA_TEAM_ROLE) by upgsnow;

    execute (
        CREATE TABLE IF NOT EXISTS ACOENR_REBUILD_QC_HISTORY_MATRIX
        (
            RUN_DT DATE,
            RUN_DTTM TIMESTAMP_NTZ,
            REPORT_SECTION VARCHAR,
            CATEGORY VARCHAR,
            PLAN_TYPE VARCHAR,
            MONTH_ID NUMBER,
            MBRS FLOAT
        )
    ) by upgsnow;

    disconnect from upgsnow;
quit;

%if &sqlrc ne 0 %then %do;
    %put ERROR: Could not create or verify ACOENR_REBUILD_QC_HISTORY_MATRIX.;
    %return;
%end;

/* Read the prior date for display and a numeric prior-run indicator.
   The comparison query below independently selects MAX(RUN_DT), so it does
   not depend on macro-variable substitution inside Snowflake SQL. */
proc sql noprint;
    connect using upgsnow;

    create table data.QC_Prior_Run_Info as
    select *
    from connection to upgsnow
    (
        select
            coalesce(to_char(max(RUN_DT), 'YYYY-MM-DD'),'') as PRIOR_RUN_DT_CHAR,
            case when max(RUN_DT) is null then 0 else 1 end as HAS_PRIOR
        from MHDWPROD.MHA.ACOENR_REBUILD_QC_HISTORY_MATRIX
        where RUN_DT < to_date(&today, 'YYYY-MM-DD')
    );

    disconnect from upgsnow;
quit;

proc sql noprint;
    select coalescec(strip(PRIOR_RUN_DT_CHAR),''),
           coalesce(HAS_PRIOR,0)
      into :QC_PRIOR_RUN_DT_CHAR trimmed,
           :QC_HAS_PRIOR trimmed
    from data.QC_Prior_Run_Info;
quit;

%if %length(%superq(QC_PRIOR_RUN_DT_CHAR)) = 0 %then
    %let QC_PRIOR_RUN_DT_CHAR=Not available;




%put NOTE: ===============================================;
%put NOTE: QC_HAS_PRIOR=&QC_HAS_PRIOR.;
%put NOTE: QC_PRIOR_RUN_DT_CHAR=[%superq(QC_PRIOR_RUN_DT_CHAR)];
%put NOTE: ===============================================;


/********************************************************************
 BUILD ONLY THE FIVE APPROVED QC SUBTOTAL CATEGORIES

 Expected:
   CASELOAD       All                         41 rows
   ENROLLMENT     Auto-Assigned               41 rows
   ENROLLMENT     Family Based Assignment     41 rows
   ENROLLMENT     Member Choice               41 rows
   DISENROLLMENT  CSR - Member Driven         41 rows

 Total expected when 41 months are present: 205 rows
********************************************************************/

proc sql;
    create table data.QC_Current_Matrix as

    /* 1. CASELOAD - All subtotal */
    select
        'CASELOAD' as REPORT_SECTION length=20,
        'All' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC
    where type='snapshot'
      and membertype='All'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 2. ENROLLMENT - Auto-Assigned subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Auto-Assigned' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Auto-Assigned'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 3. ENROLLMENT - Family Based Assignment subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Family Based Assignment' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Family Based Assignment'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 4. ENROLLMENT - Member Choice subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Member Choice' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Member Choice'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 5. DISENROLLMENT - CSR - Member Driven subtotal */
    select
        'DISENROLLMENT' as REPORT_SECTION length=20,
        'CSR - Member Driven' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC
    where type='disenrollment'
      and membertype='All'
      and strip(enrdisClass)='CSR - Member Driven'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek
    ;
quit;

%U_stop_if_sql_error(step=Create five-category QC current matrix);


/********************************************************************
 CONSOLIDATE AND STANDARDIZE CURRENT MATRIX
********************************************************************/

proc sql;
    create table data.QC_Current_Matrix2 as
    select
        strip(REPORT_SECTION) as REPORT_SECTION length=20,
        strip(CATEGORY)       as CATEGORY length=60,
        strip(PLAN_TYPE)      as PLAN_TYPE length=30,
        MONTH_ID,
        sum(MBRS) as CURRENT_MBRS format=comma18.2
    from data.QC_Current_Matrix
    where not missing(CATEGORY)
      and strip(CATEGORY) ne ''
      and strip(CATEGORY) ne 'NULL'
      and strip(PLAN_TYPE)='TOTAL'
    group by
        calculated REPORT_SECTION,
        calculated CATEGORY,
        calculated PLAN_TYPE,
        MONTH_ID;
quit;

%U_stop_if_sql_error(step=Create consolidated five-category QC matrix);


/********************************************************************
 VERIFY CATEGORY COUNTS AND TOTAL ROWS
********************************************************************/

proc sql;
    create table data.QC_Current_Verification as
    select
        REPORT_SECTION,
        CATEGORY,
        count(*) as ROW_COUNT,
        min(MONTH_ID) as FIRST_MONTH,
        max(MONTH_ID) as LAST_MONTH
    from data.QC_Current_Matrix2
    group by
        REPORT_SECTION,
        CATEGORY
    order by
        REPORT_SECTION,
        CATEGORY;
quit;

proc print data=data.QC_Current_Verification noobs;
    title "QC CURRENT MATRIX VERIFICATION";
run;
title;


proc sql noprint;
    select count(*)
      into :QC_CURRENT_MATRIX_ROWS trimmed
    from data.QC_Current_Matrix2;

    select count(distinct cats(
               strip(REPORT_SECTION),'|',
               strip(CATEGORY)
           ))
      into :QC_CURRENT_CATEGORY_COUNT trimmed
    from data.QC_Current_Matrix2;
quit;

%if %length(%superq(QC_CURRENT_MATRIX_ROWS))=0 %then
    %let QC_CURRENT_MATRIX_ROWS=0;

%if %length(%superq(QC_CURRENT_CATEGORY_COUNT))=0 %then
    %let QC_CURRENT_CATEGORY_COUNT=0;

%put NOTE: ===============================================================;
%put NOTE: QC CURRENT CATEGORY COUNT=&QC_CURRENT_CATEGORY_COUNT.;
%put NOTE: QC CURRENT MATRIX ROWS=&QC_CURRENT_MATRIX_ROWS.;
%put NOTE: ===============================================================;











/* Compare with the most recent prior weekly run when one exists. */
%if %sysevalf(&QC_HAS_PRIOR = 1) %then %do;

    /* Most recent prior weekly matrix. */
    proc sql;
        connect using upgsnow;

        create table data.QC_Prior_Matrix as
        select *
        from connection to upgsnow
        (
            select
                trim(REPORT_SECTION) as REPORT_SECTION,
                trim(CATEGORY)       as CATEGORY,
                trim(PLAN_TYPE)      as PLAN_TYPE,
                MONTH_ID,
                sum(MBRS) as PRIOR_MBRS
            from MHDWPROD.MHA.ACOENR_REBUILD_QC_HISTORY_MATRIX
            where RUN_DT =
                  (
                    select max(RUN_DT)
                    from MHDWPROD.MHA.ACOENR_REBUILD_QC_HISTORY_MATRIX
                    where RUN_DT < to_date(&today, 'YYYY-MM-DD')
                  )
              and PLAN_TYPE = 'TOTAL'
              and trim(CATEGORY) <> 'NULL'
            group by
                trim(REPORT_SECTION),
                trim(CATEGORY),
                trim(PLAN_TYPE),
                MONTH_ID
        );

        disconnect from upgsnow;
    quit;

    /* Historical weekly-change statistics.

       A historical pair is one saved run compared with the immediately
       preceding saved run for the same section/category/month.

       Statistics are calculated separately for:
         CURRENT_MTD
         PREVIOUS_MONTH
         OLDER_MONTH

       Adaptive thresholds are activated only after at least 8 historical
       weekly pairs exist. Until then, fixed business thresholds are used. */
    proc sql;
        connect using upgsnow;

        create table data.QC_History_Stats as
        select *
        from connection to upgsnow
        (
            with ordered_history as
            (
                select
                    RUN_DT,
                    trim(REPORT_SECTION) as REPORT_SECTION,
                    trim(CATEGORY)       as CATEGORY,
                    trim(PLAN_TYPE)      as PLAN_TYPE,
                    MONTH_ID,
                    MBRS,
                    lag(MBRS) over
                    (
                        partition by
                            trim(REPORT_SECTION),
                            trim(CATEGORY),
                            trim(PLAN_TYPE),
                            MONTH_ID
                        order by RUN_DT
                    ) as PRIOR_MBRS,

                    case
                        when MONTH_ID =
                             to_number(to_char(date_trunc('month',RUN_DT),'YYYYMMDD'))
                            then 'CURRENT_MTD'
                        when MONTH_ID =
                             to_number(to_char(dateadd(month,-1,date_trunc('month',RUN_DT)),'YYYYMMDD'))
                            then 'PREVIOUS_MONTH'
                        else 'OLDER_MONTH'
                    end as MONTH_GROUP

                from MHDWPROD.MHA.ACOENR_REBUILD_QC_HISTORY_MATRIX
                where PLAN_TYPE = 'TOTAL'
                  and trim(CATEGORY) <> 'NULL'
            ),
            weekly_pairs as
            (
                select
                    REPORT_SECTION,
                    CATEGORY,
                    PLAN_TYPE,
                    MONTH_GROUP,
                    abs(MBRS - PRIOR_MBRS) as ABS_WEEKLY_DIFF
                from ordered_history
                where PRIOR_MBRS is not null
            )
            select
                REPORT_SECTION,
                CATEGORY,
                PLAN_TYPE,
                MONTH_GROUP,
                count(*) as HIST_PAIR_COUNT,
                avg(ABS_WEEKLY_DIFF) as AVG_ABS_DIFF,
                coalesce(stddev_samp(ABS_WEEKLY_DIFF),0) as STD_ABS_DIFF
            from weekly_pairs
            group by
                REPORT_SECTION,
                CATEGORY,
                PLAN_TYPE,
                MONTH_GROUP
        );

        disconnect from upgsnow;
    quit;

    /* Step 1: Join current and prior totals and derive MONTH_GROUP.
       MONTH_GROUP is created here first because SAS PROC SQL cannot use a
       CALCULATED column inside another JOIN condition in the same query. */
    proc sql;
        create table data.QC_Check_Base0 as
        select
            coalesce(a.REPORT_SECTION,b.REPORT_SECTION) as REPORT_SECTION length=20,
            coalesce(a.CATEGORY,b.CATEGORY)             as CATEGORY length=60,
            coalesce(a.PLAN_TYPE,b.PLAN_TYPE)           as PLAN_TYPE length=30,
            coalesce(a.MONTH_ID,b.MONTH_ID)             as MONTH_ID,

            input("%superq(QC_PRIOR_RUN_DT_CHAR)", yymmdd10.)
                as PRIOR_RUN_DT format=date9.,
            coalesce(b.PRIOR_MBRS,0) as PRIOR_MBRS format=comma18.2,

            input("&today_char.", yymmdd10.)
                as CURRENT_RUN_DT format=date9.,
            coalesce(a.CURRENT_MBRS,0) as CURRENT_MBRS format=comma18.2

        from data.QC_Current_Matrix2 a
        full join data.QC_Prior_Matrix b
            on a.REPORT_SECTION = b.REPORT_SECTION
           and a.CATEGORY       = b.CATEGORY
           and a.PLAN_TYPE      = b.PLAN_TYPE
           and a.MONTH_ID       = b.MONTH_ID;
    quit;

    data data.QC_Check_Base1;
        set data.QC_Check_Base0;

        length MONTH_GROUP $20;
        format DIFF_MBRS comma18.2 PCT_CHANGE percent9.2;

        DIFF_MBRS = CURRENT_MBRS - PRIOR_MBRS;

        if PRIOR_MBRS > 0 then
            PCT_CHANGE = DIFF_MBRS / PRIOR_MBRS;
        else
            PCT_CHANGE = .;

        if MONTH_ID =
           input(put(intnx('month',
                          input("&today_char.",yymmdd10.),
                          0,'b'),yymmddn8.),8.)
        then MONTH_GROUP='CURRENT_MTD';

        else if MONTH_ID =
                input(put(intnx('month',
                               input("&today_char.",yymmdd10.),
                               -1,'b'),yymmddn8.),8.)
        then MONTH_GROUP='PREVIOUS_MONTH';

        else MONTH_GROUP='OLDER_MONTH';
    run;

    /* Step 2: Attach historical statistics using the already-created
       MONTH_GROUP column. */
    proc sql;
        create table data.QC_Check_Base as
        select
            a.*,
            coalesce(h.HIST_PAIR_COUNT,0) as HIST_PAIR_COUNT,
            coalesce(h.AVG_ABS_DIFF,0)    as AVG_ABS_DIFF format=comma18.2,
            coalesce(h.STD_ABS_DIFF,0)    as STD_ABS_DIFF format=comma18.2
        from data.QC_Check_Base1 a
        left join data.QC_History_Stats h
            on a.REPORT_SECTION = h.REPORT_SECTION
           and a.CATEGORY       = h.CATEGORY
           and a.PLAN_TYPE      = h.PLAN_TYPE
           and a.MONTH_GROUP    = h.MONTH_GROUP
        order by
            a.REPORT_SECTION,
            a.CATEGORY,
            a.PLAN_TYPE,
            a.MONTH_ID;
    quit;

    /* Final adaptive PASS/WARNING/FAIL logic.

       When at least 8 historical weekly pairs exist:
         WARNING = max(business warning floor, average + 2 standard deviations)
         FAIL    = max(business fail floor,    average + 3 standard deviations)

       Before 8 pairs exist, the business floors are used by themselves. */
    data data.QC_Check_Matrix;
        set data.QC_Check_Base;

        length QC_FLAG $25 THRESHOLD_METHOD $12;
        format WARNING_THRESHOLD FAIL_THRESHOLD comma18.2;

        select (MONTH_GROUP);
            when ('CURRENT_MTD') do;
                /* Current MTD is still developing during the month.
                   Large week-to-week movements are expected and should not
                   be treated like changes to closed historical months. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=15000;
                    FAIL_FLOOR=30000;
                end;
                else do;
                    WARNING_FLOOR=25000;
                    FAIL_FLOOR=50000;
                end;
            end;

            when ('PREVIOUS_MONTH') do;
                /* The immediately prior month can continue to settle because
                   of late eligibility and transaction updates. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=5000;
                    FAIL_FLOOR=15000;
                end;
                else do;
                    WARNING_FLOOR=5000;
                    FAIL_FLOOR=15000;
                end;
            end;

            otherwise do;
                /* Older closed months normally change by only about 20-40 members.

                   CASELOAD totals are very large (approximately 1.1M members).
                   A revision of 100-200 members is operationally small and should
                   trigger analyst review, not automatically block distribution.

                   For CASELOAD:
                     50-499 members = review warning
                     500+ members   = blocking failure

                   Enrollment/disenrollment categories retain the original
                   50 warning / 100 failure floors because their monthly totals
                   are much smaller. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=50;
                    FAIL_FLOOR=500;
                end;
                else do;
                    WARNING_FLOOR=50;
                    FAIL_FLOOR=100;
                end;
            end;
        end;

        if HIST_PAIR_COUNT >= 8 then do;
            THRESHOLD_METHOD='ADAPTIVE';
            WARNING_THRESHOLD=max(WARNING_FLOOR,
                                  AVG_ABS_DIFF + 2*STD_ABS_DIFF);
            FAIL_THRESHOLD=max(FAIL_FLOOR,
                               AVG_ABS_DIFF + 3*STD_ABS_DIFF);
        end;
        else do;
            THRESHOLD_METHOD='FIXED';
            WARNING_THRESHOLD=WARNING_FLOOR;
            FAIL_THRESHOLD=FAIL_FLOOR;
        end;

        if PRIOR_MBRS=0 and CURRENT_MBRS=0 then
            QC_FLAG='OK';

        /* During CURRENT_MTD, new/missing rows and large movement are review items,
           but they do not force an overall FAIL because the month is still developing. */
        else if MONTH_GROUP='CURRENT_MTD' then do;
            if PRIOR_MBRS=0 and CURRENT_MBRS>0 then
                QC_FLAG='YELLOW - New MTD Row';
            else if PRIOR_MBRS>0 and CURRENT_MBRS=0 then
                QC_FLAG='YELLOW - Missing MTD Row';
            else if abs(DIFF_MBRS) >= WARNING_THRESHOLD then
                QC_FLAG='YELLOW - Check';
            else
                QC_FLAG='OK';
        end;

        /* Closed months retain strict row-level failure handling. */
        else if PRIOR_MBRS=0 and CURRENT_MBRS>0 then
            QC_FLAG='NEW ROW';
        else if PRIOR_MBRS>0 and CURRENT_MBRS=0 then
            QC_FLAG='MISSING ROW';
        else if abs(DIFF_MBRS) >= FAIL_THRESHOLD then
            QC_FLAG='RED - Large Diff';
        else if abs(DIFF_MBRS) >= WARNING_THRESHOLD then
            QC_FLAG='YELLOW - Check';
        else
            QC_FLAG='OK';

        drop WARNING_FLOOR FAIL_FLOOR;
    run;

    proc sql noprint;
        /* Blocking failures prevent distribution. */
        select count(*)
          into :QC_FAIL_COUNT trimmed
        from data.QC_Check_Matrix
        where MONTH_GROUP ne 'CURRENT_MTD'
          and QC_FLAG in
            ('RED - Large Diff','MISSING ROW','NEW ROW');

        /* Review warnings require analyst review but do not automatically
           prevent distribution. New MTD rows are counted separately as
           informational because they are expected at the start of a month. */
        select count(*)
          into :QC_WARN_COUNT trimmed
        from data.QC_Check_Matrix
        where QC_FLAG in
            ('YELLOW - Check','YELLOW - Missing MTD Row');

        select count(*)
          into :QC_INFO_COUNT trimmed
        from data.QC_Check_Matrix
        where QC_FLAG='YELLOW - New MTD Row';
    quit;

    %if %length(%superq(QC_FAIL_COUNT))=0 %then %let QC_FAIL_COUNT=0;
    %if %length(%superq(QC_WARN_COUNT))=0 %then %let QC_WARN_COUNT=0;
    %if %length(%superq(QC_INFO_COUNT))=0 %then %let QC_INFO_COUNT=0;

    /* Technical QC status remains available for matrix/detail titles. */
    %if %sysevalf(&QC_FAIL_COUNT > 0) %then
        %let QC_STATUS=FAIL;
    %else %if %sysevalf(&QC_WARN_COUNT > 0) %then
        %let QC_STATUS=WARNING;
    %else
        %let QC_STATUS=PASS;

    /* Operational decision shown on the first worksheet. */
    %if %sysevalf(&QC_FAIL_COUNT > 0) %then %do;
        %let DISTRIBUTION_DECISION=DO NOT DISTRIBUTE;
        %let RECOMMENDED_ACTION=Resolve blocking QC failures before sharing the report.;
    %end;
    %else %if %sysevalf(&QC_WARN_COUNT > 0) %then %do;
        %let DISTRIBUTION_DECISION=REVIEW BEFORE DISTRIBUTION;
        %let RECOMMENDED_ACTION=Review highlighted warning rows and distribute after analyst approval.;
    %end;
    %else %do;
        %let DISTRIBUTION_DECISION=READY TO DISTRIBUTE;
        %let RECOMMENDED_ACTION=No blocking or review-level issues were detected.;
    %end;

%end;
%else %do;

    %let QC_STATUS=BASELINE_ONLY;
    %let QC_FAIL_COUNT=0;
    %let QC_WARN_COUNT=1;
    %let QC_INFO_COUNT=0;
    %let DISTRIBUTION_DECISION=REVIEW BEFORE DISTRIBUTION;
    %let RECOMMENDED_ACTION=No prior weekly baseline exists. Perform manual review before distribution.;

    data data.QC_Check_Matrix;
        length REPORT_SECTION $20 CATEGORY $60 PLAN_TYPE $30
               QC_FLAG $25 MONTH_GROUP $20 THRESHOLD_METHOD $12;
        format PRIOR_RUN_DT CURRENT_RUN_DT date9.
               PRIOR_MBRS CURRENT_MBRS DIFF_MBRS
               AVG_ABS_DIFF STD_ABS_DIFF
               WARNING_THRESHOLD FAIL_THRESHOLD comma18.2
               PCT_CHANGE percent9.2;

        REPORT_SECTION = 'BASELINE';
        CATEGORY = 'No prior weekly QC run found';
        PLAN_TYPE = 'TOTAL';
        MONTH_ID = .;
        PRIOR_RUN_DT = .;
        PRIOR_MBRS = .;
        CURRENT_RUN_DT = input("&today_char.", yymmdd10.);
        CURRENT_MBRS = .;
        DIFF_MBRS = .;
        PCT_CHANGE = .;
        MONTH_GROUP = '';
        HIST_PAIR_COUNT = 0;
        AVG_ABS_DIFF = .;
        STD_ABS_DIFF = .;
        WARNING_THRESHOLD = .;
        FAIL_THRESHOLD = .;
        THRESHOLD_METHOD = 'FIXED';
        QC_FLAG = 'BASELINE ONLY';
        output;
    run;

%end;

%put NOTE: ===============================================;
%put NOTE: QC_STATUS=&QC_STATUS.;
%put NOTE: DISTRIBUTION_DECISION=&DISTRIBUTION_DECISION.;
%put NOTE: REPORT_INTEGRITY=&REPORT_INTEGRITY.;
%put NOTE: QC_FAIL_COUNT=&QC_FAIL_COUNT.;
%put NOTE: QC_WARN_COUNT=&QC_WARN_COUNT.;
%put NOTE: QC_INFO_COUNT=&QC_INFO_COUNT.;
%put NOTE: ===============================================;

proc sql;
    create table data.QC_Flag_Summary as
    select QC_FLAG, count(*) as ROWS
    from data.QC_Check_Matrix
    group by QC_FLAG
    order by QC_FLAG;
quit;

data _null_;
    set data.QC_Flag_Summary;
    put "NOTE: QC_FLAG_SUMMARY: " QC_FLAG= ROWS=;
run;

/* Create a report-style wide QC matrix.
   Only category TOTAL rows are included. Each category is shown as:
     Prior Members
     Current Members
     Difference
     % Change
     QC Flag
   Months run horizontally, matching the production report layout. */

data data.QC_Matrix_Long;
    set data.QC_Check_Matrix;

    length METRIC $20 VALUE $30 BLOCK_STATUS $25;
    format MONTH_ID 8.;

    /* Carry the QC decision to every metric row so the full 5-row block
       can be colored consistently in the wide matrix. */
    BLOCK_STATUS=strip(QC_FLAG);

    METRIC_ORDER=1;
    METRIC='Prior Members';
    if missing(PRIOR_MBRS) then VALUE='';
    else VALUE=strip(put(PRIOR_MBRS,comma18.));
    output;

    METRIC_ORDER=2;
    METRIC='Current Members';
    if missing(CURRENT_MBRS) then VALUE='';
    else VALUE=strip(put(CURRENT_MBRS,comma18.));
    output;

    METRIC_ORDER=3;
    METRIC='Difference';
    if missing(DIFF_MBRS) then VALUE='';
    else VALUE=strip(put(DIFF_MBRS,comma18.));
    output;

    METRIC_ORDER=4;
    METRIC='% Change';
    if missing(PCT_CHANGE) then VALUE='';
    else VALUE=strip(put(PCT_CHANGE,percent9.2));
    output;

    METRIC_ORDER=5;
    METRIC='QC Flag';
    VALUE=strip(QC_FLAG);
    output;

    keep REPORT_SECTION CATEGORY PLAN_TYPE MONTH_ID
         METRIC_ORDER METRIC VALUE BLOCK_STATUS;
run;

proc sort data=data.QC_Matrix_Long;
    by REPORT_SECTION CATEGORY METRIC_ORDER MONTH_ID;
run;

/* Month header format for the QC matrix.
   The current month is labeled YYYYMM01-MTD. */

proc sort data=data.QC_Check_Matrix(keep=MONTH_ID)
          out=work.QC_Month_Source nodupkey;
    by MONTH_ID;
run;

data work.QC_Month_Format;
    length FMTNAME $32 TYPE $1 LABEL $20;
    retain FMTNAME 'QC_MON' TYPE 'N';

    set work.QC_Month_Source;
    by MONTH_ID;

    if first.MONTH_ID then do;
        START=MONTH_ID;

        if MONTH_ID =
           input(put(intnx('month',
                          input("&today_char.",yymmdd10.),
                          0,'b'),yymmddn8.),8.)
        then LABEL=cats(put(MONTH_ID,8.),'-MTD');
        else LABEL=put(MONTH_ID,8.);

        output;
    end;

    keep FMTNAME TYPE START LABEL;
run;

proc sort data=work.QC_Month_Format nodupkey;
    by START;
run;

proc format cntlin=work.QC_Month_Format;
run;


/********************************************************************
 CALCULATE QC SUMMARY COUNTS BEFORE CREATING THE QC WORKBOOK
********************************************************************/
proc sql noprint;
    select count(*)
      into :QC_TOTAL_ROWS trimmed
    from data.QC_Check_Matrix;

    select count(*)
      into :QC_OK_COUNT trimmed
    from data.QC_Check_Matrix
    where QC_FLAG='OK';
quit;

%if %length(%superq(QC_TOTAL_ROWS)) = 0 %then
    %let QC_TOTAL_ROWS=0;

%if %length(%superq(QC_OK_COUNT)) = 0 %then
    %let QC_OK_COUNT=0;


/*--------------------------------------------------------------
  Export separate QC workbook
--------------------------------------------------------------*/

%global QCFILE;
%let QCFILE=&U_RUN_DIR./ReportTestMonthly-&repdt._REBUILD_SASQA.xlsx;

%put NOTE: QCFILE=&QCFILE;

options orientation=landscape;
ods excel file="&QCFILE"
 options(sheet_interval='none' embedded_titles='yes' absolute_column_width='14'
         flow='tables' frozen_headers='on' frozen_rowheaders='on')
 style=styles.minimal;


/*--------------------------------------------------------------
  QC Summary
--------------------------------------------------------------*/

ods excel options(
    sheet_name="QC_Summary"
    sheet_interval='none'
    autofilter="none"
);

title "ACO Weekly Enrollment QC Summary";

data data.QC_Summary;
    length ITEM $40 VALUE $80;

    ITEM='Run Date';
    VALUE="&today_char.";
    output;

    ITEM='Prior Comparison Date';
    VALUE="%superq(QC_PRIOR_RUN_DT_CHAR)";
    output;

    ITEM='Distribution Decision';
    VALUE="&DISTRIBUTION_DECISION.";
    output;

    ITEM='Recommended Action';
    VALUE="&RECOMMENDED_ACTION.";
    output;

    ITEM='Report Integrity';
    VALUE="&REPORT_INTEGRITY.";
    output;

    ITEM='Technical QC Status';
    VALUE="&QC_STATUS.";
    output;

    ITEM='Rows Checked';
    VALUE="&QC_TOTAL_ROWS.";
    output;

    ITEM='Passed Rows';
    VALUE="&QC_OK_COUNT.";
    output;

    ITEM='Blocking Failures';
    VALUE="&QC_FAIL_COUNT.";
    output;

    ITEM='Review Warnings';
    VALUE="&QC_WARN_COUNT.";
    output;

    ITEM='Informational Flags';
    VALUE="&QC_INFO_COUNT.";
    output;

    ITEM='Decision Rule';
    VALUE='Blocking failure = do not distribute; warning = analyst review';
    output;

    ITEM='Adaptive Threshold Rule';
    VALUE='Activates after 8 historical weekly comparisons';
    output;
run;

proc report data=data.QC_Summary nowd
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center];

    columns ITEM VALUE;

    define ITEM / display "QC Summary Item"
        style(column)=[font_weight=bold];

    define VALUE / display "Value";

    compute VALUE;
        if ITEM='Distribution Decision' then do;
            if VALUE='READY TO DISTRIBUTE' then
                call define(_ROW_,'style',
                    'style=[background=#C6EFCE color=#006100 font_weight=bold]');
            else if VALUE='REVIEW BEFORE DISTRIBUTION' then
                call define(_ROW_,'style',
                    'style=[background=#FFEB9C color=#9C6500 font_weight=bold]');
            else if VALUE='DO NOT DISTRIBUTE' then
                call define(_ROW_,'style',
                    'style=[background=#FFC7CE color=#9C0006 font_weight=bold]');
        end;
        else if ITEM='Report Integrity' and VALUE='PASS' then
            call define(_ROW_,'style',
                'style=[background=#C6EFCE color=#006100 font_weight=bold]');
    endcomp;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*--------------------------------------------------------------
  QC Matrix
--------------------------------------------------------------*/

ods excel options(
    sheet_name="QC_Matrix"
    sheet_interval='now'
    autofilter="none"
);

title "ACO Enrollment QC Matrix - Prior Weekly Run Compared to Current Run";
title2 "Category TOTAL Rows Only - QC Status: &QC_STATUS.";
title3 "Prior Run: %superq(QC_PRIOR_RUN_DT_CHAR)   Current Run: &today_char.";

proc report data=data.QC_Matrix_Long nowd missing
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center]
    style(column)=[vjust=middle];

    columns
        REPORT_SECTION
        CATEGORY
        PLAN_TYPE
        METRIC_ORDER
        METRIC
        BLOCK_STATUS
        MONTH_ID,VALUE
    ;

    define REPORT_SECTION / group "Section"
        style(column)=[just=left];

    define CATEGORY / group "Category"
        style(column)=[just=left];

    define PLAN_TYPE / group "Plan Type"
        style(column)=[just=left];

    define METRIC_ORDER / group noprint;

    define METRIC / group "Measure"
        style(column)=[just=left font_weight=bold];

    define BLOCK_STATUS / group noprint;

    define MONTH_ID / across "Month"
        order=internal
        format=QC_MON.;

    define VALUE / group ""
        style(column)=[just=right];

    compute VALUE;

        if BLOCK_STATUS='OK' then
            call define(
                _COL_,
                'style',
                'style=[background=#C6EFCE color=#006100]'
            );

        else if index(BLOCK_STATUS,'YELLOW') > 0 then
            call define(
                _COL_,
                'style',
                'style=[background=#FFEB9C color=#9C6500 font_weight=bold]'
            );

        else if index(BLOCK_STATUS,'RED') > 0
             or BLOCK_STATUS in ('MISSING ROW','NEW ROW') then
            call define(
                _COL_,
                'style',
                'style=[background=#FFC7CE color=#9C0006 font_weight=bold]'
            );

        else if BLOCK_STATUS='BASELINE ONLY' then
            call define(
                _COL_,
                'style',
                'style=[background=#D9EAF7 color=#1F4E78 font_weight=bold]'
            );

    endcomp;

    break after CATEGORY / skip;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*--------------------------------------------------------------
  QC Detail - one row per section/category/month TOTAL
--------------------------------------------------------------*/

ods excel options(
    sheet_name="QC_Detail"
    sheet_interval='now'
    autofilter="all"
    frozen_headers="yes"
);

title "ACO Enrollment QC Detail";
title2 "Category TOTAL Rows Only - QC Status: &QC_STATUS.";

proc report data=data.QC_Check_Matrix nowd missing
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center]
    style(column)=[vjust=middle];

    columns REPORT_SECTION CATEGORY PLAN_TYPE MONTH_ID MONTH_GROUP
            PRIOR_RUN_DT PRIOR_MBRS CURRENT_RUN_DT CURRENT_MBRS
            DIFF_MBRS PCT_CHANGE HIST_PAIR_COUNT AVG_ABS_DIFF STD_ABS_DIFF
            WARNING_THRESHOLD FAIL_THRESHOLD THRESHOLD_METHOD QC_FLAG;

    define REPORT_SECTION / display "Section";
    define CATEGORY       / display "Category";
    define PLAN_TYPE      / display "Plan Type";
    define MONTH_ID       / display "Month";
    define MONTH_GROUP    / display "Month Group";
    define PRIOR_RUN_DT   / display "Prior Run" format=date9.;
    define PRIOR_MBRS     / display "Prior Members" format=comma18.1;
    define CURRENT_RUN_DT / display "Current Run" format=date9.;
    define CURRENT_MBRS   / display "Current Members" format=comma18.1;
    define DIFF_MBRS      / display "Difference" format=comma18.1;
    define PCT_CHANGE     / display "% Change" format=percent9.2;
    define HIST_PAIR_COUNT / display "History Pairs";
    define AVG_ABS_DIFF   / display "Avg Abs Diff" format=comma18.1;
    define STD_ABS_DIFF   / display "Std Abs Diff" format=comma18.1;
    define WARNING_THRESHOLD / display "Warning Threshold" format=comma18.1;
    define FAIL_THRESHOLD / display "Fail Threshold" format=comma18.1;
    define THRESHOLD_METHOD / display "Threshold Method";
    define QC_FLAG        / display "QC Flag";

    compute QC_FLAG;
        if QC_FLAG='OK' then
            call define(_ROW_,'style','style=[background=#C6EFCE color=#006100]');
        else if index(QC_FLAG,'YELLOW') > 0 then
            call define(_ROW_,'style','style=[background=#FFEB9C color=#9C6500 font_weight=bold]');
        else if index(QC_FLAG,'RED') > 0
             or QC_FLAG in ('MISSING ROW','NEW ROW') then
            call define(_ROW_,'style','style=[background=#FFC7CE color=#9C0006 font_weight=bold]');
        else if QC_FLAG='BASELINE ONLY' then
            call define(_ROW_,'style','style=[background=#D9EAF7 color=#1F4E78 font_weight=bold]');
    endcomp;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*--------------------------------------------------------------
  Close QC workbook before saving history or attaching it
--------------------------------------------------------------*/

title;
title2;
title3;

ods excel close;

%put NOTE: QC workbook creation completed: &QCFILE;

/************************************************************/
/* SAVE CURRENT TOTAL-CATEGORY MATRIX TO QC HISTORY             */
/*                                                              */
/* This is the validated save method tested on 30JUL2026.       */
/* Same-day reruns delete and replace today's rows.              */
/************************************************************/

%global QC_HISTORY_SAVED_ROWS;
%let QC_HISTORY_SAVED_ROWS=0;

/* Confirm the current category-total matrix exists and has rows. */
proc sql noprint;
    select count(*)
      into :QC_CURRENT_HISTORY_ROWS trimmed
    from data.QC_Current_Matrix
    where strip(CATEGORY) ne 'NULL'
      and strip(CATEGORY) ne ''
      and strip(PLAN_TYPE) = 'TOTAL';
quit;

%put NOTE: QC CURRENT TOTAL-CATEGORY ROWS=&QC_CURRENT_HISTORY_ROWS.;

%if %length(%superq(QC_CURRENT_HISTORY_ROWS)) = 0 %then %do;
    %put ERROR: QC current matrix row count was not populated. History was not updated.;
    %return;
%end;

%if %sysevalf(&QC_CURRENT_HISTORY_ROWS <= 0) %then %do;
    %put ERROR: QC current matrix contains zero TOTAL-category rows. History was not updated.;
    %return;
%end;

/* Remove the prior temporary Snowflake staging table. */
proc sql;
    connect using upgsnow;

    execute (USE DATABASE MHDWPROD) by upgsnow;
    execute (USE SCHEMA MHA) by upgsnow;
    execute (USE WAREHOUSE MHA_WH) by upgsnow;
    execute (USE ROLE MHA_TEAM_ROLE) by upgsnow;

    execute (
        DROP TABLE IF EXISTS ACOENR_REBUILD_QC_STAGE
    ) by upgsnow;

    disconnect from upgsnow;
quit;

%U_stop_if_sql_error(step=Drop QC history stage table);

/* Copy the current TOTAL-category matrix to Snowflake staging. */
proc sql;
    create table upgsnow.ACOENR_REBUILD_QC_STAGE as
    select
        strip(REPORT_SECTION) as REPORT_SECTION,
        strip(CATEGORY)       as CATEGORY,
        'TOTAL'               as PLAN_TYPE,
        MONTH_ID,
        MBRS
    from data.QC_Current_Matrix
    where strip(CATEGORY) ne 'NULL'
      and strip(CATEGORY) ne ''
      and strip(PLAN_TYPE) = 'TOTAL';
quit;

%U_stop_if_sql_error(step=Create QC history stage table);

/* Delete and replace the current run-date history rows. */
proc sql;
    connect using upgsnow;

    execute (USE DATABASE MHDWPROD) by upgsnow;
    execute (USE SCHEMA MHA) by upgsnow;
    execute (USE WAREHOUSE MHA_WH) by upgsnow;
    execute (USE ROLE MHA_TEAM_ROLE) by upgsnow;

    execute (
        DELETE FROM ACOENR_REBUILD_QC_HISTORY_MATRIX
        WHERE RUN_DT = TO_DATE(&today, 'YYYY-MM-DD')
    ) by upgsnow;

    execute (
        INSERT INTO ACOENR_REBUILD_QC_HISTORY_MATRIX
        (
            RUN_DT,
            RUN_DTTM,
            REPORT_SECTION,
            CATEGORY,
            PLAN_TYPE,
            MONTH_ID,
            MBRS
        )
        SELECT
            TO_DATE(&today, 'YYYY-MM-DD'),
            CURRENT_TIMESTAMP(),
            REPORT_SECTION,
            CATEGORY,
            PLAN_TYPE,
            MONTH_ID,
            MBRS
        FROM ACOENR_REBUILD_QC_STAGE
    ) by upgsnow;

    disconnect from upgsnow;
quit;

%U_stop_if_sql_error(step=Save current QC history);

/* Verify the exact number of rows saved for this run date. */
proc sql noprint;
    select count(*)
      into :QC_HISTORY_SAVED_ROWS trimmed
    from upgsnow.ACOENR_REBUILD_QC_HISTORY_MATRIX
    where run_dt=input("&today_char.",yymmdd10.)
      and strip(PLAN_TYPE)='TOTAL';
quit;

%if %length(%superq(QC_HISTORY_SAVED_ROWS)) = 0 %then
    %let QC_HISTORY_SAVED_ROWS=0;

%put NOTE: ===============================================================;
%put NOTE: QC HISTORY ROWS SAVED FOR &today_char.=&QC_HISTORY_SAVED_ROWS.;
%put NOTE: EXPECTED QC HISTORY ROWS=&QC_CURRENT_HISTORY_ROWS.;
%put NOTE: ===============================================================;

%if %sysevalf(&QC_HISTORY_SAVED_ROWS ne &QC_CURRENT_HISTORY_ROWS) %then %do;
    %put ERROR: QC history verification failed. Saved row count does not match current matrix.;
    %abort cancel;
%end;

/*--------------------------------------------------------------
  Send QC email after the QC workbook is closed and history is verified
--------------------------------------------------------------*/

/* Test candidate: QC evidence retained; automatic email deferred to final pipeline. */



%mend U_RUN_ACO_QC_AND_EMAIL;

/* Run the QC workbook, history, and email process. */
%U_RUN_ACO_QC_AND_EMAIL;

/* To resend QC email in this same session after successful QC, run the U_SEND_ACO_QC_EMAIL macro. */


/*******************Report Output*********************/
/*
   ACTIVE PRODUCTION WORKSHEETS IN THIS FINAL v3 FILE:
     1. Summary
     2. Summary-Enroll-Region
     3. Summary-Caseload-Reg x SA
     4. Summary-Enroll-Reg X SA
     5. Summary-DisEnroll-Reg X SA
     6. Caseload
     7. Caseload-Reg X SA
     8. Enrollment
     9. Enrollment-Reg X SA
    10. Disenrollment
    11. Disenrollment_Reg X SA

   All other worksheet code is preserved below but wrapped in SKIP_* macros,
   so it remains available for future reference and does not run.
*/
/*****************************************************************
 Dynamic Month Format
 Automatically marks the report month as MTD.
 FIRSTDTWEEK is numeric YYYYMMDD.
*****************************************************************/

%put NOTE: REPDT=&repdt;
%put NOTE: TODAY_CHAR=&today_char.;

data fmt_mon_value;
    length fmtname $32 type $1 label $20;
    retain fmtname 'MON_VALUE'
           type 'N';

    /* Derive the report month inside the DATA step.
       This avoids an empty REPORT_MONTH_DATE macro variable. */
    report_month_date=intnx(
        'month',
        input("&today_char.",yymmdd10.),
        0,
        'beginning'
    );

    sas_month='01MAR2023'd;

    do while (sas_month <= report_month_date);

        start=input(put(sas_month,yymmddn8.),8.);
        end=start;

        if sas_month=report_month_date then
            label=cats(put(start,8.),'-MTD');
        else
            label=put(start,8.);

        output;

        sas_month=intnx('month',sas_month,1,'beginning');
    end;

    keep fmtname type start end label;
run;

proc format cntlin=fmt_mon_value;
run;
%let style = %nrstr( missing nowd spanrows center headline headskip split='*' 
     style(report) =[ verticalalign=m  borderwidth=1px borderstyle=solid  bordercolor=black Rules=all Background=white Frame=box cellspacing=0 cellpadding=0 ] 
     style(Header) =[ font_face="Arial" bordercolor=black borderwidth=1px borderstyle=solid  verticalalign=m  background=blue color=white  font_weight=bold  font_size=11pt  just=center ]
     style(lines)  =[ font_face="Arial" font_size=11pt  color=black ]   
     style(column) =[ font_face="Arial" font_size=11pt bordercolor=black borderwidth=1px borderstyle=solid  textalign=right vjust=c  verticalalign=m  backgroundposition=right_center ] ); 

%put &style;

ods html close;
ods listing close;
ods graphics on/reset=all antialias=on height=3in width=6in border=off scale=on scalemarkers=on;
ods noresults noproctitle ;
options nodate number 
topmargin="0.5in" leftmargin="0.25in" bottommargin="0.5in" rightmargin="0.25in";

options orientation=landscape;

/* Formatting reference: published October 7 report. Native numeric widths
   grow with the reporting months, so no fixed last-column limit is used. */
%macro U_NATIVE_WIDTHS(prefix=,num=);
 %local _i _months;
 %let _months=%eval(%sysfunc(intck(month,%sysfunc(inputn(20230301,yymmdd8.)),%sysfunc(inputn(&EndDate_char.,yymmdd10.))))+1);
 &prefix.%do _i=1 %to %eval(2*&_months.);,&num.%end;
%mend;

ods excel file="&OUTFILE"
 options(sheet_interval='none' embedded_titles='no' embedded_footnotes='yes'
         absolute_column_width='14' flow='tables' gridlines='off'
         frozen_headers='off' frozen_rowheaders='off' row_repeat='header'
         pages_fitwidth='1' pages_fitheight='13')
 style=styles.minimal;

/* 1a. Summary Caseloads by ACOs without Region/service areas */

ods excel options(sheet_name="Summary" sheet_interval='none'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='7' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "Weekly ACO/MCO/PCC Enrollment Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MH Analytics" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members'/* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/

  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/

  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') /*and provname2 is not null /*and MCO_region ^= 'Out of state/Unknown'*/;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*---------------------------------------------------------------*/

/* 1b. Summary Enrollments by ACOs without Regions/Service Areas */

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );

  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/

  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
    
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
 
  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
   where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and membertype='All';
run;



/*---------------------------------------------------------*/


/* 1c. Summary Disenrollments by ACOs without Regions/Service Areas */

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
 
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass is not null and membertype='All';
run;



/*1d. last 3 months of data (1 quarter) auto-assignments */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Auto-Assigned Enroll 3m ===== */
%macro U_AUTO_ASSIGNED_ENROLL_3M();
ods excel options(sheet_name="Auto-Assigned Enroll 3m" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Auto-Assigned Enrollments By Reions and Srv. Areas" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enroll2_&repdt. &style.;  
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   

  columns ( 'Number of Members' MCO_REGION, SERVICE_AREA, /*firstdtweek,*/ mbrs);  
  columns ( 'Percent of Members' MCO_REGION, SERVICE_AREA, /*firstdtweek,*/ pcttype); 
    /*---------------------------------------*/

  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  define MCO_REGION/across '' order=internal descending ;
  define SERVICE_AREA/across '' order=internal descending ;
  
  /*define firstdtweek/across ''format=MON_value.  ;*/
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
    

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and firstdtweek in (20190101, 20190201, 20190301) and enrdisClass = 'Auto-Assigned'
        and membertype='All';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*----------------------------------------------------------*/

/* 2a. Summary Caseloads by Region/ACOs */


%mend U_AUTO_ASSIGNED_ENROLL_3M;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Auto-Assigned Enroll 3m ===== */

/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Region ===== */
%macro U_SUMMARY_CASELOAD_REGION();
ods excel options(sheet_name="Summary-Caseload-Region" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "Weekly ACO/MCO/PCC Enrollment By regions - Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MH Analytics" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MassHealth ACO/MCO/PCC Members by Regions - Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
 
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
    

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*----------------------------------------------------------*/

/* 2b. Summary Enrollments by Regions/ACOs */


%mend U_SUMMARY_CASELOAD_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Region ===== */
ods excel options(sheet_name="Summary-Enroll-Region" sheet_interval='now'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,10.623125,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='1' frozen_rowheaders='off');


ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments By regions - Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );

  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
   

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null
       and membertype='All';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*----------------------------------------------------------------------*/


/* 2c. Summary Disenrollments by Regions /ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnroll-Region ===== */
%macro U_SUMMARY_DISENROLL_REGION();
ods excel options(sheet_name="Summary-DisEnroll-Region" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments By regions - Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );
   
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region is not null and MCO_region ^= 'Out of state/Unknown'
         and membertype='All' and enrdisClass ne '';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*----------------------------------------------------------*/

/* 3a-1. Summary Caseloads by Region/service areas/ACOs */


%mend U_SUMMARY_DISENROLL_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnroll-Region ===== */
ods excel options(sheet_name="Summary-Caseload-Reg x SA" sheet_interval='now'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,10.623125,10.623125,17.17,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='6' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "Weekly ACO/MCO/PCC Enrollment By Regions and Srv Areas Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MH Analytics" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA);  
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };    
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };   
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
   

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/* 3a-2. Summary Caseloads by Region/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Reg x RC ===== */
%macro U_SUMMARY_CASELOAD_REG_X_RC();
ods excel options(sheet_name="Summary-Caseload-Reg x RC" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "Weekly ACO/MCO/PCC Enrollment By Regions and Srv Areas Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MH Analytics" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */ 
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };    
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };  */ 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
   

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*------------------------------------------------------*/


/* 2c-1. Summary Enrollments by Regions/Service Areas/ACOs */


%mend U_SUMMARY_CASELOAD_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Reg x RC ===== */
ods excel options(sheet_name="Summary-Enroll-Reg X SA" sheet_interval='now'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,17.17,10.623125,10.623125,10.623125,17.17,17.17,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='off' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments By Regions and Srv Areas Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
   

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass ne '' ;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/* 2c-2. Summary Enrollments by Regions/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Enroll-Reg X RC ===== */
%macro U_SUMMARY_ENROLL_REG_X_RC();
ods excel options(sheet_name="Summary-Enroll-Reg X RC" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments By Regions and Srv Areas Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA);*/ 
  columns ( 'Plan Type' provtype2);
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
   

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass ne '' ;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*---------------------------------------------------------*/



/* 3c-1. Summary Disenrollments by Regions/Service Areas /ACOs */


%mend U_SUMMARY_ENROLL_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Enroll-Reg X RC ===== */
ods excel options(sheet_name="Summary-DisEnroll-Reg X SA" sheet_interval='now'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,17.17,10.623125,10.623125,10.623125,17.17,17.17,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='1' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Disnrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB')  and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/* 3c-2. Summary Disenrollments by Regions/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnoll-Reg X RC ===== */
%macro U_SUMMARY_DISENOLL_REG_X_RC();
ods excel options(sheet_name="Summary-DisEnoll-Reg X RC" sheet_interval='now' );

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'Disnrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB')  and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*----------------------------------------------*/

/* Caseload */


%mend U_SUMMARY_DISENOLL_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnoll-Reg X RC ===== */
ods excel options(sheet_name="Caseload" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(15.533281,10.623125,15.533281,15.533281,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='1' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across ''format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB');
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*---------------------------------------------------*/


/* Caseload By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Caseload-Region ===== */
%macro U_CASELOAD_REGION();
ods excel options(sheet_name="Caseload-Region" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
      
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
 
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*-------------------------------------------------------------------------*/


/* Caseload By Regions By Service Area*/

%mend U_CASELOAD_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Caseload-Region ===== */
ods excel options(sheet_name="Caseload-Reg X SA" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(15.533281,10.623125,10.623125,10.623125,15.533281,15.533281,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='off' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/    
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*-------------------------------------------------------------------------*/
/*-------------------------------------------------------------------------*/


/* Caseload By Regions By RC*/

/* ===== COMMENTED OUT UNUSED WORKSHEET: Caseload-Reg X RC ===== */
%macro U_CASELOAD_REG_X_RC();
ods excel options(sheet_name="Caseload-Reg X RC" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/    
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
 /* define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*-------------------------------------------------------------------------*/




/* Enrollments*/


%mend U_CASELOAD_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Caseload-Reg X RC ===== */
ods excel options(sheet_name="Enrollment" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,15.533281,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='7' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Auto-Assigned : Member Enrolled through Auto Assignment" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Special Assignment : Enrollment Created as part of Special Assignment work" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) The batch fixes, such as moving Tufts UMASS members to the PCC plan are classified as Re-enrollment on 3/1 in the report.";
    line @1 "2) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and membertype='All';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*----------------------------------------------*/


/* Enrollments By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Enrollment-Region ===== */
%macro U_ENROLLMENT_REGION();
ods excel options(sheet_name="Enrollment-Region" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Auto-Assigned : Member Enrolled through Auto Assignment" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Special Assignment : Enrollment Created as part of Special Assignment work" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown'
        and membertype='All';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*----------------------------------------------------*/

/* Enrollments By Regions By Service Area */


%mend U_ENROLLMENT_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Enrollment-Region ===== */
ods excel options(sheet_name="Enrollment-Reg X SA" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(15.533281,17.17,10.623125,10.623125,10.623125,15.533281,15.533281,17.17,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='1' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Auto-Assigned : Member Enrolled through Auto Assignment" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Special Assignment : Enrollment Created as part of Special Assignment work" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*----------------------------------------------------*/
/*----------------------------------------------------*/

/* Enrollments By Regions By RC */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Enrollment-Reg X RC ===== */
%macro U_ENROLLMENT_REG_X_RC();
ods excel options(sheet_name="Enrollment-Reg X RC" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Auto-Assigned : Member Enrolled through Auto Assignment" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Special Assignment : Enrollment Created as part of Special Assignment work" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
 /* define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };*/ 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');



/*----------------------------------------------------*/



/* Disenrollments*/


%mend U_ENROLLMENT_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Enrollment-Reg X RC ===== */
ods excel options(sheet_name="Disenrollment" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,15.533281,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='6' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Member Driven : Code used by CSR for closing a case when a member calls" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "System Generated : Automatic Disenrollment created by the System" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);  
  columns ( 'Reason' enrdisClass );
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
 
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across ''format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and membertype='All' and enrdisClass is not null;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*----------------------------------------------------*/


/* Disenrollments By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Region ===== */
%macro U_DISENROLLMENT_REGION();
ods excel options(sheet_name="Disenrollment_Region" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Member Driven : Code used by CSR for closing a case when a member calls" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "System Generated : Automatic Disenrollment created by the System" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
 
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; 
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null
        and membertype='All';
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*----------------------------------------------------*/

/* Disenrollments By Regions by Service Areas */


%mend U_DISENROLLMENT_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Region ===== */
ods excel options(sheet_name="Disenrollment_Reg X SA" sheet_interval='now' autofilter='none' absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(15.533281,17.17,10.623125,10.623125,10.623125,15.533281,15.533281,17.17,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='off' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Member Driven : Code used by CSR for closing a case when a member calls" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "System Generated : Automatic Disenrollment created by the System" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format= MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*----------------------------------------------------*/
/* Disenrollments By Regions by RC */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Reg X RC ===== */
%macro U_DISENROLLMENT_REG_X_RC();
ods excel options(sheet_name="Disenrollment_Reg X RC" sheet_interval='now' autofilter='none');

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Member Driven : Code used by CSR for closing a case when a member calls" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "System Generated : Automatic Disenrollment created by the System" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA);*/
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format= MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');

/*----------------------------------------------------*/




%mend U_DISENROLLMENT_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Reg X RC ===== */

/* ===== COMMENTED OUT UNUSED WORKSHEET: Code Crosswalk ===== */
%macro U_CODE_CROSSWALK();
ods excel options(sheet_name="Code Crosswalk" sheet_interval='now' autofilter='none');
proc print data=data.code_xwalk; run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


%mend U_CODE_CROSSWALK;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Code Crosswalk ===== */
ods excel close;

%symdel SF_KEY_PWD / nowarn;
/*---------------------------------------------*/

/* Final report completion check for ACO_REBUILD_Run.sh.
   Reaching QC email alone does not prove main report completion.
   SYSCC 0 or 4 allows warning-only runs; the launcher also scans the log.
*/
%macro U_VERIFY_RUN_COMPLETE;
    %if %sysevalf(&syscc > 4) %then %do;
        %put ERROR: Upgrade completion check failed. SYSCC=&syscc.;
        %abort cancel;
    %end;
    data _null_;
        length output_path $1024;
        do output_index=1 to 2;
            if output_index=1 then output_path=symget('OUTFILE');
            else output_path=symget('QCFILE');
            assign_rc=filename('UPGCHK',strip(output_path));
            file_id=0;
            if assign_rc=0 then file_id=fopen('UPGCHK','I',1,'B');
            if file_id>0 then do;
                read_rc=fread(file_id);
                close_rc=fclose(file_id);
            end;
            else read_rc=1;
            clear_rc=filename('UPGCHK');
            if read_rc ne 0 then do;
                put 'ERROR: Upgrade output missing, unreadable, or empty: ' output_path;
                abort cancel;
            end;
        end;
    run;
    %if &syserr > 4 %then %do;
        %put ERROR: Upgrade output verification did not complete.;
        %abort cancel;
    %end;
    proc export data=data.QC_Current_Matrix outfile="&U_RUN_DIR./QC_Current_Matrix.csv" dbms=csv replace; run;
    %if &syserr > 4 %then %abort cancel;
    proc export data=data.QC_Check_Matrix outfile="&U_RUN_DIR./QC_Check_Matrix.csv" dbms=csv replace; run;
    %if &syserr > 4 %then %abort cancel;
    proc export data=data.QC_Summary outfile="&U_RUN_DIR./QC_Summary.csv" dbms=csv replace; run;
    %if &syserr > 4 %then %abort cancel;
    proc export data=data.current_run_validation_final outfile="&U_RUN_DIR./Freshness.csv" dbms=csv replace; run;
    %if &syserr > 4 %then %abort cancel;
    %if %sysevalf(&syscc > 4) %then %abort cancel;
    data _null_;
        file "&U_RUN_DIR./TECHNICAL_COMPLETE.txt";
        put "RunID=&U_RUN_ID.";
        put "ReportDate=&repdt.";
        put "QCStatus=&QC_STATUS.";
        put "DistributionDecision=&DISTRIBUTION_DECISION.";
        put "REGXSA=&OUTFILE.";
        put "SASQA=&QCFILE.";
    run;
    %if &syserr > 4 %then %abort cancel;
    %put NOTE: ACO_REBUILD_RUN_COMPLETE REPDT=&repdt. RUNID=&U_RUN_ID.;
%mend U_VERIFY_RUN_COMPLETE;
%U_VERIFY_RUN_COMPLETE;
