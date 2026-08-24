/*===============================================================
  Monthly Advocacy Report
  PROC 7 - Caseload with Adds and Terms by Reopens
  Dynamic Production Version v1

  PURPOSE
    Build the Caseload with Adds and Terms by Reopens output
    dynamically for the current reporting cycle.

  VALIDATION STATUS
    PROC 7 logic has been validated.

    Production-input rerun matched the Dynamic TEST exactly.

    Differences versus the stored July 2026 production workbook
    were confirmed to be inherited source-data / live lookup drift,
    not a PROC 7 logic error.

  INPUTS

    PROC 0 dynamic Snowflake table:
      MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

    PROC 2 validated dynamic production dataset:
      DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN

    PROC 6 validated dynamic production dataset:
      DYN.ADV_&REPORT_YYYYMM._TERMS_BG_DYN

  OUTPUT
      DYN.ADV_&REPORT_YYYYMM._CASELOAD_REOPENS_DYN

  BUSINESS LOGIC
    Preserves the inherited PROC 7 logic exactly.

  SAFETY
    - Does NOT overwrite legacy KP production datasets.
    - Uses only validated dynamic upstream datasets.
    - Writes permanent result only to Advocacy_Dynamic/Data.
================================================================*/


/*===============================================================
  1. Shared project settings
================================================================*/
%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options compress=yes;


/*===============================================================
  2. Libraries / Snowflake
================================================================*/
libname dyn
    "/sas_mass_health/shared/Advocacy_Dynamic/Data";

libname mhdwprod snow
    datasrc=MHDWPROD
    database=MHUSER
    schema=KRAYT
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="AUTHENTICATOR=SNOWFLAKE_JWT;
             PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
             PRIV_KEY_FILE_PWD=Kta#93574#yHRre";


/*===============================================================
  3. Dynamic production input / output names
================================================================*/
%let PROC7_ADDS =
    DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN;

%let PROC7_TERMS =
    DYN.ADV_&REPORT_YYYYMM._TERMS_BG_DYN;

%let PROC7_OUTPUT =
    DYN.ADV_&REPORT_YYYYMM._CASELOAD_REOPENS_DYN;


