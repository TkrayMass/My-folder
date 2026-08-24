/*===============================================================
  Monthly Advocacy Report
  PROC 5 - New Terminations by Eligibility Stop
  Dynamic Production Version v1.1
  
  Run Time >3hrs

  v1.1 QC FIX
    Corrects malformed nested %PUT statement at end of PROC5_FINISH.
    No business logic, dates, filters, joins, outputs, or calculations changed.

  PURPOSE
    Rebuild the historical New Terminations by Eligibility Stop
    report from May 2014 through the current reporting month using
    the validated dynamic Proc 0 eligibility table.

  ORIGINAL PRODUCTION OUTPUT
    KP.MONTHLY_ADV_YYYYMM_TERMS

  OUTPUT
    DYN.ADV_&REPORT_YYYYMM._TERMS_DYN

  CURRENT-MONTH DISTRIBUTION FILE
    new_terminations - option1 wtieout <YYYYMM>.xlsx

  INPUT
    MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

  HISTORY
    May 2014 through &REPORT_YYYYMM

  BUSINESS LOGIC
    For each month:
      Prior-month members
      MINUS
      Current-month members
    excluding budget groups 99, 44, and 87.

    For those terminating members, derive the eligibility-stop
    reason from NW_ELIGIBILITY_HIST as of the prior-month snapshot
    date, keeping the most recent applicable aid-category row.

  DESIGN
    - Does NOT overwrite KP production data.
    - Rebuilds the permanent Proc 5 dynamic dataset from scratch.
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
  3. Inherited Proc 5 business logic
================================================================*/
%macro eligstop(
    extrdt,
    dout,
    priormonth,
    currmonth,
    din,
    psnapdt
);

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
                currmonth,
                cde_elig_stop || '-' || dsc_elig_stop as dsc_elig_stop,
                count(*) as members,
                count(distinct sak_recip) as qa_members

            from
            (
                select *
                from
                (
                    select
                        elig.sak_recip,
                        cde_elig_stop,
                        xref.dsc as dsc_elig_stop,
                        elig.cde_aid_category,
                        dsc_aid_category,
                        dte_effective_elig,
                        dte_end_elig,
                        dte_effective_aidcat,
                        dte_end_aidcat,
                        &currmonth as currmonth,

                        row_number() over
                        (
                            partition by elig.sak_recip
                            order by dte_effective_aidcat desc,
                                     num_rank_aid_category
                        ) as recnt

                    from nw_eligibility_hist elig

                    inner join nw_aid_category aid
                        on aid.aidcat_seq = elig.aidcat_seq

                    inner join nw_sup_code_ref xref
                        on xref.cde_group = 'CDE_ELIG_STOP'
                       and xref.cde_char  = elig.cde_elig_stop

                    inner join nw_member mem
                        on mem.mem_seq = elig.mem_seq

                    where &extrdt between elig.valid_from_dt_tm
                                      and elig.valid_thru_dt_tm

                      and &psnapdt between elig.dte_effective
                                       and elig.dte_end

                      and cde_status_aidcat = 'A'
                      and cde_status_elig   = 'A'

                      and id_medicaid in
                      (
                          select id_medicaid
                          from &din
                          where yr_mth = &priormonth
                            and cde_budget_group not in ('99','44','87')

                          minus

                          select id_medicaid
                          from &din
                          where yr_mth = &currmonth
                            and cde_budget_group not in ('99','44','87')
                      )
                )
                where recnt = 1
            )

            group by rollup
            (
                currmonth,
                cde_elig_stop || '-' || dsc_elig_stop
            )

            order by members desc
        );

        disconnect from mhdwprod;
    quit;

%mend eligstop;


