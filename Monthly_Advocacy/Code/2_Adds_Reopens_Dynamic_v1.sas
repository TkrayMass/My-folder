/*===============================================================
  Monthly Advocacy Report
  PROC 2 - Adds / Reopens by Budget Group
  Dynamic Version v1
  
  runs - 13 minutes

  PURPOSE
    Rebuild the monthly Adds/Reopens-by-Budget-Group history from
    May 2014 through the current reporting month.

  INPUT
    MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"

  OUTPUT
    DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN

  BUSINESS LOGIC
    Preserved from the verified inherited PROC 2 program.

  DYNAMIC DATE PATTERN
    For each current month C:
      PRIORMONTH = C - 1 month
      OYR        = C - 12 months
      OYRP       = C - 12 months
      TYR        = C - 36 months
      TYRP       = C - 1 month
      FYR        = C - 60 months

    These offsets reproduce the recurring hard-coded parameter
    pattern in the inherited PROC 2 calls.

  SAFETY
    - Does NOT overwrite KP production datasets.
    - Does NOT overwrite production Snowflake tables.
    - Writes only to the Advocacy_Dynamic DYN library.
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
     Preserved from inherited PROC 2
================================================================*/
%macro eligstart(
    extrdt,
    begdate,
    enddate,
    dout,
    ename,
    priormonth,
    currmonth,
    din,
    oyr,
    oyrp,
    tyr,
    tyrp,
    fyr
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
                cde_budget_group,
                sum(reopened) as reopened,
                sum(case when reopened=1 and reopened_0_3=1 then 1 else 0 end) as reopened_0_3,
                sum(case when reopened=1 and reopened_0_3=0 then 1 else 0 end) as reopened_4_12,
                sum(case when reopened=0 and newborn=1 then 1 else 0 end) as newborn,
                sum(case when reopened=0 and newborn=0 and new_hxwin3=1 then 1 else 0 end) as new_hxwin3,
                sum(case when reopened=0 and newborn=0 and new_hxwin3=0 and new_hxwin5=1 then 1 else 0 end) as new_hxwin5,
                sum(case when reopened=0 and newborn=0 and new_hxwin3=0 and new_hxwin5=0 then 1 else 0 end) as new,
                count(*) as openings,
                yr_mth

            from
            (
                select distinct
                    pop.id_medicaid,
                    &currmonth as yr_mth,
                    b.cde_budget_group,

                    max(
                        case
                            when dt_yyyymm between &oyr and &priormonth
                                 and bg.cde_budget_group not in ('99','44','87')
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as reopened,

                    max(
                        case
                            when dt_yyyymm between &oyr and &priormonth
                                 and months_between(
                                        to_date(cast(&priormonth as string),'YYYYMM'),
                                        to_date(cast(dt_yyyymm as string),'YYYYMM')
                                     ) + 1 <= 3
                                 and bg.cde_budget_group not in ('99','44','87')
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as reopened_0_3,

                    max(
                        case
                            when dt_yyyymm between &oyr and &priormonth
                                 and months_between(
                                        to_date(cast(&priormonth as string),'YYYYMM'),
                                        to_date(cast(dt_yyyymm as string),'YYYYMM')
                                     ) + 1 > 3
                                 and bg.cde_budget_group not in ('99','44','87')
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as reopened_4_12,

                    max(
                        case
                            when dt_yyyymm between &tyr and &tyrp
                                 and bg.cde_budget_group not in ('99','44','87')
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as new_hxwin3,

                    max(
                        case
                            when dt_yyyymm between &fyr and &tyr
                                 and bg.cde_budget_group not in ('99','44','87')
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as new_hxwin5,

                    max(
                        case
                            when b.cde_age_group='A'
                            then 1 else 0
                        end
                    ) over (partition by pop.id_medicaid) as newborn

                from
                (
                    select id_medicaid
                    from &din
                    where yr_mth=&currmonth
                      and cde_budget_group not in ('99','44','87')

                    except

                    select id_medicaid
                    from &din
                    where yr_mth=&priormonth
                      and cde_budget_group not in ('99','44','87')
                ) pop

                inner join &din b
                    on pop.id_medicaid=b.id_medicaid
                   and &currmonth=yr_mth

                left join mhdwprod.nw.nw_state_eligibility_by_month bg
                    on pop.id_medicaid=bg.id_medicaid
                   and '31-DEC-9999' between bg.valid_from_dt_tm
                                        and bg.valid_thru_dt_tm

                left join nw_member_cur mem
                    on mem.id_medicaid=pop.id_medicaid
            )

            group by yr_mth, cde_budget_group
            order by yr_mth, cde_budget_group
        );

        disconnect from mhdwprod;
    quit;

%mend eligstart;


/*===============================================================
  4. Full-history dynamic controller
     May 2014 through current REPORT_MONTH
================================================================*/
%macro build_proc2_history;

    %local start_month
           months_to_run
           i
           month_dt
           prior_dt
           oyr_dt
           oyrp_dt
           tyr_dt
           tyrp_dt
           fyr_dt
           currmonth
           priormonth
           oyr
           oyrp
           tyr
           tyrp
           fyr
           begdate_text
           enddate_text
           ename_text
           extrdt_text
           din
           first_month;

    %let start_month=%sysfunc(mdy(5,1,2014));
    %let months_to_run=%sysfunc(intck(month,&start_month,&REPORT_MONTH_BEGIN));

    %let din=MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn";
    %let extrdt_text=%sysfunc(putn(&EXTRACTION_DATE,date11.));
    %let first_month=1;

    proc datasets library=dyn nolist;
        delete adv_&REPORT_YYYYMM._adds_newv5_dyn;
    quit;

    %put ============================================================;
    %put PROC 2 DYNAMIC REBUILD STARTING;
    %put START MONTH=201405;
    %put END MONTH=&REPORT_YYYYMM;
    %put TOTAL MONTHS=%eval(&months_to_run + 1);
    %put INPUT=&din;
    %put ============================================================;

    %do i=0 %to &months_to_run;

        %let month_dt=%sysfunc(intnx(month,&start_month,&i,b));
        %let prior_dt=%sysfunc(intnx(month,&month_dt,-1,b));

        %let oyr_dt=%sysfunc(intnx(month,&month_dt,-12,b));
        %let oyrp_dt=%sysfunc(intnx(month,&month_dt,-12,b));
        %let tyr_dt=%sysfunc(intnx(month,&month_dt,-36,b));
        %let tyrp_dt=%sysfunc(intnx(month,&month_dt,-1,b));
        %let fyr_dt=%sysfunc(intnx(month,&month_dt,-60,b));

        %let currmonth=%sysfunc(putn(&month_dt,yymmn6.));
        %let priormonth=%sysfunc(putn(&prior_dt,yymmn6.));
        %let oyr=%sysfunc(putn(&oyr_dt,yymmn6.));
        %let oyrp=%sysfunc(putn(&oyrp_dt,yymmn6.));
        %let tyr=%sysfunc(putn(&tyr_dt,yymmn6.));
        %let tyrp=%sysfunc(putn(&tyrp_dt,yymmn6.));
        %let fyr=%sysfunc(putn(&fyr_dt,yymmn6.));

        %let begdate_text=%sysfunc(putn(&month_dt,date11.));
        %let enddate_text=%sysfunc(putn(%sysfunc(intnx(month,&month_dt,0,e)),date11.));
        %let ename_text=%sysfunc(putn(&month_dt,monyy7.));

        %put NOTE: PROC2 DYNAMIC - Processing &currmonth;
        %put NOTE: PRIOR=&priormonth OYR=&oyr OYRP=&oyrp TYR=&tyr TYRP=&tyrp FYR=&fyr;

        proc datasets library=work nolist;
            delete proc2_month;
        quit;

        %eligstart(
            "&extrdt_text",
            "&begdate_text",
            "&enddate_text",
            work.proc2_month,
            "&ename_text",
            &priormonth,
            &currmonth,
            &din,
            &oyr,
            &oyrp,
            &tyr,
            &tyrp,
            &fyr
        );

        %if not %sysfunc(exist(work.proc2_month)) %then %do;
            %put ERROR: PROC2 DYNAMIC - WORK.PROC2_MONTH was not created for &currmonth.;
            %put ERROR: PROC2 DYNAMIC - Rebuild stopped.;
            %return;
        %end;

        %if &first_month=1 %then %do;

            data dyn.adv_&REPORT_YYYYMM._adds_newv5_dyn;
                set work.proc2_month;
            run;

            %let first_month=0;

        %end;
        %else %do;

            proc append
                base=dyn.adv_&REPORT_YYYYMM._adds_newv5_dyn
                data=work.proc2_month
                force;
            run;

        %end;

    %end;

    proc datasets library=work nolist;
        delete proc2_month;
    quit;

    %put ============================================================;
    %put PROC 2 DYNAMIC REBUILD COMPLETE;
    %put MONTHS PROCESSED=%eval(&months_to_run + 1);
    %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN;
    %put ============================================================;

%mend build_proc2_history;

%build_proc2_history;


/*===============================================================
  5. Post-build QC summary
================================================================*/
%macro proc2_post_qc;

    %if %sysfunc(exist(dyn.adv_&REPORT_YYYYMM._adds_newv5_dyn)) %then %do;

        proc sql;
            title "PROC 2 Adds/Reopens by BG Dynamic QC";

            select
                count(*) as row_count,
                min(yr_mth) as first_month,
                max(yr_mth) as last_month,
                sum(openings) as total_openings
            from dyn.adv_&REPORT_YYYYMM._adds_newv5_dyn;

        quit;

        title;

        %put ============================================================;
        %put PROC 2 DYNAMIC V1 FINISHED;
        %put INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
        %put OUTPUT=DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN;
        %put ============================================================;

    %end;
    %else %do;

        %put ERROR: PROC2 DYNAMIC - Final dynamic dataset does not exist.;

    %end;

%mend proc2_post_qc;

%proc2_post_qc;
