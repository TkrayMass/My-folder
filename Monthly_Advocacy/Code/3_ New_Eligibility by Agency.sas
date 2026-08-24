/*===============================================================
  Monthly Advocacy Report
  PROC 3 - New Eligibility by Agency
  Dynamic Production Version v1
  Run time >3hrs

  PURPOSE
    Rebuild the historical New Eligibility by Agency report from
    May 2014 through the current reporting month using the validated
    dynamic Proc 0 eligibility table.

  VALIDATION
    Validated against:
      KP.MONTHLY_ADV_202607_ADDS

    July 2026 validation result:
      Production rows = 7,146
      Dynamic rows    = 7,146
      Production differences = 0
      Dynamic differences    = 0
      STATUS = PASS

  INPUT
    MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

  OUTPUT
    DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN

  CURRENT-MONTH DISTRIBUTION FILE
    new_eligibility - <mon yyyy> w agency.xlsx

  HISTORY
    May 2014 through &REPORT_YYYYMM

  DESIGN
    - Preserves inherited PROC 3 Snowflake business logic.
    - Replaces all hard-coded monthly %ELIGSTART calls with one
      month-by-month controller.
    - Uses shared 00_Project_Settings.sas.
    - Does NOT overwrite KP production datasets.
    - Writes validated permanent dynamic output to DYN.
    - Exports only the current reporting month after the historical
      rebuild is complete.
================================================================*/


/*===============================================================
  1. Shared project settings
================================================================*/
%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options compress=yes;


/*===============================================================
  2. Snowflake connections
================================================================*/
libname my_snow snow
    datasrc=MHDWPROD
    database=MHUSER
    schema=KRAYT
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="AUTHENTICATOR=SNOWFLAKE_JWT;
             PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
             PRIV_KEY_FILE_PWD=Kta#93574#yHRre"
    role=KRAYT_rw_role
    readbuff=32767
    insertbuff=32767;

libname mhdwprod snow
    datasrc=MHDWPROD
    database=MHUSER
    schema=KRAYT
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="AUTHENTICATOR=SNOWFLAKE_JWT;
             PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
             PRIV_KEY_FILE_PWD=Kta#93574#yHRre";


/*===============================================================
  3. Production business logic
================================================================*/
%macro eligstart(
    extrdt,
    begdate,
    enddate,
    dout,
    ename,
    priormonth,
    currmonth,
    din
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
                cde_elig_start || '-' || dsc_elig_start as dsc_elig_start,
                agency,
                count(*) as members,
                count(distinct sak_recip) as qa_members

            from
            (
                select *
                from
                (
                    select
                        elig.sak_recip,
                        cde_elig_start,
                        xref.dsc as dsc_elig_start,
                        elig.cde_aid_category,
                        dsc_aid_category,
                        dte_effective_elig,
                        dte_end_elig,
                        dte_effective_aidcat,
                        dte_end_aidcat,
                        &currmonth as currmonth,

                        case
                            when nvl(elig.cde_agency,'HIX') not in ('MHO','HIX')
                            then 'referred elig'
                            else elig.cde_agency
                        end as agency,

                        row_number() over
                        (
                            partition by elig.sak_recip
                            order by dte_effective_aidcat desc,
                                     num_rank_aid_category
                        ) as recnt

                    from mhdwprod.nw.nw_eligibility_hist elig

                    inner join mhdwprod.nw.nw_aid_category aid
                        on aid.aidcat_seq = elig.aidcat_seq

                    inner join mhdwprod.nw.nw_sup_code_ref xref
                        on xref.cde_group = 'CDE_ELIG_START'
                       and xref.cde_char  = elig.cde_elig_start

                    inner join nw_member mem
                        on mem.mem_seq = elig.mem_seq

                    where &extrdt between elig.valid_from_dt_tm
                                      and elig.valid_thru_dt_tm

                      and &enddate between elig.dte_effective
                                       and elig.dte_end

                      and cde_status_aidcat = 'A'
                      and cde_status_elig   = 'A'

                      and id_medicaid in
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
                      )
                )
                where recnt = 1
            )

            group by rollup
            (
                currmonth,
                cde_elig_start || '-' || dsc_elig_start,
                agency
            )

            order by members desc
        );

        disconnect from mhdwprod;
    quit;

%mend eligstart;