/*===============================================================
  4. Full-history TEST controller
     May 2014 through current REPORT_MONTH
================================================================*/
%macro build_proc5_history;

    %local start_month
           months_to_run
           i
           month_dt
           prior_dt
           prior_end_dt
           currmonth
           priormonth
           extrdt_text
           extrdt_sql
           psnapdt_text
           psnapdt_sql
           din
           first_month;

    %let start_month=%sysfunc(mdy(5,1,2014));

    %let months_to_run=
        %sysfunc(intck(month,&start_month,&REPORT_MONTH_BEGIN));

    %let din=
        MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn";

    %let extrdt_text=
        %sysfunc(putn(&EXTRACTION_DATE,date11.));

    %let extrdt_sql=
        %str(%')&extrdt_text%str(%');

    %let first_month=1;

    proc datasets library=dyn nolist;
        delete adv_&REPORT_YYYYMM._terms_dyn;
    quit;

    %put ============================================================;
    %put PROC 5 DYNAMIC REBUILD STARTING;
    %put START MONTH=201405;
    %put END MONTH=&REPORT_YYYYMM;
    %put TOTAL MONTHS=%eval(&months_to_run + 1);
    %put INPUT=&din;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._TERMS_DYN;
    %put ============================================================;

    %do i=0 %to &months_to_run;

        %let month_dt=
            %sysfunc(intnx(month,&start_month,&i,b));

        %let prior_dt=
            %sysfunc(intnx(month,&month_dt,-1,b));

        %let prior_end_dt=
            %sysfunc(intnx(month,&month_dt,-1,e));

        %let currmonth=
            %sysfunc(putn(&month_dt,yymmn6.));

        %let priormonth=
            %sysfunc(putn(&prior_dt,yymmn6.));

        %let psnapdt_text=
            %sysfunc(putn(&prior_end_dt,date11.));

        %let psnapdt_sql=
            %str(%')&psnapdt_text%str(%');

        %put NOTE: PROC5 DYNAMIC - Processing &currmonth;
        %put NOTE: PRIOR=&priormonth PRIOR SNAP=&psnapdt_text;

        proc datasets library=work nolist;
            delete proc5_month;
        quit;

        %eligstop(
            &extrdt_sql,
            work.proc5_month,
            &priormonth,
            &currmonth,
            &din,
            &psnapdt_sql
        );

        %if not %sysfunc(exist(work.proc5_month)) %then %do;

            %put ERROR: PROC5 DYNAMIC - WORK.PROC5_MONTH was not created for &currmonth.;
            %put ERROR: PROC5 DYNAMIC - Historical rebuild stopped.;

            %return;

        %end;

        %if &first_month=1 %then %do;

            data dyn.adv_&REPORT_YYYYMM._terms_dyn;
                set work.proc5_month;
            run;

            %let first_month=0;

        %end;
        %else %do;

            proc append
                base=dyn.adv_&REPORT_YYYYMM._terms_dyn
                data=work.proc5_month
                force;
            run;

        %end;

    %end;

    proc datasets library=work nolist;
        delete proc5_month;
    quit;

    %put ============================================================;
    %put PROC 5 DYNAMIC REBUILD COMPLETE;
    %put MONTHS PROCESSED=%eval(&months_to_run + 1);
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._TERMS_DYN;
    %put ============================================================;

%mend build_proc5_history;

%build_proc5_history;


/*===============================================================
  5. Current-month output, export, and QC
================================================================*/
%macro proc5_finish;

    %local PROC5_XLSX current_rows;

    %if not %sysfunc(
        exist(dyn.adv_&REPORT_YYYYMM._terms_dyn)
    ) %then %do;

        %put ============================================================;
        %put ERROR: PROC 5 DYNAMIC FAILED.;
        %put ERROR: DYN.ADV_&REPORT_YYYYMM._TERMS_DYN DOES NOT EXIST.;
        %put ERROR: CURRENT-MONTH DATASET AND EXCEL EXPORT WERE SKIPPED.;
        %put ============================================================;

        %return;

    %end;

    data work.proc5_current_month;
        set dyn.adv_&REPORT_YYYYMM._terms_dyn;
        where currmonth = &REPORT_YYYYMM;
    run;

    proc sql noprint;

        select count(*)
        into :current_rows trimmed
        from work.proc5_current_month;

    quit;

    %if &current_rows = 0 %then %do;

        %put ============================================================;
        %put ERROR: PROC 5 DYNAMIC FAILED.;
        %put ERROR: NO ROWS FOUND FOR CURRENT MONTH &REPORT_YYYYMM.;
        %put ERROR: EXCEL EXPORT WAS SKIPPED.;
        %put ============================================================;

        %return;

    %end;

    %let PROC5_XLSX=
/sas_mass_health/shared/Advocacy_Dynamic/Output/&OUTPUT_FOLDER./new_terminations - option1 wtieout &REPORT_YYYYMM..xlsx;

    proc export
        data=work.proc5_current_month
        outfile="&PROC5_XLSX"
        dbms=xlsx
        replace;
        sheet="&REPORT_YYYYMM";
    run;

    proc sql;

        title "PROC 5 New Terminations - Dynamic TEST QC";

        select
            count(*) as row_count,
            min(currmonth) as first_month,
            max(currmonth) as last_month,
            sum(members) as total_members,
            sum(qa_members) as total_qa_members
        from dyn.adv_&REPORT_YYYYMM._terms_dyn;

        title "PROC 5 Current Reporting Month QC";

        select
            count(*) as current_month_rows,
            min(currmonth) as current_month,
            max(currmonth) as current_month_max,
            sum(members) as total_members,
            sum(qa_members) as total_qa_members
        from work.proc5_current_month;

    quit;

    title;

    %put ============================================================;
    %put PROC 5 DYNAMIC V1.1 FINISHED SUCCESSFULLY;
    %put INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._TERMS_DYN;
    %put CURRENT MONTH ROWS=&current_rows;
    %put CURRENT MONTH EXCEL=&PROC5_XLSX;
    %put ============================================================;

%mend proc5_finish;

%proc5_finish;
