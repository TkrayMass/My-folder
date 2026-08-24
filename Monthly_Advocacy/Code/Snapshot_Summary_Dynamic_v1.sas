/*===============================================================
  Monthly Advocacy Report
  Snapshot Summary - Dynamic Version v1.1

  PURPOSE
    Creates the distributed Snapshot Summary report from the
    validated Proc 0 dynamic Snowflake table.

  INPUT
    MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN

  PERMANENT SAS OUTPUT
    DYN.SNAPSHOT_SUMMARY_&REPORT_YYYYMM

  DISTRIBUTION OUTPUT
    &ADV_OUTPUT/&OUTPUT_FOLDER/Snapshot - &REPORT_YYYYMMDD.mf.csv

  NOTE
    This replaces the manual Snowflake SQL previously run after
    Proc 0. It summarizes the large eligibility history table by
    YR_MTH and CDE_BUDGET_GROUP, then exports only the small summary
    report that is sent to the distribution list.
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


/*===============================================================
  3. Build permanent Snapshot Summary dataset
================================================================*/
proc sql;

    connect using mhdwprod;

    execute (USE DATABASE MHUSER) by mhdwprod;
    execute (USE SCHEMA KRAYT) by mhdwprod;
    execute (USE WAREHOUSE MHA_WH) by mhdwprod;
    execute (USE ROLE KRAYT_RW_ROLE) by mhdwprod;

    create table dyn.snapshot_summary_&REPORT_YYYYMM as
    select *
    from connection to mhdwprod
    (
        select
            yr_mth,
            cde_budget_group,
            count(*) as members
        from MHUSER.KRAYT."budget_adv_elig_&REPORT_YYYYMM._x_dyn"
        where cde_budget_group is not null
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
  4. QC
================================================================*/
proc sql;
    title "Snapshot Summary Dynamic QC";

    select
        count(*) as row_count,
        min(yr_mth) as first_month,
        max(yr_mth) as last_month,
        sum(members) as total_members
    from dyn.snapshot_summary_&REPORT_YYYYMM;

quit;

title;


/*===============================================================
  5. Export distributed Snapshot CSV
================================================================*/
proc export
    data=dyn.snapshot_summary_&REPORT_YYYYMM
    outfile="&ADV_OUTPUT/&OUTPUT_FOLDER/Snapshot - &REPORT_YYYYMMDD.mf.csv"
    dbms=csv
    replace;
run;


/*===============================================================
  6. Completion message
================================================================*/
%put ============================================================;
%put SNAPSHOT SUMMARY DYNAMIC V1.1 FINISHED;
%put INPUT=MHUSER.KRAYT.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN;
%put SAS OUTPUT=DYN.SNAPSHOT_SUMMARY_&REPORT_YYYYMM;
%put CSV OUTPUT=&ADV_OUTPUT/&OUTPUT_FOLDER/Snapshot - &REPORT_YYYYMMDD.mf.csv;
%put ============================================================;
