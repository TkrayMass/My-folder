/*===============================================================
  Monthly Advocacy Report
  PROC 0 - Dynamic Development Version v1.4
  VALIDATED FULL-REBUILD LOGIC / LOW-LOG PRODUCTION TEST

  PURPOSE
    Rebuild the full monthly eligibility snapshot history from
    March 2009 through the reporting month.

  VALIDATED BASELINE
    Production row count: 458,284,004
    Dynamic row count:    458,284,004
    First month:          200903
    Last month:           202607

  CHANGE FROM v1.3
    - Keeps the validated FULL-HISTORY rebuild logic unchanged.
    - Turns SASTRACE OFF.  v1.3 enabled detailed Snowflake tracing,
      which generated an extremely large SAS Studio log and can add
      substantial logging overhead during a 209-month rebuild.
    - Explicitly turns FULLSTIMER off during the rebuild to reduce
      repetitive per-step timing output.
    - Keeps concise progress messages so the current month being
      processed is still visible.
    - Does NOT change extraction dates, joins, filters, output names,
      or Snowflake publication logic.

  DESIGN DECISION
    The legacy full-history CSV export remains removed.
    It is not used by downstream Advocacy procedures and would
    contain approximately 458 million rows.

  SAFETY
    - Does NOT overwrite the legacy production SAS dataset.
    - Does NOT overwrite the legacy production Snowflake table.
    - Monthly intermediate extracts are created in WORK only.
================================================================*/

/*===============================================================
  1. Shared project settings
================================================================*/
%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

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

libname svd '/sas_mass_health/shared/tkray/OPS';
libname CLMDB "/sas_mass_health/shared/Advocacy/Data/CLMDB";

/*===============================================================
  3. Low-log production-test options

  IMPORTANT:
    v1.3 used:
        options sastrace=',,,ds' sastraceloc=saslog;

    That option prints detailed SAS/ACCESS Snowflake activity for
    every monthly query.  It is useful for troubleshooting one query,
    but not for a 209-month production rebuild.

    Keep tracing OFF unless actively debugging a Snowflake problem.
================================================================*/
options sastrace=off
        nofullstimer
        nomprint
        nomlogic
        nosymbolgen
        nosource
        nosource2;

/*===============================================================
  4. Monthly extraction macro
================================================================*/
%macro getdays(extrdt, snapdt, yr_mth, snapdt1, dout);

proc sql;
    connect using mhdwprod;

    execute (USE DATABASE mhdwprod) by mhdwprod;
    execute (USE SCHEMA NW) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

    create table &dout as
    select * from connection to mhdwprod
    (
        select
            &yr_mth as yr_mth,
            se.id_medicaid,
            mem.id_medicaid_crnt,
            se.cde_age_group,
            se.cde_budget_group
        from NW.nw_state_eligibility_hist se
        inner join NW.nw_member_xref_medicaid mem
            on mem.mem_seq = se.mem_seq
        where to_date(&extrdt) between se.valid_from_dt_tm and se.valid_thru_dt_tm
          and se.ind_active = 'Y'
          and to_date(&snapdt) between se.dte_effective and se.dte_end
    );

    disconnect from mhdwprod;
quit;

%mend getdays;

