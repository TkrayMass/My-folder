/*===============================================================
  Monthly Advocacy Report
  PROC 4 - New Eligibility by Budget Group
  Dynamic Production Version v1

  PURPOSE
    Rebuild the historical New Eligibility by Budget Group report
    from May 2014 through the current reporting month using the
    validated dynamic Proc 0 eligibility table.

  VALIDATION
    Production baseline:
      KP.MONTHLY_ADV_202607_ADDS_WBG

    Promote this version after the TEST version passes QC with:
      Production Differences = 0
      Dynamic Differences    = 0
      STATUS = PASS

  INPUT
    MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

  OUTPUT
    DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN

  CURRENT-MONTH DISTRIBUTION FILE
    new_eligibility - <mon yyyy> w bg.xlsx

  HISTORY
    May 2014 through &REPORT_YYYYMM

  BUSINESS LOGIC
    For each month:
      Current-month members
      MINUS
      Prior-month members
    excluding budget groups 99, 44, and 87,
    then count openings by current-month budget group.

  DESIGN
    - Replaces inherited hard-coded monthly calls with one loop.
    - Uses shared 00_Project_Settings.sas.
    - Does NOT overwrite KP production datasets.
    - Rebuilds the permanent dynamic history from scratch.
    - Exports only the current reporting month after completion.
================================================================*/


/*===============================================================
  1. Shared project settings
================================================================*/
%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options compress=yes;


/*===============================================================
  2. Snowflake connection
================================================================*/
libname mhdwprod snow
    datasrc=MHDWPROD
    database=MHUSER
    schema=KRAYT
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="AUTHENTICATOR=SNOWFLAKE_JWT;
             PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
             PRIV_KEY_FILE_PWD=Kta#93574#yHRre";


/*===============================================================
  3. Proc 4 business logic
================================================================*/
%macro eligstop(dout, priormonth, currmonth, din);

    proc sql;
        connect using mhdwprod;

        execute (USE DATABASE mhdwprod) by mhdwprod;
        execute (USE SCHEMA NW) by mhdwprod;
        execute (USE WAREHOUSE MHA_WH) by mhdwprod;
        execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

        create table &dout as
        select *
        from connection to mhdwprod
        (
            select
                cde_budget_group,
                yr_mth,
                count(*) as openings
            from
            (
                select
                    pop.id_medicaid,
                    &currmonth as yr_mth,
                    b.cde_budget_group

                from
                (
                    select id_medicaid
                    from &din
                    where yr_mth = &currmonth
                      and cde_budget_group not in ('99','44','87')

                    minus

                    select id_medicaid
                    from &din
                    where yr_mth = &priormonth
                      and cde_budget_group not in ('99','44','87')
                ) pop

                inner join &din b
                    on pop.id_medicaid = b.id_medicaid
                   and &currmonth = b.yr_mth
            )

            group by cde_budget_group, yr_mth
            order by cde_budget_group, yr_mth
        );

        disconnect from mhdwprod;
    quit;

%mend eligstop;


/*===============================================================
  4. Full-history production controller
================================================================*/
%macro build_proc4_history;

    %local start_month
           months_to_run
           i
           month_dt
           prior_dt
           currmonth
           priormonth
           din
           first_month;

    %let start_month=%sysfunc(mdy(5,1,2014));

    %let months_to_run=
        %sysfunc(intck(month,&start_month,&REPORT_MONTH_BEGIN));

    %let din=
        MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn";

    %let first_month=1;

    proc datasets library=dyn nolist;
        delete adv_&REPORT_YYYYMM._adds_bg_dyn;
    quit;

    %put ============================================================;
    %put PROC 4 DYNAMIC PRODUCTION REBUILD STARTING;
    %put START MONTH=201405;
    %put END MONTH=&REPORT_YYYYMM;
    %put TOTAL MONTHS=%eval(&months_to_run + 1);
    %put INPUT=&din;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN;
    %put ============================================================;

    %do i=0 %to &months_to_run;

        %let month_dt=
            %sysfunc(intnx(month,&start_month,&i,b));

        %let prior_dt=
            %sysfunc(intnx(month,&month_dt,-1,b));

        %let currmonth=
            %sysfunc(putn(&month_dt,yymmn6.));

        %let priormonth=
            %sysfunc(putn(&prior_dt,yymmn6.));

        %put NOTE: PROC4 DYNAMIC - Processing &currmonth;
        %put NOTE: PRIOR=&priormonth CURRENT=&currmonth;

        proc datasets library=work nolist;
            delete proc4_month;
        quit;

        %eligstop(
            work.proc4_month,
            &priormonth,
            &currmonth,
            &din
        );

        %if not %sysfunc(exist(work.proc4_month)) %then %do;

            %put ERROR: PROC4 DYNAMIC - WORK.PROC4_MONTH was not created for &currmonth.;
            %put ERROR: PROC4 DYNAMIC - Historical rebuild stopped.;

            %return;

        %end;

        %if &first_month=1 %then %do;

            data dyn.adv_&REPORT_YYYYMM._adds_bg_dyn;
                set work.proc4_month;
            run;

            %let first_month=0;

        %end;
        %else %do;

            proc append
                base=dyn.adv_&REPORT_YYYYMM._adds_bg_dyn
                data=work.proc4_month
                force;
            run;

        %end;

    %end;

    proc datasets library=work nolist;
        delete proc4_month;
    quit;

    %put ============================================================;
    %put PROC 4 DYNAMIC PRODUCTION REBUILD COMPLETE;
    %put MONTHS PROCESSED=%eval(&months_to_run + 1);
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN;
    %put ============================================================;

