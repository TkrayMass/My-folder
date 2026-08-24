/*===============================================================
  Monthly Advocacy Report
  PROC 9 - Caseload with Adds and Terms by Budget Group
  Dynamic Production Version v1

  PURPOSE
    Build the monthly Caseload with Adds and Terms by Budget Group
    report using validated dynamic production inputs while
    preserving the inherited production business logic.

  VALIDATION STATUS
    PROC 9 Dynamic TEST matched the stored July 2026 production
    control exactly:
      Production Differences = 0
      Dynamic Differences    = 0
      STATUS                 = PASS

  PRODUCTION INPUTS
    PROC 0 Dynamic Eligibility:
      MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

    PROC 4 Adds by Budget Group:
      DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN

    PROC 6 Terms by Budget Group:
      DYN.ADV_&REPORT_YYYYMM._TERMS_BG_DYN

  PRODUCTION OUTPUT
    SAS dataset:
      DYN.ADV_&REPORT_YYYYMM._CASELOAD_BG_DYN

    Excel:
      &ADV_OUTPUT./&OUTPUT_FOLDER./
      caseload_with_adds_and_terms_by_BGs_&REPORT_YYYYMM._v1.xlsx

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
%let PROC9_ADDS =
    DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN;

%let PROC9_TERMS =
    DYN.ADV_&REPORT_YYYYMM._TERMS_BG_DYN;

%let PROC9_OUTPUT =
    DYN.ADV_&REPORT_YYYYMM._CASELOAD_BG_DYN;

%let PROC9_XLSX =
    &ADV_OUTPUT./&OUTPUT_FOLDER./caseload_with_adds_and_terms_by_BGs_&REPORT_YYYYMM._v1.xlsx;


/*===============================================================
  4. Validate required upstream production datasets
================================================================*/
%macro proc9_check_inputs;

    %if not %sysfunc(exist(&PROC9_ADDS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 9 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 4 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC9_ADDS;
        %put ERROR: RUN/VERIFY PROC 4 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;


    %if not %sysfunc(exist(&PROC9_TERMS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 9 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 6 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC9_TERMS;
        %put ERROR: RUN/VERIFY PROC 6 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;

%mend proc9_check_inputs;

%proc9_check_inputs;


/*===============================================================
  5. Pull monthly totals from dynamic PROC 0

  Preserve inherited logic:
    - Exclude BG 99, 44, 87
    - Shift YR_MTH forward one month into CURRMONTH
================================================================*/
proc sql;

    connect using mhdwprod;

    execute (USE DATABASE MHUSER) by mhdwprod;
    execute (USE SCHEMA KRAYT) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

    create table work.proc9_totals as

    select *
    from connection to mhdwprod
    (
        select
            yr_mth,

            to_number(
                to_char(
                    add_months(
                        to_date(cast(yr_mth as varchar), 'yyyymm'),
                        1
                    ),
                    'yyyymm'
                )
            ) as currmonth,

            count(*) as members

        from MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

        where cde_budget_group not in ('99','44','87')

        group by
            yr_mth,
            to_number(
                to_char(
                    add_months(
                        to_date(cast(yr_mth as varchar), 'yyyymm'),
                        1
                    ),
                    'yyyymm'
                )
            )

        order by yr_mth
    );

    disconnect from mhdwprod;

quit;


/*===============================================================
  6. Adds by Budget Group
================================================================*/
data work.proc9_adds;

    set &PROC9_ADDS;

run;


/*===============================================================
  7. Terms by Budget Group
================================================================*/
data work.proc9_terms;

    set &PROC9_TERMS;

run;


/*===============================================================
  8. Preserve inherited historical cutoff
================================================================*/
data work.proc9_totals;

    set work.proc9_totals;

    if yr_mth <= 201403 then delete;

run;


data work.proc9_totals2;

    set work.proc9_totals;

run;


/*===============================================================
  9. Summarize Adds by month
================================================================*/
proc summary
    data=work.proc9_adds
    nway
    missing;

    class yr_mth;
    var openings;

    output
        out=work.proc9_summadds
        sum=total_adds;

run;


/*===============================================================
 10. Summarize Terms by month
================================================================*/
proc summary
    data=work.proc9_terms
    nway
    missing;

    class yr_mth;
    var closings;

    output
        out=work.proc9_summterms
        sum=total_terms;

run;


/*===============================================================
 11. Sort stacked inputs
================================================================*/
proc sort data=work.proc9_totals2;
    by currmonth;
run;

proc sort data=work.proc9_adds;
    by yr_mth cde_budget_group;
run;

proc sort data=work.proc9_summadds;
    by yr_mth;
run;

proc sort data=work.proc9_terms;
    by yr_mth cde_budget_group;
run;

proc sort data=work.proc9_summterms;
    by yr_mth;
run;


/*===============================================================
 12. Build permanent dynamic production dataset

  Preserve inherited SET structure and TYPE labels exactly.
================================================================*/
data &PROC9_OUTPUT;

    length type $20.;

    set
        work.proc9_totals2
            (in=n
             drop=yr_mth)

        work.proc9_adds
            (in=a
             rename=(
                 yr_mth   = currmonth
                 openings = members
             ))

        work.proc9_summadds
            (in=sa
             rename=(
                 yr_mth     = currmonth
                 total_adds = members
             ))

        work.proc9_terms
            (in=t
             rename=(
                 yr_mth   = currmonth
                 closings = members
             ))

        work.proc9_summterms
            (in=st
             rename=(
                 yr_mth      = currmonth
                 total_terms = members
             ));

    by currmonth;


    if n  then type = 'Total';
    if a  then type = 'Openings';
    if t  then type = 'Closings';
    if sa then type = 'Total Adds';
    if st then type = 'Total Terms';


    drop _:;

run;


/*===============================================================
 13. Sort permanent output
================================================================*/
proc sort data=&PROC9_OUTPUT;

    by currmonth type cde_budget_group members;

run;


/*===============================================================
 14. Current reporting month QC
================================================================*/
proc sql;

    create table work.proc9_current_month as

    select *
    from &PROC9_OUTPUT

    where currmonth = &REPORT_YYYYMM
    ;

quit;


proc sql noprint;

    select count(*)
    into :PROC9_CURRENT_ROWS trimmed

    from work.proc9_current_month;

quit;


%if &PROC9_CURRENT_ROWS = 0 %then %do;

    %put ============================================================;
    %put ERROR: PROC 9 PRODUCTION FAILED.;
    %put ERROR: NO ROWS FOUND FOR REPORT MONTH &REPORT_YYYYMM.;
    %put ERROR: EXCEL FILE WAS NOT EXPORTED.;
    %put ============================================================;

    %abort cancel;

%end;


/*===============================================================
 15. Production QC
================================================================*/
proc sql;

    title "PROC 9 Dynamic Production QC";

    select
        count(*)       as row_count,
        min(currmonth) as first_month,
        max(currmonth) as last_month,
        sum(members)   as total_members

    from &PROC9_OUTPUT
    ;


    title "PROC 9 Current Reporting Month QC";

    select
        count(*)       as current_month_rows,
        min(currmonth) as current_month,
        max(currmonth) as current_month_max,
        sum(members)   as current_month_total_members

    from work.proc9_current_month
    ;

quit;

title;


/*===============================================================
 16. Export production Excel workbook

  Preserves inherited filename convention.
================================================================*/
proc export
    data=&PROC9_OUTPUT
    outfile="&PROC9_XLSX"
    dbms=xlsx
    replace;
run;


/*===============================================================
 17. Completion message
================================================================*/
%put ============================================================;
%put PROC 9 DYNAMIC PRODUCTION FINISHED SUCCESSFULLY;
%put REPORT MONTH=&REPORT_YYYYMM;
%put ;
%put PROC 0 INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
%put PROC 4 INPUT=&PROC9_ADDS;
%put PROC 6 INPUT=&PROC9_TERMS;
%put ;
%put OUTPUT=&PROC9_OUTPUT;
%put CURRENT MONTH ROWS=&PROC9_CURRENT_ROWS;
%put EXCEL=&PROC9_XLSX;
%put ============================================================;