/*===============================================================
  4. Full-history dynamic controller
     May 2014 through current REPORT_MONTH
================================================================*/
%macro build_proc3_history;

    %local start_month
           months_to_run
           i
           month_dt
           prior_dt
           currmonth
           priormonth
           begdate_text
           enddate_text
           ename_text
           extrdt_text
           extrdt_sql
           enddate_sql
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

    /* Rebuild permanent dynamic output from scratch */
    proc datasets library=dyn nolist;
        delete adv_&REPORT_YYYYMM._elig_agcy_dyn;
    quit;

    %put ============================================================;
    %put PROC 3 DYNAMIC PRODUCTION REBUILD STARTING;
    %put START MONTH=201405;
    %put END MONTH=&REPORT_YYYYMM;
    %put TOTAL MONTHS=%eval(&months_to_run + 1);
    %put INPUT=&din;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN;
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

        %let begdate_text=
            %sysfunc(putn(&month_dt,date11.));

        %let enddate_text=
            %sysfunc(
                putn(
                    %sysfunc(intnx(month,&month_dt,0,e)),
                    date11.
                )
            );

        %let enddate_sql=
            %str(%')&enddate_text%str(%');

        %let ename_text=
            %sysfunc(putn(&month_dt,monyy7.));

        %put NOTE: PROC3 DYNAMIC - Processing &currmonth;
        %put NOTE: PRIOR=&priormonth BEGIN=&begdate_text END=&enddate_text;

        proc datasets library=work nolist;
            delete proc3_month;
        quit;

        %eligstart(
            &extrdt_sql,
            "&begdate_text",
            &enddate_sql,
            work.proc3_month,
            "&ename_text",
            &priormonth,
            &currmonth,
            &din
        );

        %if not %sysfunc(exist(work.proc3_month)) %then %do;

            %put ERROR: PROC3 DYNAMIC - WORK.PROC3_MONTH was not created for &currmonth.;
            %put ERROR: PROC3 DYNAMIC - Historical rebuild stopped.;

            %return;

        %end;

        %if &first_month=1 %then %do;

            data dyn.adv_&REPORT_YYYYMM._elig_agcy_dyn;
                set work.proc3_month;
            run;

            %let first_month=0;

        %end;
        %else %do;

            proc append
                base=dyn.adv_&REPORT_YYYYMM._elig_agcy_dyn
                data=work.proc3_month
                force;
            run;

        %end;

    %end;

    proc datasets library=work nolist;
        delete proc3_month;
    quit;

    %put ============================================================;
    %put PROC 3 DYNAMIC PRODUCTION REBUILD COMPLETE;
    %put MONTHS PROCESSED=%eval(&months_to_run + 1);
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN;
    %put ============================================================;

%mend build_proc3_history;

%build_proc3_history;


/*===============================================================
  5. Current-month output, export, and QC
================================================================*/
%macro proc3_finish;

    %local REPORT_MON3
           REPORT_YEAR
           PROC3_XLSX
           current_rows;

    %if not %sysfunc(
        exist(dyn.adv_&REPORT_YYYYMM._elig_agcy_dyn)
    ) %then %do;

        %put ============================================================;
        %put ERROR: PROC 3 DYNAMIC FAILED.;
        %put ERROR: DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN DOES NOT EXIST.;
        %put ERROR: CURRENT-MONTH DATASET AND EXCEL EXPORT WERE SKIPPED.;
        %put ============================================================;

        %return;

    %end;

    data work.proc3_current_month;
        set dyn.adv_&REPORT_YYYYMM._elig_agcy_dyn;
        where currmonth = &REPORT_YYYYMM;
    run;

    proc sql noprint;

        select count(*)
        into :current_rows trimmed
        from work.proc3_current_month;

    quit;

    %if &current_rows = 0 %then %do;

        %put ============================================================;
        %put ERROR: PROC 3 DYNAMIC FAILED.;
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

    %let PROC3_XLSX=
/sas_mass_health/shared/Advocacy_Dynamic/Output/&OUTPUT_FOLDER./new_eligibility - &REPORT_MON3 &REPORT_YEAR w agency.xlsx;

    proc export
        data=work.proc3_current_month
        outfile="&PROC3_XLSX"
        dbms=xlsx
        replace;
        sheet="&REPORT_MON3-&REPORT_YEAR";
    run;

    proc sql;

        title "PROC 3 New Eligibility by Agency - Dynamic QC";

        select
            count(*) as row_count,
            min(currmonth) as first_month,
            max(currmonth) as last_month,
            sum(members) as total_members,
            sum(qa_members) as total_qa_members
        from dyn.adv_&REPORT_YYYYMM._elig_agcy_dyn;

        title "PROC 3 Current Reporting Month QC";

        select
            count(*) as current_month_rows,
            min(currmonth) as current_month,
            max(currmonth) as current_month_max,
            sum(members) as total_members,
            sum(qa_members) as total_qa_members
        from work.proc3_current_month;

    quit;

    title;

    %put ============================================================;
    %put PROC 3 DYNAMIC V1 FINISHED SUCCESSFULLY;
    %put INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN;
    %put CURRENT MONTH ROWS=&current_rows;
    %put CURRENT MONTH EXCEL=&PROC3_XLSX;
    %put ============================================================;

%mend proc3_finish;

%proc3_finish;
