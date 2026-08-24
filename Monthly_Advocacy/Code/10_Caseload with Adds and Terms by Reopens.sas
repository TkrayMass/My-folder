/*===============================================================
  Monthly Advocacy Report
  PROC 10 - Caseload with Adds and Terms by Reopens
  Dynamic Production Version v1

  PURPOSE
    Build the monthly Caseload with Adds and Terms by Reopens
    report using validated dynamic production inputs while
    preserving the inherited production business logic.

  VALIDATION STATUS
    PROC 10 passed decisive validation under current source
    conditions:
      Reference Differences = 0
      Dynamic Differences   = 0
      STATUS                = PROC 10 LOGIC PASS

  PRODUCTION INPUTS
    PROC 0 Dynamic Eligibility:
      MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

    PROC 1 Adds / Reopens:
      DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV4_DYN

    PROC 5 Terms:
      DYN.ADV_&REPORT_YYYYMM._TERMS_DYN

  PRODUCTION OUTPUT
    SAS dataset:
      DYN.ADV_&REPORT_YYYYMM._REOPENS_V10_DYN

    Excel:
      &ADV_OUTPUT./&OUTPUT_FOLDER./
      caseload_with_adds_and_terms_by_reopens_&REPORT_YYYYMM.v10.xlsx

  IMPORTANT
    The inherited program aligns TOTALS, ADDS, and the monthly
    total TERMS row by a sequential variable K rather than by
    CURRMONTH. This production version preserves that behavior
    exactly because it is part of the validated inherited design.

  SAFETY
    - Does not overwrite legacy KP SAS datasets.
    - Uses validated dynamic production upstream datasets.
================================================================*/


/*===============================================================
  1. Shared project settings
================================================================*/
%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options compress=yes
        fullstimer
        mprint
        mlogic
        symbolgen
        source
        source2;


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
             PRIV_KEY_FILE_PWD=Kta#93574#yHRre"
    readbuff=32767
    insertbuff=32767;


/*===============================================================
  3. Production input / output names
================================================================*/
%let PROC10_ADDS =
    DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV4_DYN;

%let PROC10_TERMS =
    DYN.ADV_&REPORT_YYYYMM._TERMS_DYN;

%let PROC10_OUTPUT =
    DYN.ADV_&REPORT_YYYYMM._REOPENS_V10_DYN;

%let PROC10_XLSX =
    &ADV_OUTPUT./&OUTPUT_FOLDER./caseload_with_adds_and_terms_by_reopens_&REPORT_YYYYMM.v10.xlsx;


/*===============================================================
  4. Validate required upstream production datasets
================================================================*/
%macro proc10_check_inputs;

    %if not %sysfunc(exist(&PROC10_ADDS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 10 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 1 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC10_ADDS;
        %put ERROR: RUN/VERIFY PROC 1 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;


    %if not %sysfunc(exist(&PROC10_TERMS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 10 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 5 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC10_TERMS;
        %put ERROR: RUN/VERIFY PROC 5 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;

%mend proc10_check_inputs;

%proc10_check_inputs;


/*===============================================================
  5. Pull monthly totals from dynamic PROC 0

  Preserve inherited business logic:
    - Exclude BG 99, 87, 44
    - One row per YR_MTH
================================================================*/
proc sql;

    connect using mhdwprod;

    execute (USE DATABASE MHUSER) by mhdwprod;
    execute (USE SCHEMA KRAYT) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

    create table work.proc10_totals as

    select *
    from connection to mhdwprod
    (
        select
            yr_mth,
            count(*) as members

        from MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

        where cde_budget_group not in ('99','87','44')

        group by yr_mth

        order by yr_mth
    );

    disconnect from mhdwprod;

quit;


/*===============================================================
  6. Adds / Reopens
================================================================*/
data work.proc10_adds;

    set &PROC10_ADDS;

    k + 1;

run;


/*===============================================================
  7. Terms

  Preserve inherited subset exactly:

      if dsc_elig_stop =:' ' ;

  This keeps the blank DSC_ELIG_STOP monthly total row.
================================================================*/
data work.proc10_terms;

    set &PROC10_TERMS;

    if currmonth = . then delete;

    if dsc_elig_stop =:' ';

    k + 1;

run;


/*===============================================================
  8. Preserve inherited historical cutoff for totals
================================================================*/
data work.proc10_totals;

    set work.proc10_totals;

    if yr_mth <= 201403 then delete;

run;


/*===============================================================
  9. Add inherited sequential key K to totals
================================================================*/
data work.proc10_totals;

    set work.proc10_totals;

    k + 1;

run;


/*===============================================================
 10. Build permanent dynamic production dataset

  Preserve inherited positional K merge exactly.
================================================================*/
data &PROC10_OUTPUT;

    merge

        work.proc10_totals
        (
            rename=(
                members = total
                yr_mth  = currmonth
            )
        )

        work.proc10_adds
        (
            rename=(
                yr_mth = currmonth
            )
        )

        work.proc10_terms
        (
            rename=(
                members = terms
            )
        );

    by k;


    nextmonth =
        total
        + openings
        - terms;


    if currmonth = . then delete;

run;


/*===============================================================
 11. Production QC - complete output
================================================================*/
proc sql;

    title "PROC 10 Dynamic Production QC";

    select
        count(*)       as row_count,
        min(currmonth) as first_month,
        max(currmonth) as last_month,
        sum(total)     as total_caseload,
        sum(openings)  as total_openings,
        sum(terms)     as total_terms

    from &PROC10_OUTPUT
    ;

quit;

title;


/*===============================================================
 12. Current reporting month QC
================================================================*/
proc sql;

    create table work.proc10_current_month as

    select *
    from &PROC10_OUTPUT

    where currmonth = &REPORT_YYYYMM
    ;

quit;


proc sql noprint;

    select count(*)
    into :PROC10_CURRENT_ROWS trimmed

    from work.proc10_current_month;

quit;


%if &PROC10_CURRENT_ROWS = 0 %then %do;

    %put ============================================================;
    %put ERROR: PROC 10 PRODUCTION FAILED.;
    %put ERROR: NO ROWS FOUND FOR REPORT MONTH &REPORT_YYYYMM.;
    %put ERROR: EXCEL FILE WAS NOT EXPORTED.;
    %put ============================================================;

    %abort cancel;

%end;


proc sql;

    title "PROC 10 Current Reporting Month QC";

    select
        count(*)       as current_month_rows,
        min(currmonth) as current_month,
        max(currmonth) as current_month_max,
        sum(total)     as current_month_total,
        sum(openings)  as current_month_openings,
        sum(terms)     as current_month_terms,
        sum(nextmonth) as current_month_nextmonth

    from work.proc10_current_month
    ;

quit;

title;


/*===============================================================
 13. Export production Excel workbook

  Preserves inherited filename convention.
================================================================*/
proc export
    data=&PROC10_OUTPUT
        (drop=k)
    outfile="&PROC10_XLSX"
    dbms=xlsx
    replace;
run;


/*===============================================================
 14. Completion message
================================================================*/
%put ============================================================;
%put PROC 10 DYNAMIC PRODUCTION FINISHED SUCCESSFULLY;
%put REPORT MONTH=&REPORT_YYYYMM;
%put ;
%put PROC 0 INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
%put PROC 1 INPUT=&PROC10_ADDS;
%put PROC 5 INPUT=&PROC10_TERMS;
%put ;
%put OUTPUT=&PROC10_OUTPUT;
%put CURRENT MONTH ROWS=&PROC10_CURRENT_ROWS;
%put EXCEL=&PROC10_XLSX;
%put ============================================================;