/*===============================================================
  4. Validate required upstream datasets
================================================================*/
%macro proc7_validate_inputs;

    %if not %sysfunc(exist(&PROC7_ADDS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 7 DYNAMIC FAILED.;
        %put ERROR: REQUIRED PROC 2 DATASET DOES NOT EXIST:;
        %put ERROR: &PROC7_ADDS;
        %put ERROR: PROC 7 WAS NOT RUN.;
        %put ============================================================;

        %abort cancel;

    %end;


    %if not %sysfunc(exist(&PROC7_TERMS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 7 DYNAMIC FAILED.;
        %put ERROR: REQUIRED PROC 6 DATASET DOES NOT EXIST:;
        %put ERROR: &PROC7_TERMS;
        %put ERROR: PROC 7 WAS NOT RUN.;
        %put ============================================================;

        %abort cancel;

    %end;

%mend proc7_validate_inputs;

%proc7_validate_inputs;


/*===============================================================
  5. Pull eligibility totals from validated PROC 0 dynamic table

  Inherited business rule:
    - Count members by month and budget group
    - Exclude budget groups 99, 44, and 87
================================================================*/
proc sql;

    connect using mhdwprod;

    execute (USE DATABASE MHUSER) by mhdwprod;
    execute (USE SCHEMA KRAYT) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;


    create table work.proc7_totals as

    select *
    from connection to mhdwprod
    (
        select
            yr_mth,
            cde_budget_group,
            count(*) as members

        from MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

        where cde_budget_group not in ('99','44','87')

        group by
            yr_mth,
            cde_budget_group

        order by
            yr_mth,
            cde_budget_group
    );


    disconnect from mhdwprod;

quit;


/*===============================================================
  6. Copy validated PROC 2 dynamic production Adds
================================================================*/
data work.proc7_adds;

    set &PROC7_ADDS;

run;


/*===============================================================
  7. Copy validated PROC 6 dynamic production Terms
================================================================*/
data work.proc7_terms;

    set &PROC7_TERMS;

run;


/*===============================================================
  8. Preserve inherited historical cutoff
================================================================*/
data work.proc7_totals;

    set work.proc7_totals;

    if yr_mth <= 201403 then delete;

run;


/*===============================================================
  9. Sort all inputs
================================================================*/
proc sort data=work.proc7_totals;
    by yr_mth cde_budget_group;
run;

proc sort data=work.proc7_adds;
    by yr_mth cde_budget_group;
run;

proc sort data=work.proc7_terms;
    by yr_mth cde_budget_group;
run;


/*===============================================================
 10. Rebuild final PROC 7 output

     Preserve inherited production logic exactly.
================================================================*/
data &PROC7_OUTPUT;

    merge

        work.proc7_totals
        (
            rename=(
                members = total
                yr_mth  = currmonth
            )
        )

        work.proc7_adds
        (
            rename=(
                yr_mth = currmonth
            )
        )

        work.proc7_terms
        (
            rename=(
                yr_mth   = currmonth
                closings = terms
            )
        );

    by currmonth cde_budget_group;


    /*-----------------------------------------------------------
      Inherited calculation
    -----------------------------------------------------------*/
    nextmonth = total + openings - terms;


    /*-----------------------------------------------------------
      Inherited historical restriction
    -----------------------------------------------------------*/
    if currmonth = . or currmonth < 201405 then delete;


    /*-----------------------------------------------------------
      Inherited missing-value handling
    -----------------------------------------------------------*/
    if new_hxwin3 = . then new_hxwin3 = 0;
    if new_hxwin5 = . then new_hxwin5 = 0;
    if new        = . then new        = 0;


    /*-----------------------------------------------------------
      Inherited final measure
    -----------------------------------------------------------*/
    new_members =
          new_hxwin3
        + new_hxwin5
        + new;


    keep
        currmonth
        cde_budget_group
        new_members;

run;


/*===============================================================
 11. Sort permanent dynamic output
================================================================*/
proc sort data=&PROC7_OUTPUT;

    by currmonth cde_budget_group;

run;


/*===============================================================
 12. Current reporting month
================================================================*/
data work.proc7_current_month;

    set &PROC7_OUTPUT;

    where currmonth = &REPORT_YYYYMM;

run;


/*===============================================================
 13. Validate current month exists
================================================================*/
proc sql noprint;

    select count(*)
    into :PROC7_CURRENT_ROWS trimmed

    from work.proc7_current_month;

quit;


%if &PROC7_CURRENT_ROWS = 0 %then %do;

    %put ============================================================;
    %put ERROR: PROC 7 DYNAMIC FAILED.;
    %put ERROR: NO ROWS FOUND FOR REPORT MONTH &REPORT_YYYYMM.;
    %put ERROR: FINAL EXCEL EXPORT WAS NOT CREATED.;
    %put ============================================================;

    %abort cancel;

%end;


/*===============================================================
 14. Dynamic QC
================================================================*/
proc sql;

    title "PROC 7 Caseload with Adds and Terms by Reopens - Dynamic QC";

    select
        count(*)          as row_count,
        min(currmonth)    as first_month,
        max(currmonth)    as last_month,
        sum(new_members)  as total_new_members

    from &PROC7_OUTPUT;


    title "PROC 7 Current Reporting Month QC";

    select
        count(*)          as current_month_rows,
        min(currmonth)    as current_month,
        max(currmonth)    as current_month_max,
        sum(new_members)  as current_month_new_members

    from work.proc7_current_month;

quit;

title;


/*===============================================================
 15. Export final reporting workbook

  Preserve inherited output naming convention:
    caseload_with_adds_and_terms_by_reopens_YYYYMMwbgorigv5.xlsx
================================================================*/
%let PROC7_XLSX=
&ADV_OUTPUT/&OUTPUT_FOLDER./caseload_with_adds_and_terms_by_reopens_&REPORT_YYYYMM.wbgorigv5.xlsx;


proc export
    data=&PROC7_OUTPUT
    outfile="&PROC7_XLSX"
    dbms=xlsx
    replace;
run;


/*===============================================================
 16. Completion message
================================================================*/
%put ============================================================;
%put PROC 7 DYNAMIC PRODUCTION FINISHED SUCCESSFULLY;
%put REPORT MONTH=&REPORT_YYYYMM;
%put ;
%put PROC 0 INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
%put PROC 2 INPUT=&PROC7_ADDS;
%put PROC 6 INPUT=&PROC7_TERMS;
%put ;
%put OUTPUT=&PROC7_OUTPUT;
%put CURRENT MONTH ROWS=&PROC7_CURRENT_ROWS;
%put EXCEL=&PROC7_XLSX;
%put ============================================================;