/*===============================================================
  5. Dynamic historical rebuild
================================================================*/
%macro build_proc0_history;

    %local start_month
           months_to_run
           i
           month_dt
           month_end
           yr_mth
           snapdt1
           extrdt_text
           snapdt_text
           extrdt_arg
           snapdt_arg
           first_month;

    %let start_month=%sysfunc(mdy(3,1,2009));
    %let months_to_run=%sysfunc(intck(month,&start_month,&REPORT_MONTH_BEGIN));

    %let extrdt_text=%sysfunc(putn(&EXTRACTION_DATE,date11.));
    %let extrdt_arg=%sysfunc(quote(&extrdt_text,%str(%')));

    %let first_month=1;

    /* Start clean.  An interrupted prior run must never be treated
       as a completed current-month dataset. */
    proc datasets library=dyn nolist;
        delete budget_adv_elig_&REPORT_YYYYMM._x_dyn;
    quit;

    %put ============================================================;
    %put PROC 0 DYNAMIC FULL REBUILD STARTING;
    %put START MONTH=200903;
    %put END MONTH=&REPORT_YYYYMM;
    %put TOTAL MONTHS=%eval(&months_to_run + 1);
    %put EXTRACTION DATE=&extrdt_text;
    %put SASTRACE=OFF;
    %put FULLSTIMER=OFF;
    %put ============================================================;

    %do i=0 %to &months_to_run;

        %let month_dt=%sysfunc(intnx(month,&start_month,&i,b));
        %let month_end=%sysfunc(intnx(month,&month_dt,0,e));

        %let yr_mth=%sysfunc(putn(&month_dt,yymmn6.));
        %let snapdt1=%sysfunc(putn(&month_end,yymmddn8.));
        %let snapdt_text=%sysfunc(putn(&month_end,date11.));
        %let snapdt_arg=%sysfunc(quote(&snapdt_text,%str(%')));

        /* Concise progress indicator. */
        %put NOTE: PROC0 DYNAMIC - Processing &yr_mth
                   (%eval(&i + 1) of %eval(&months_to_run + 1));

        %getdays(
            &extrdt_arg,
            &snapdt_arg,
            &yr_mth,
            &snapdt1,
            work.proc0_month
        );

        %if not %sysfunc(exist(work.proc0_month)) %then %do;
            %put ERROR: PROC0 DYNAMIC - WORK.PROC0_MONTH was not created for &yr_mth.;
            %put ERROR: PROC0 DYNAMIC - Rebuild stopped before Snowflake upload.;
            %return;
        %end;

        %if &first_month = 1 %then %do;
            data dyn.budget_adv_elig_&REPORT_YYYYMM._x_dyn;
                set work.proc0_month;
            run;
            %let first_month=0;
        %end;
        %else %do;
            proc append
                base=dyn.budget_adv_elig_&REPORT_YYYYMM._x_dyn
                data=work.proc0_month
                force;
            run;
        %end;

        proc datasets library=work nolist;
            delete proc0_month;
        quit;

    %end;

    %put ============================================================;
    %put PROC 0 DYNAMIC FULL REBUILD COMPLETE;
    %put TOTAL MONTHS PROCESSED=%eval(&months_to_run + 1);
    %put FINAL REPORT MONTH=&REPORT_YYYYMM;
    %put ============================================================;

%mend build_proc0_history;

%build_proc0_history;

/*===============================================================
  6. Post-build QC + Snowflake publication
================================================================*/
%macro proc0_post_qc;

    %if %sysfunc(exist(dyn.budget_adv_elig_&REPORT_YYYYMM._x_dyn)) %then %do;

        proc sql;
            title "PROC 0 Dynamic Development QC";
            select
                min(yr_mth) as first_yr_mth,
                max(yr_mth) as last_yr_mth,
                count(*) as total_rows
            from dyn.budget_adv_elig_&REPORT_YYYYMM._x_dyn;
        quit;
        title;

        data mhdwprod.budget_adv_elig_&REPORT_YYYYMM._x_dyn
            (bulkload=yes
             bl_internal_stage="user/someuser"
             bl_compress=yes);
            set dyn.budget_adv_elig_&REPORT_YYYYMM._x_dyn;
        run;

        %put ============================================================;
        %put PROC 0 DYNAMIC V1.4 FINISHED;
        %put SAS DATASET=DYN.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
        %put SNOWFLAKE TABLE=BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
        %put CSV EXPORT=SKIPPED BY DESIGN;
        %put ============================================================;

    %end;
    %else %do;
        %put ERROR: PROC0 DYNAMIC - Final DYN dataset does not exist.;
        %put ERROR: Snowflake upload was NOT attempted.;
    %end;

%mend proc0_post_qc;

%proc0_post_qc;
