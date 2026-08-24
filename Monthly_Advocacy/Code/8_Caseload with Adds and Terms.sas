/*===============================================================
  Monthly Advocacy Report
  PROC 8 - Caseload with Adds and Terms
  Dynamic Production Version v1

  PURPOSE
    Build the monthly Caseload with Adds and Terms report using
    validated dynamic production inputs while preserving the
    inherited production business logic.

  VALIDATION STATUS
    PROC 8 Dynamic TEST matched the stored July 2026 production
    control exactly:
      Production Differences = 0
      Dynamic Differences    = 0

  PRODUCTION INPUTS
    PROC 0 Dynamic Eligibility:
      MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

    PROC 3 New Eligibility by Agency:
      DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN

    PROC 5 New Terminations:
      DYN.ADV_&REPORT_YYYYMM._TERMS_DYN

  PRODUCTION OUTPUT
    SAS dataset:
      DYN.ADV_&REPORT_YYYYMM._CASELOAD_AT_DYN

    CSV:
      &ADV_OUTPUT./&OUTPUT_FOLDER./
      caseload_with_adds_and_terms_&REPORT_YYYYMM._v3.csv

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
%let PROC8_ADDS =
    DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN;

%let PROC8_TERMS =
    DYN.ADV_&REPORT_YYYYMM._TERMS_DYN;

%let PROC8_OUTPUT =
    DYN.ADV_&REPORT_YYYYMM._CASELOAD_AT_DYN;

%let PROC8_CSV =
    &ADV_OUTPUT./&OUTPUT_FOLDER./caseload_with_adds_and_terms_&REPORT_YYYYMM._v3.csv;


/*===============================================================
  4. Validate required upstream production datasets
================================================================*/
%macro proc8_check_inputs;

    %if not %sysfunc(exist(&PROC8_ADDS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 8 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 3 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC8_ADDS;
        %put ERROR: RUN/VERIFY PROC 3 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;


    %if not %sysfunc(exist(&PROC8_TERMS)) %then %do;

        %put ============================================================;
        %put ERROR: PROC 8 PRODUCTION STOPPED.;
        %put ERROR: REQUIRED PROC 5 PRODUCTION DATASET DOES NOT EXIST:;
        %put ERROR: &PROC8_TERMS;
        %put ERROR: RUN/VERIFY PROC 5 PRODUCTION FIRST.;
        %put ============================================================;

        %abort cancel;

    %end;

%mend proc8_check_inputs;

%proc8_check_inputs;


/*===============================================================
  5. Pull monthly caseload totals from dynamic PROC 0
================================================================*/
proc sql;

    connect using mhdwprod;

    execute (USE DATABASE MHUSER) by mhdwprod;
    execute (USE SCHEMA KRAYT) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

    create table work.proc8_totals as

    select *
    from connection to mhdwprod
    (
        select
            yr_mth,
            count(*) as members

        from MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

        where cde_budget_group not in ('99','44','87')

        group by yr_mth

        order by yr_mth
    );

    disconnect from mhdwprod;

quit;


/*===============================================================
  6. Adds / Agency input
================================================================*/
data work.proc8_adds;

    set &PROC8_ADDS;

run;


/*===============================================================
  7. Summarize Adds by month and agency
================================================================*/
proc summary
    data=work.proc8_adds
         (where=(not(agency=:' ')))
    nway
    missing;

    class currmonth agency;
    var members;

    output
        out=work.proc8_summadds
            (drop=_TYPE_ _FREQ_)
        sum=members;

run;


/*===============================================================
  8. Total Adds by month
================================================================*/
proc summary
    data=work.proc8_summadds
    nway
    missing;

    class currmonth;
    var members;

    output
        out=work.proc8_subtotadds
            (drop=_TYPE_ _FREQ_)
        sum=members;

run;


/*===============================================================
  9. Terms input
================================================================*/
data work.proc8_terms;

    set &PROC8_TERMS;

    if currmonth = . then delete;

    if dsc_elig_stop =:' ' then delete;

run;


/*===============================================================
 10. Total Terms by month
================================================================*/
proc summary
    data=work.proc8_terms
    nway
    missing;

    class currmonth;
    var members;

    output
        out=work.proc8_subtotterms
            (drop=_TYPE_ _FREQ_)
        sum=members;

run;


/*===============================================================
 11. Prepare caseload totals
================================================================*/
data work.proc8_totals;

    set work.proc8_totals;

    if yr_mth < 201405 then delete;

    currmonth = yr_mth;

    drop yr_mth;

run;


/*===============================================================
 12. Agency Adds split

  INHERITED BUSINESS LOGIC:
    Agency begins H -> HIX_ADDS
    Agency begins M -> MHO_ADDS
    Everything else -> REFERRED_ADDS
================================================================*/
data work.proc8_summadds2;

    set work.proc8_summadds;

    hix_adds      = 0;
    mho_adds      = 0;
    referred_adds = 0;

    if agency =: 'H' then
        hix_adds = members;

    else if agency =: 'M' then
        mho_adds = members;

    else
        referred_adds = members;

run;


/*===============================================================
 13. Summarize Agency Adds to one row per month
================================================================*/
proc summary
    data=work.proc8_summadds2
    nway
    missing;

    class currmonth;

    var
        hix_adds
        mho_adds
        referred_adds;

    output
        out=work.proc8_agency_adds
            (drop=_TYPE_ _FREQ_)
        sum=;

run;


/*===============================================================
 14. Sort all merge inputs
================================================================*/
proc sort data=work.proc8_totals;
    by currmonth;
run;

proc sort data=work.proc8_agency_adds;
    by currmonth;
run;

proc sort data=work.proc8_subtotadds;
    by currmonth;
run;

proc sort data=work.proc8_subtotterms;
    by currmonth;
run;


/*===============================================================
 15. Final monthly output

  INHERITED FORMULA:
    NEXTMONTH = TOTAL + TOTAL_ADDS - TERMS
================================================================*/
data work.proc8_final;

    merge

        work.proc8_totals
            (rename=(members=total))

        work.proc8_agency_adds

        work.proc8_subtotadds
            (rename=(members=total_adds))

        work.proc8_subtotterms
            (rename=(members=terms));

    by currmonth;

    if currmonth = . then delete;


    if missing(total) then
        total = 0;

    if missing(hix_adds) then
        hix_adds = 0;

    if missing(mho_adds) then
        mho_adds = 0;

    if missing(referred_adds) then
        referred_adds = 0;

    if missing(total_adds) then
        total_adds = 0;

    if missing(terms) then
        terms = 0;


    nextmonth =
        total
        + total_adds
        - terms;

run;


/*===============================================================
 16. Ensure one row per month
================================================================*/
proc sort
    data=work.proc8_final
    out=work.proc8_finals
    nodupkey;

    by currmonth;

run;


/*===============================================================
 17. Transpose to inherited report layout
================================================================*/
proc transpose
    data=work.proc8_finals
    out=work.proc8_tranfinal;

    by currmonth;

    var
        total
        hix_adds
        mho_adds
        referred_adds
        total_adds
        terms
        nextmonth;

run;


/*===============================================================
 18. Save permanent dynamic production dataset
================================================================*/
data &PROC8_OUTPUT;

    set work.proc8_tranfinal;

    members = col1;

    keep
        currmonth
        _NAME_
        members;

run;


proc sort data=&PROC8_OUTPUT;

    by currmonth _NAME_;

run;


/*===============================================================
 19. Current reporting month QC
================================================================*/
proc sql;

    create table work.proc8_current_month as

    select *
    from &PROC8_OUTPUT

    where currmonth = &REPORT_YYYYMM
    ;

quit;


proc sql noprint;

    select count(*)
    into :PROC8_CURRENT_ROWS trimmed

    from work.proc8_current_month;

quit;


%if &PROC8_CURRENT_ROWS = 0 %then %do;

    %put ============================================================;
    %put ERROR: PROC 8 PRODUCTION FAILED.;
    %put ERROR: NO ROWS FOUND FOR REPORT MONTH &REPORT_YYYYMM.;
    %put ERROR: CSV WAS NOT EXPORTED.;
    %put ============================================================;

    %abort cancel;

%end;


/*===============================================================
 20. Production QC
================================================================*/
proc sql;

    title "PROC 8 Dynamic Production QC";

    select
        count(*)       as row_count,
        min(currmonth) as first_month,
        max(currmonth) as last_month,
        sum(members)   as total_members

    from &PROC8_OUTPUT
    ;


    title "PROC 8 Current Reporting Month QC";

    select
        count(*)       as current_month_rows,
        min(currmonth) as current_month,
        max(currmonth) as current_month_max,
        sum(members)   as current_month_total_members

    from work.proc8_current_month
    ;

quit;

title;


/*===============================================================
 21. Export production CSV

  Preserves inherited filename convention.
================================================================*/
proc export
    data=&PROC8_OUTPUT
    outfile="&PROC8_CSV"
    dbms=csv
    replace;
run;


/*===============================================================
 22. Completion message
================================================================*/
%put ============================================================;
%put PROC 8 DYNAMIC PRODUCTION FINISHED SUCCESSFULLY;
%put REPORT MONTH=&REPORT_YYYYMM;
%put ;
%put PROC 0 INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
%put PROC 3 INPUT=&PROC8_ADDS;
%put PROC 5 INPUT=&PROC8_TERMS;
%put ;
%put OUTPUT=&PROC8_OUTPUT;
%put CURRENT MONTH ROWS=&PROC8_CURRENT_ROWS;
%put CSV=&PROC8_CSV;
%put ============================================================;