%mend build_proc4_history;

%build_proc4_history;


/*===============================================================
  5. Current-month export and post-build QC
================================================================*/
%macro proc4_finish;

    %local REPORT_MON3
           REPORT_YEAR
           PROC4_XLSX
           current_rows;

    %if not %sysfunc(
        exist(dyn.adv_&REPORT_YYYYMM._adds_bg_dyn)
    ) %then %do;

        %put ============================================================;
        %put ERROR: PROC 4 DYNAMIC FAILED.;
        %put ERROR: DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN DOES NOT EXIST.;
        %put ERROR: CURRENT-MONTH DATASET AND EXCEL EXPORT WERE SKIPPED.;
        %put ============================================================;

        %return;

    %end;

    data work.proc4_current_month;
        set dyn.adv_&REPORT_YYYYMM._adds_bg_dyn;
        where yr_mth = &REPORT_YYYYMM;
    run;

    proc sql noprint;

        select count(*)
        into :current_rows trimmed
        from work.proc4_current_month;

    quit;

    %if &current_rows = 0 %then %do;

        %put ============================================================;
        %put ERROR: PROC 4 DYNAMIC FAILED.;
        %put ERROR: NO ROWS FOUND FOR CURRENT MONTH &REPORT_YYYYMM.;
        %put ERROR: EXCEL EXPORT WAS SKIPPED.;
        %put ============================================================;

        %return;

    %end;

    %let REPORT_MON3=
        %sysfunc(
            lowcase(
                %sysfunc(
                    putn(&REPORT_MONTH_BEGIN,monname3.)
                )
            )
        );

    %let REPORT_YEAR=
        %sysfunc(year(&REPORT_MONTH_BEGIN));

    %let PROC4_XLSX=
/sas_mass_health/shared/Advocacy_Dynamic/Output/&OUTPUT_FOLDER./new_eligibility - &REPORT_MON3 &REPORT_YEAR w bg.xlsx;

    proc export
        data=work.proc4_current_month
        outfile="&PROC4_XLSX"
        dbms=xlsx
        replace;
        sheet="&REPORT_MON3-&REPORT_YEAR";
    run;

    proc sql;

        title "PROC 4 New Eligibility by BG - Dynamic QC";

        select
            count(*) as row_count,
            min(yr_mth) as first_month,
            max(yr_mth) as last_month,
            sum(openings) as total_openings
        from dyn.adv_&REPORT_YYYYMM._adds_bg_dyn;

        title "PROC 4 Current Reporting Month QC";

        select
            count(*) as current_month_rows,
            min(yr_mth) as current_month,
            max(yr_mth) as current_month_max,
            sum(openings) as total_openings
        from work.proc4_current_month;

    quit;

    title;

    %put ============================================================;
    %put PROC 4 DYNAMIC V1 FINISHED SUCCESSFULLY;
    %put INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN;
    %put CURRENT MONTH ROWS=&current_rows;
    %put CURRENT MONTH EXCEL=&PROC4_XLSX;
    %put ============================================================;

%mend proc4_finish;

%proc4_finish;
