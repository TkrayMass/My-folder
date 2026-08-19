
/******************************************************************************************
 ACO Weekly Enrollment Report - v3.13.1 PRODUCTION - DISTRIBUTION DECISION QC

 Purpose:
   - Preserves the validated manual report calculations.
   - Retains the working v3 Snowflake table-creation method:
       CREATE OR REPLACE TABLE through Snowflake pass-through.
   - Reads dynamic run dates from Snowflake.
   - Calls ACOENR_WEEKLY_REFRESH().
   - Validates ACOENR_02_ENRDIS.
   - Rebuilds ACOENR_00 through ACOENR_06.
   - Produces the required Excel worksheets.
   - Restores validated TOTAL-category weekly QC with QC_Summary, QC_Matrix, and QC_Detail.
   - Adds QC history comparison and QC workbook without changing report calculations.
   - QC email is temporarily disabled while automation testing continues.
   - Current-MTD movement can generate WARNING but cannot by itself force overall FAIL.
   - Overall FAIL is reserved for blocking RED/NEW/MISSING rows outside CURRENT_MTD.
   - Adds an operational Distribution Decision:
       READY TO DISTRIBUTE
       REVIEW BEFORE DISTRIBUTION
       DO NOT DISTRIBUTE
   - Separates blocking failures, review warnings, and informational MTD flags.
   - Uses a 500-member blocking threshold for older CASELOAD revisions.

 Important:
   - Tables ACOENR_03 through ACOENR_06 are created with Snowflake
     CREATE OR REPLACE TABLE. Do not convert these statements back to
     SAS LIBNAME CREATE TABLE statements.
******************************************************************************************/

ods _all_ close; /* Close all open ODS destinations */
/* filename _HTMLOUT clear; */
/* filename _RTFOUT clear; */

options notes source mprint mlogic symbolgen;

/* Local SAS library used by report work tables */
libname data '/sas_mass_health/shared/data/ACOWeeklyReport';

/* Snowflake connection */
options nosymbolgen nomprint nosource;

/* Load Snowflake credentials */
%include "/sas_mass_health/shared/tkray/private/snowflake_credentials.sas";

options source;

libname my_snow1 snow
    datasrc=MHDWPROD
    database=MHDWPROD
    schema=MHA
    uid="TATYANA.KRAY@MASS.GOV"
    conopts="
        AUTHENTICATOR=SNOWFLAKE_JWT;
        ROLE=MHA_TEAM_ROLE;
        WAREHOUSE=MHA_WH;
        PRIV_KEY_FILE=/sas_mass_health/shared/tkray/ssh/keys/krayt_rsa_key_1.p8;
        PRIV_KEY_FILE_PWD=&SF_KEY_PWD."
;
/* Valid macro wrapper for step-level SQL error handling */
%macro stop_if_sql_error(step=);
    %if &sqlrc ne 0 %then %do;
        %put ERROR: &step failed. Program stopped.;
        %abort cancel;
    %end;
%mend stop_if_sql_error;

/******************************************************************************************
 STEP 0 - CLEANUP BEFORE RUN
******************************************************************************************/

/* Clear old SAS-side work tables from previous run */
proc datasets library=data nolist;
    delete myEnrAgg2
           myCaseload2
           check_acoenr_02
           code_xwalk
           myCaseload2A;
quit;

/* Drop old Snowflake working/report tables before refresh.
   Do NOT drop permanent crosswalk tables. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (DROP TABLE IF EXISTS weektable_) by my_snow1;
    execute (DROP TABLE IF EXISTS test_weektable2_) by my_snow1;
    execute (DROP TABLE IF EXISTS nw_member_enroll) by my_snow1;
    execute (DROP TABLE IF EXISTS a_Region_SrvArea) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_00_WEEKTABLE_3) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_01_SNAPSHOT) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_02_ENRDIS) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_03_ALLDATA) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_04_ALLDATA_NAME) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_05_CLEANREP_NAME) by my_snow1;
    execute (DROP TABLE IF EXISTS ACOENR_06_REP_W_PERC) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Snowflake cleanup);

/******************************************************************************************
 STEP 1 - DYNAMIC RUN DATES FROM SNOWFLAKE

 Note:
   Snowflake owns the business run dates. SAS reads equivalent values from Snowflake
   and uses them only for snapshot filters, filenames, report titles, and display labels.
******************************************************************************************/

proc sql noprint;
    connect using my_snow1;

    select startdate_char,
           lastweek_char,
           enddate_char,
           today_char,
           wh_thru_dt_char,
           running_dt_char,
           repdt_char
      into :StartDate_char trimmed,
           :lastweek_char trimmed,
           :EndDate_char trimmed,
           :today_char trimmed,
           :wh_thru_dt_char trimmed,
           :Running_DT_char trimmed,
           :repdt trimmed
      from connection to my_snow1
      (
        select to_char(to_date('2023-03-01'), 'YYYY-MM-DD') as startdate_char,
               to_char(dateadd(day,-7,current_date()), 'YYYY-MM-DD') as lastweek_char,
               to_char(current_date(), 'YYYY-MM-DD') as enddate_char,
               to_char(current_date(), 'YYYY-MM-DD') as today_char,
               to_char(current_date(), 'YYYY-MM-DD') as wh_thru_dt_char,
               to_char(current_date(), 'YYYY-MM-DD') as running_dt_char,
               to_char(current_date(), 'YYYYMMDD') as repdt_char
      );

    disconnect from my_snow1;
quit;

%let StartDate  = %str(%')&StartDate_char.%str(%');
%let lastweek   = %str(%')&lastweek_char.%str(%');
%let EndDate    = %str(%')&EndDate_char.%str(%');
%let today      = %str(%')&today_char.%str(%');
%let wh_thru_dt = %str(%')&wh_thru_dt_char.%str(%');
%let Running_DT = %str(%')&Running_DT_char.%str(%');

%let OUTFILE=/sas_mass_health/shared/output/ACOWeeklyReport/ReportTestMonthly-&repdt. REGXSA.xlsx;

/* QC workbook and email configuration */
%let OUTFILE=/sas_mass_health/shared/output/ACOWeeklyReport/ReportTestMonthly-&repdt._REGXSA.xls;
%let QC_EMAIL_TO=Tatyana.Kray@mass.gov;
%let QC_EMAIL_CC=;

%put NOTE: ===== ACO WEEKLY REPORT v2.0 DYNAMIC DATES =====;
%put NOTE: &=StartDate;
%put NOTE: &=lastweek;
%put NOTE: &=EndDate;
%put NOTE: &=today;
%put NOTE: &=wh_thru_dt;
%put NOTE: &=Running_DT;
%put NOTE: &=repdt;
%put NOTE: &=OUTFILE;
%put NOTE: ==================================================;

/******************************************************************************************
 STEP 2 - RUN SNOWFLAKE REFRESH PROCEDURE

 This procedure creates ACOENR_02_ENRDIS and its supporting Snowflake tables.
******************************************************************************************/

proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (CALL ACOENR_WEEKLY_REFRESH()) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=ACOENR_WEEKLY_REFRESH);

/******************************************************************************************
 STEP 3 - VERIFY SNOWFLAKE REFRESH BEFORE CONTINUING
******************************************************************************************/

/* Use Snowflake pass-through for validation so the check does not depend on
   SAS libname table-name resolution. */
proc sql noprint;
    connect using my_snow1;

    create table data.check_acoenr_02 as
    select *
    from connection to my_snow1
    (
        select count(*) as row_count,
               min(firstdtweek) as min_date,
               max(firstdtweek) as max_date
        from MHDWPROD.MHA.ACOENR_02_ENRDIS
    );

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=ACOENR_02_ENRDIS validation);

proc sql noprint;
    select row_count,
           min_date,
           max_date
      into :ACOENR_02_ROWS trimmed,
           :ACOENR_02_MIN_MONTH trimmed,
           :ACOENR_02_MAX_MONTH trimmed
    from data.check_acoenr_02;
quit;

data _null_;
    set data.check_acoenr_02;
    put "NOTE: ACOENR_02_CHECK: " row_count= min_date= max_date=;
run;

%put NOTE: ACOENR_02_ENRDIS rows=&ACOENR_02_ROWS min_month=&ACOENR_02_MIN_MONTH max_month=&ACOENR_02_MAX_MONTH.;

%macro stop_if_zero_rows;
    %if %sysevalf(&ACOENR_02_ROWS <= 0) %then %do;
        %put ERROR: ACOENR_02_ENRDIS has zero rows. Program stopped.;
        %abort cancel;
    %end;
%mend stop_if_zero_rows;
%stop_if_zero_rows;

/******************************************************************************************
 STEP 4 - CREATE SNAPSHOT AND REPORT TABLES
******************************************************************************************/

/************** 1 ***************/
/************** * weektable 3 - 1 record per month ***************/
proc sql;
      connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_00_weektable_3 as
        select 
            calendar_year,
            'Month of' as Timeperiod, 
            num_month, 
            min(dt) as startdt, 
            max(dt) as enddt, 
            min(dt_yyyymmdd) as firstdtweek
        from nw.nw_date
        where calendar_year >= 2023 
            and dt >= to_date(%str(&StartDate), 'YYYY-MM-DD')  /* Use %str() to pass the macro variable correctly */
            and dt <= to_date(&today, 'YYYY-MM-DD')
        group by calendar_year, num_month
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_00_WEEKTABLE_3);

/* Create the Snapshot table */
proc sql;
      connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_01_Snapshot as
        select 
  'snapshot' as type,
  wk.Timeperiod, 
  calendar_year, 
  num_month, 
  firstdtweek, 
  startdt, 
  enddt,   
  case when cde_managed_care_plan = 'PCC' then 'PCC' else mco.dsc_prov_type end as provtype ,
  case when cde_managed_care_plan = 'PCC' then 'PCC' else mco.name_dsp end as provname ,
  /*04/21/2020: Yi-Ling added*/
   case when  rc.CDE_RATE_CATEGORY  in ('RC01_Adult') then 'RC-I Adult'    
        when  rc.CDE_RATE_CATEGORY  in ('RC01_Child') then 'RC-I Child'     
        when  rc.CDE_RATE_CATEGORY  in ('RC02_Adult') then 'RC-II Adult'
        when  rc.CDE_RATE_CATEGORY  in ('RC02_Child') then 'RC-II Child'
        when  rc.CDE_RATE_CATEGORY  in ('RC9', 'RC09') then 'RC-IX'
        when  rc.CDE_RATE_CATEGORY  in ( 'RC10') then 'RC-X' 
        when rc2.CDE_RATE_CATEGORY in  ('RC01_Adult' ) then 'RC-I Adult'  
        when rc2.CDE_RATE_CATEGORY in  ('RC01_Child') then 'RC-I Child'  
        when rc2.CDE_RATE_CATEGORY in ('RC02_Adult') then 'RC-II Adult' 
        when rc2.CDE_RATE_CATEGORY in ('RC02_Child') then 'RC-II Child' 
        when rc2.CDE_RATE_CATEGORY in ('RC9', 'RC09')  then 'RC-IX'
        when rc2.CDE_RATE_CATEGORY in ('RC10') then 'RC-X'
        else 'NULL' 
  end as RateCat,    
  'ZZ - Member Enrolled' as dsc_enrdis,
  'ZZ' as cde_enrdis,
   DSC_MC_REGION_CAP, 
   dsc_mc_region_enroll,
   service_area,
   /*debugging*/
  /*
   id_medicaid,
   enr.dte_effective,
   enr.dte_end,
   (case when enddt > enr.dte_end then enr.dte_end else enddt end)
   		- (case when enr.dte_effective > startdt then enr.dte_effective else startdt end)
   		+ 1 as num_elig,
   	(enddt-startdt+1) as days_tp,
   	((case when enddt > enr.dte_end then enr.dte_end else enddt end)
   		- (case when enr.dte_effective > startdt then enr.dte_effective else startdt end)
   		+ 1 )/ (enddt-startdt+1) as avg_mbr*/
   count(distinct enr.id_medicaid) as mbrs,
   sum(((case when enddt > enr.dte_end then enr.dte_end else enddt end)
   		- (case when enr.dte_effective > startdt then enr.dte_effective else startdt end) + 1) / 1) /*divide by 86400 to deal with SAS date time conversion*/
   		as num_elig_days, /*the + 1 is converted into 86400 (86400 seconds in a day)*/
   max((enddt - startdt + 1)/1 ) as days_in_tp, /*these are all the same*/
   sum(((case when enddt > enr.dte_end then enr.dte_end else enddt end)
   		- (case when enr.dte_effective > startdt then enr.dte_effective else startdt end) + 1) / 1) / max((enddt - startdt + 1)/1) as avgmem
 from MHDWPROD.nw.nw_state_eligibility_hist enr
        inner join ACOENR_00_weektable_3 wk 
            on enr.DTE_EFFECTIVE <= wk.enddt and enr.DTE_END >= wk.startdt
        left join MHDWPROD.NW.NW_RATE_CELL_CUR rc 
            on enr.CDE_RATE_CELL_MCO = rc.CDE_RATE_CELL
        left join MHDWPROD.NW.NW_RATE_CELL_CUR rc2 
            on enr.CDE_RATE_CELL_BH = rc2.CDE_RATE_CELL
        left join MHDWPROD.NW.NW_PROVIDER mco
            on enr.MCO_PRV_SEQ = mco.PRV_SEQ and mco.CDE_PROV_TYPE in ('01', '17', '20', '80', '81', '91', '97', '30', 'A2', 'A4')
        left join MHDWPROD.nw.nw_member_addr_hist addr
            on addr.sak_recip = enr.sak_recip and wk.enddt between addr.valid_from_dt_tm and addr.valid_thru_dt_tm and addr.cde_addr_usage = 'MR'
        left join MHDWPROD.nw.nw_zip_cur zip 
            on ZIP.ADR_MAIL_ZIP = addr.ADR_ZIP_CODE
  where 
            enr.DTE_EFFECTIVE <= to_date(%str(&EndDate), 'YYYY-MM-DD') and 
            enr.DTE_END >= to_date(%str(&StartDate), 'YYYY-MM-DD') and
            to_date(%str(&wh_thru_dt), 'YYYY-MM-DD') between enr.VALID_FROM_DT_TM and enr.VALID_THRU_DT_TM and
            enr.CDE_MANAGED_CARE_PLAN in ('PCC', 'MCO-MassHealth', 'ACOA-MassHealth', 'ACOB-MassHealth') and
            enr.ind_active = 'Y'
  /*debugging order by id_medicaid, startdt, enr.dte_effective*/
 group by  
 	wk.Timeperiod, 
  calendar_year, 
  num_month, 
  firstdtweek, 
  startdt, 
  enddt,     
  case when cde_managed_care_plan = 'PCC' then 'PCC' else mco.dsc_prov_type end ,
  case when cde_managed_care_plan = 'PCC' then 'PCC' else mco.name_dsp end ,
  /*04/21/2020: Yi-Ling added*/
   case when  rc.CDE_RATE_CATEGORY  in ('RC01_Adult') then 'RC-I Adult'    
        when  rc.CDE_RATE_CATEGORY  in ('RC01_Child') then 'RC-I Child'     
        when  rc.CDE_RATE_CATEGORY  in ('RC02_Adult') then 'RC-II Adult'
        when  rc.CDE_RATE_CATEGORY  in ('RC02_Child') then 'RC-II Child'
        when  rc.CDE_RATE_CATEGORY  in ('RC9', 'RC09') then 'RC-IX'
        when  rc.CDE_RATE_CATEGORY  in ( 'RC10') then 'RC-X' 
        when rc2.CDE_RATE_CATEGORY in  ('RC01_Adult' ) then 'RC-I Adult'  
        when rc2.CDE_RATE_CATEGORY in  ('RC01_Child') then 'RC-I Child'  
        when rc2.CDE_RATE_CATEGORY in ('RC02_Adult') then 'RC-II Adult' 
        when rc2.CDE_RATE_CATEGORY in ('RC02_Child') then 'RC-II Child' 
        when rc2.CDE_RATE_CATEGORY in ('RC9', 'RC09')  then 'RC-IX'
        when rc2.CDE_RATE_CATEGORY in ('RC10') then 'RC-X'
        else 'NULL' 
  end,
   DSC_MC_REGION_CAP, 
   dsc_mc_region_enroll,
   service_area
 
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_01_SNAPSHOT);


/************** 2 ***************/

/* Join enrollment and snapshots for staging************************************************************************/
 
/*Table DATA.ALLTAB created, with  433,147   443,650 451,628rows and 16 columns.*/
/* union enrollments/disenrollments and snapshort in one table */


/* Create ACOENR_03_ALLDATA in Snowflake using pass-through.
   Pass-through allows CREATE OR REPLACE and avoids SAS libname "table already exists" errors. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_03_ALLDATA as
        select 
           type, Timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt,
           provtype, provname, RateCat, dsc_enrdis, cde_enrdis, 
           DSC_MC_REGION_CAP, dsc_mc_region_enroll, mbrs 
        from ACOENR_02_ENRDIS

        union all

        select 
           type, Timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt,
           provtype, provname, RateCat, dsc_enrdis, cde_enrdis, 
           DSC_MC_REGION_CAP, dsc_mc_region_enroll, avgmem as mbrs 
        from ACOENR_01_SNAPSHOT
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_03_ALLDATA);


/* ===== COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_03_ALLDATA distribution checks ===== */
%macro SKIP_DEBUG_CHECK_ACOENR_03();
/************** 4 ***************/
/* test distributions ************************************************************************/
 



/*CHECK*/
proc sql;
select type, provtype, provname, count(*)
from MY_SNOW1.ACOENR_03_allData 
group by type, provtype, provname
order by type, provtype, provname;
run;

proc sql;
select type, DSC_MC_REGION_CAP, dsc_mc_region_enroll, count(*) 
from MY_SNOW1.ACOENR_03_allData 
group by type, DSC_MC_REGION_CAP, dsc_mc_region_enroll
order by type, DSC_MC_REGION_CAP, dsc_mc_region_enroll;
run;



%mend SKIP_DEBUG_CHECK_ACOENR_03;
/* ===== END COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_03_ALLDATA distribution checks ===== */

/******************************dont run - this code shows some transparency on how the xwalks are built*******************************************/
 
/*
Push data to xwalk table via code below 
proc sql;
create table MY_SNOW1.XWALK_ACOENRRPT_NAMEMAP as
select distinct *
from data.plan_names_share_fin4b;
quit;

--manual change name of steward to revere to enable trending 

execute mha.copy_table_if_exists('XWALK_ACOENRRPT_NAMEMAP','BONEYJ');


proc sql; 
select enroll_disenroll, cde, code, max(group) as group
from data.codes_latest_v2
group by enroll_disenroll, cde, code
order by enroll_disenroll, cde, code; 
quit;

proc sql;
create table MY_SNOW1.XWALK_ACOENRRPT_ENRDIS as
select enroll_disenroll, cde, code, max(group) as RptGroup
from data.codes_latest_v2
group by enroll_disenroll, cde, code
order by enroll_disenroll, cde, code;
quit;

--manual change name of steward to revere to enable trending 

execute mha.copy_table_if_exists('XWALK_ACOENRRPT_ENRDIS','BONEYJ');
--to delete mha.drop_if_exists('XWALK_ACOENRRPT_ENRDIS'); -- this would drop table that could then be reloaded
*/

/* Add mapping codes for ACO names and enrollment/leaving reasons ************************************************************************/
 
/*Table DATA.MYTABLE created, with    433,147 443,650 451,628 and 18 columns.*/
/* join to ACO table to get ACOs short names-changed 3-11-21 for CCC and PHS name changes */
/*NAME CHANGE AS OF 12/6/2022---
PROVTYPE	PROVNAME	ACO_NAME	n
30 - HEALTH MAINTENANCE ORGANIZATION	WELLSENSE ESSENTIAL - MCO PLAN	MCO-BMC	104671*/

/************** 5 ***************/
/*DROP TABLE my_snow1.ACOENR_04_allData_name;*/
/* Create ACOENR_04_ALLDATA_NAME in Snowflake using pass-through. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_04_ALLDATA_NAME as
        select a.*, b.prov_type,
          c."RptGroup" as enrdisClass,
          b.aco_name as provname2,
          case when provtype = '30 - HEALTH MAINTENANCE ORGANIZATION' then 'MCO'
            when provtype = 'A2 - ACO A' then 'ACO A'
            when provtype = 'A4 - ACO B FULL IMPLEMENTATION ONLY' then 'ACO B'
            when provtype in ('PCC','ZA - PCC') then 'PCC'
            else 'MCO' end as provtype2
        from ACOENR_03_ALLDATA a
        left join MHDWPROD.MHA.XWALK_ACOENRRPT_NAMEMAP b on a.provname = b.provname
        left join MHDWPROD.MHA.XWALK_ACOENRRPT_ENRDIS c on a.cde_enrdis = c.cde
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_04_ALLDATA_NAME);

/* ===== COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_04_ALLDATA_NAME join checks ===== */
%macro SKIP_DEBUG_CHECK_ACOENR_04();
/************** 6 ***************/

/****check joins work***********************************************************************/

proc sql;
select type, provtype, provtype2, provname, provname2, count(*), sum(mbrs)
from my_snow1.ACOENR_04_allData_name
group by type, provtype, provtype2, provname, provname2
order by type, provtype, provtype2, provname, provname2;
run;

proc sql;
select type, enrdisclass, cde_enrdis , count(*), sum(mbrs)
from my_snow1.ACOENR_04_allData_name
group by type, enrdisclass, cde_enrdis 
order by type, enrdisclass, cde_enrdis ;
run;

proc sql;
select type, RateCat, count(*), sum(mbrs)
from my_snow1.ACOENR_04_allData_name
group by type, RateCat 
order by type, RateCat;
run;



%mend SKIP_DEBUG_CHECK_ACOENR_04;
/* ===== END COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_04_ALLDATA_NAME join checks ===== */

/************** 7 ***************/
/* Add a summary line in addition to RC breakouts ************************************************************************/
 
/* this just adds a summary (all) table and RC breakouts togetherin a single table to aid reporting structure*/
/* Create ACOENR_05_CLEANREP_NAME in Snowflake using pass-through. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_05_CLEANREP_NAME as
        select 'All' as membertype,
            type, timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt, provtype2, provname2,
            enrdisClass, DSC_MC_REGION_CAP, dsc_mc_region_enroll,
            sum(mbrs) as mbrs
        from ACOENR_04_ALLDATA_NAME
        where provtype not in ('ZZ - ACOB PCCB')
        group by 
            type, timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt, provtype2, provname2,
            enrdisClass, DSC_MC_REGION_CAP, dsc_mc_region_enroll
        union all  
        select RateCat as membertype,
            type, timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt, provtype2, provname2,
            enrdisClass, DSC_MC_REGION_CAP, dsc_mc_region_enroll,
            sum(mbrs) as mbrs
        from ACOENR_04_ALLDATA_NAME
        where provtype not in ('ZZ - ACOB PCCB')
        group by 
            membertype,
            type, timeperiod, calendar_year, num_month, firstdtweek, startdt, enddt, provtype2, provname2,
            enrdisClass, DSC_MC_REGION_CAP, dsc_mc_region_enroll
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_05_CLEANREP_NAME);

/* ===== COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_05_CLEANREP_NAME checks ===== */
%macro SKIP_DEBUG_CHECK_ACOENR_05();
/************** 8 ***************/
/****check joins work***********************************************************************/

proc sql;
select membertype, type, provtype2, provname2, count(*), sum(mbrs)
from my_snow1.ACOENR_05_CleanRep_name
group by membertype, type, provtype2,  provname2
order by membertype, type, provtype2,  provname2;
run;

proc sql;
select membertype, type, enrdisclass, count(*), sum(mbrs)
from my_snow1.ACOENR_05_CleanRep_name
group by membertype, type, enrdisclass
order by membertype, type, enrdisclass;
run;


proc sql;
select firstdtweek, startdt, enddt,type, sum(mbrs) 
from my_snow1.ACOENR_05_CleanRep_name
group by firstdtweek, type,startdt, enddt
order by firstdtweek, type,startdt, enddt;
run;



%mend SKIP_DEBUG_CHECK_ACOENR_05;
/* ===== END COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_05_CLEANREP_NAME checks ===== */

/************** 9 ***************/


/* Add Percents ************************************************************************/
 
/* Make % per type */



/* Create ACOENR_06_REP_W_PERC in Snowflake using pass-through. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        create or replace table ACOENR_06_REP_W_PERC as
        select a.*, b.totmem, a.mbrs/b.totmem as pcttype, 'As_of_&repdt.' as Running_DT
        from ACOENR_05_CLEANREP_NAME a 
        inner join (
            select type, membertype, enrdisClass, firstdtweek, sum(mbrs) as totmem 
            from ACOENR_05_CLEANREP_NAME 
            group by type, membertype, enrdisClass, firstdtweek
        ) b 
          on a.type = b.type and a.membertype=b.membertype and 
             (a.enrdisClass = b.enrdisClass or a.enrdisClass is null) and a.firstdtweek = b.firstdtweek
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Create ACOENR_06_REP_W_PERC);

/* ===== COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_06_REP_W_PERC checks ===== */
%macro SKIP_DEBUG_CHECK_ACOENR_06();
/************** 10 ***************/
/****check joins work***********************************************************************/

proc sql;
select type, membertype, enrdisclass, firstdtweek, sum(mbrs), sum(totmem), min(totmem), max(totmem), sum(pcttype)
from my_snow1.ACOENR_06_Rep_w_perc
group by type, membertype, enrdisclass, firstdtweek
order by type, membertype, enrdisclass, firstdtweek;
quit;



%mend SKIP_DEBUG_CHECK_ACOENR_06;
/* ===== END COMMENTED OUT DEBUG/CHECK SECTION: ACOENR_06_REP_W_PERC checks ===== */

/*WORKS*/
/************** 11 ***************/
/**Create a snapshot and enrollment agg tables to flow into the report********************************/
/***recast region/svc area variables to work for now**************************************************/

/* IMPORTANT:
   Build the permanent SAS report datasets using the same LIBNAME method as the
   trusted manual report. The prior pass-through extraction changed the numeric
   representation of MBRS in SAS and caused the false 112,020,077 validation total.
   The Snowflake table itself was correct at 1,120,077. */

proc sql;
    create table data.myEnrAgg2 as
    select a.*,
           a.DSC_MC_REGION_CAP as MCO_REGION,
           a.dsc_mc_region_enroll as SERVICE_AREA
    from my_snow1.ACOENR_06_REP_W_PERC a
    where type ne 'snapshot';
quit;

%stop_if_sql_error(step=Create current-run DATA.MYENRAGG2);

proc sql;
    create table data.myCaseload2 as
    select a.*,
           a.DSC_MC_REGION_CAP as MCO_REGION,
           a.dsc_mc_region_enroll as SERVICE_AREA
    from my_snow1.ACOENR_06_REP_W_PERC a
    where type = 'snapshot';
quit;

%stop_if_sql_error(step=Create current-run DATA.MYCASELOAD2);

proc sql;
    create table data.code_xwalk as
    select *
    from my_snow1.XWALK_ACOENRRPT_ENRDIS;
quit;

%stop_if_sql_error(step=Create DATA.CODE_XWALK);

/* Verify that the local SAS report datasets were rebuilt in this run. */
proc sql noprint;
    select count(*) into :LOCAL_CASELOAD_ROWS trimmed
    from data.myCaseload2;

    select count(*) into :LOCAL_ENR_ROWS trimmed
    from data.myEnrAgg2;
quit;

%macro stop_if_local_tables_empty;
    %if %length(%superq(LOCAL_CASELOAD_ROWS)) = 0 or
        %length(%superq(LOCAL_ENR_ROWS)) = 0 %then %do;
        %put ERROR: Local report table row counts were not populated.;
        %abort cancel;
    %end;

    %if %sysevalf(&LOCAL_CASELOAD_ROWS <= 0) %then %do;
        %put ERROR: DATA.MYCASELOAD2 has zero rows. Program stopped.;
        %abort cancel;
    %end;

    %if %sysevalf(&LOCAL_ENR_ROWS <= 0) %then %do;
        %put ERROR: DATA.MYENRAGG2 has zero rows. Program stopped.;
        %abort cancel;
    %end;
%mend stop_if_local_tables_empty;

%stop_if_local_tables_empty;

%put NOTE: CURRENT-RUN LOCAL TABLES: MYCASELOAD2=&LOCAL_CASELOAD_ROWS rows;
%put NOTE: CURRENT-RUN LOCAL TABLES: MYENRAGG2=&LOCAL_ENR_ROWS rows;

/*CHECK NUMBERS  1,258,071*/
proc sql;
    connect using my_snow1;

    create table data.myCaseload2A as
    select *
    from connection to my_snow1
    (
        select sum(MBRS) / 2 as adjusted_mb_count
        from MHDWPROD.MHA.ACOENR_01_SNAPSHOT
        where type = 'snapshot'
          and FIRSTDTWEEK = 20240601
    );

    disconnect from my_snow1;
quit;


/******************************************************************************************
 STEP 4A - FRESHNESS / CURRENT-MONTH VALIDATION BEFORE QC AND EXCEL

 This check proves that:
   - ACOENR_01_SNAPSHOT was rebuilt;
   - ACOENR_06_REP_W_PERC contains the current report month;
   - DATA.MYCASELOAD2 contains the same current-month rows;
   - the report will not continue on a stale prior-week SAS dataset.
******************************************************************************************/

proc sql noprint;
    connect using my_snow1;

    create table data.current_run_validation as
    select *
    from connection to my_snow1
    (
        with current_month as
        (
            select to_number(to_char(date_trunc('month', current_date()), 'YYYYMMDD')) as month_id
        )
        select
            c.month_id,
            count(*) as current_month_rows,
            round(sum(case when r.membertype='All' then r.mbrs else 0 end),0) as current_month_total,
            min(r.Running_DT) as min_running_dt,
            max(r.Running_DT) as max_running_dt
        from current_month c
        left join MHDWPROD.MHA.ACOENR_06_REP_W_PERC r
          on r.firstdtweek=c.month_id
         and r.type='snapshot'
         and r.provtype2 not in ('ZZ - ACOB PCCB')
        group by c.month_id
    );

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Current-month Snowflake validation);

proc sql;
    create table data.local_current_validation as
    select
        v.month_id,
        count(c.firstdtweek) as local_current_month_rows,
        round(sum(case when c.membertype='All' then c.mbrs else 0 end),1)
            as local_current_month_total
    from data.current_run_validation v
    left join data.myCaseload2 c
      on c.firstdtweek=v.month_id
     and c.provtype2 not in ('ZZ - ACOB PCCB')
    group by v.month_id;
quit;

%stop_if_sql_error(step=Local current-month validation);

/* Create one validation result row without performing arithmetic in macro logic.
   This prevents blank or character macro values from causing %EVAL/%SYSEVALF errors. */
proc sql;
    create table data.current_run_validation_final as
    select
        s.month_id,
        coalesce(s.current_month_rows,0) as current_month_rows,
        s.current_month_total,
        s.min_running_dt,
        s.max_running_dt,
        coalesce(l.local_current_month_rows,0) as local_current_month_rows,
        l.local_current_month_total,
        (s.current_month_total-l.local_current_month_total) as total_difference,
        case
            when coalesce(s.current_month_rows,0) <= 0 then 'NO_SNOWFLAKE_ROWS'
            when coalesce(l.local_current_month_rows,0) <= 0 then 'NO_LOCAL_ROWS'
            when missing(s.current_month_total) then 'NO_SNOWFLAKE_TOTAL'
            when missing(l.local_current_month_total) then 'NO_LOCAL_TOTAL'
            when abs(round(s.current_month_total,1)-round(l.local_current_month_total,1)) >= 1 then 'TOTAL_MISMATCH'
            else 'PASS'
        end as validation_status length=30
    from data.current_run_validation s
    left join data.local_current_validation l
      on s.month_id=l.month_id;
quit;

%stop_if_sql_error(step=Final freshness validation);

proc sql noprint;
    select month_id,
           current_month_rows,
           current_month_total,
           min_running_dt,
           max_running_dt,
           local_current_month_rows,
           local_current_month_total,
           total_difference,
           validation_status
      into :VALID_MONTH_ID trimmed,
           :VALID_MONTH_ROWS trimmed,
           :VALID_MONTH_TOTAL trimmed,
           :VALID_MIN_RUNNING_DT trimmed,
           :VALID_MAX_RUNNING_DT trimmed,
           :LOCAL_CURRENT_MONTH_ROWS trimmed,
           :LOCAL_CURRENT_MONTH_TOTAL trimmed,
           :VALID_TOTAL_DIFFERENCE trimmed,
           :VALIDATION_STATUS trimmed
    from data.current_run_validation_final;
quit;

%macro stop_if_stale_or_missing;
    %if %superq(VALIDATION_STATUS) ne PASS %then %do;
        %put ERROR: Current-run freshness validation failed.;
        %put ERROR: VALIDATION_STATUS=%superq(VALIDATION_STATUS);;
        %put ERROR: MONTH=%superq(VALID_MONTH_ID);;
        %put ERROR: SNOWFLAKE_ROWS=%superq(VALID_MONTH_ROWS);;
        %put ERROR: SNOWFLAKE_TOTAL=%superq(VALID_MONTH_TOTAL);;
        %put ERROR: LOCAL_ROWS=%superq(LOCAL_CURRENT_MONTH_ROWS);;
        %put ERROR: LOCAL_TOTAL=%superq(LOCAL_CURRENT_MONTH_TOTAL);;
        %put ERROR: TOTAL_DIFFERENCE=%superq(VALID_TOTAL_DIFFERENCE);;
        %abort cancel;
    %end;
%mend stop_if_stale_or_missing;

%stop_if_stale_or_missing;

%put NOTE: ===============================================================;
%put NOTE: FRESHNESS CHECK PASSED.;
%put NOTE: CURRENT MONTH=&VALID_MONTH_ID.;
%put NOTE: CURRENT MONTH ROWS IN SNOWFLAKE=&VALID_MONTH_ROWS.;
%put NOTE: CURRENT MONTH TOTAL IN SNOWFLAKE=&VALID_MONTH_TOTAL.;
%put NOTE: CURRENT MONTH ROWS IN LOCAL SAS=&LOCAL_CURRENT_MONTH_ROWS.;
%put NOTE: CURRENT MONTH TOTAL IN LOCAL SAS=&LOCAL_CURRENT_MONTH_TOTAL.;
%put NOTE: SNOWFLAKE-LOCAL TOTAL DIFFERENCE=&VALID_TOTAL_DIFFERENCE.;
%put NOTE: RUNNING_DT RANGE=&VALID_MIN_RUNNING_DT to &VALID_MAX_RUNNING_DT.;
%put NOTE: ===============================================================;

/* Print plan totals to the SAS output/log for direct comparison with manual. */
proc sql;
    title "PRE-EXPORT CURRENT-MONTH PLAN TOTALS - &VALID_MONTH_ID";
    select provtype2,
           round(sum(mbrs),1) as members format=comma18.1
    from data.myCaseload2
    where type='snapshot'
      and membertype='All'
      and firstdtweek=&VALID_MONTH_ID
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by provtype2
    order by provtype2;
    title;
quit;


/******************************************************************************************
 STEP 5 - QC WORKBOOK AND HISTORY - EMAIL TEMPORARILY DISABLED

 This QC block:
   - Uses the most recent Snowflake history RUN_DT before today's run.
   - Does not place QC_PRIOR_RUN_DT_CHAR inside Snowflake SQL.
   - Safely handles an empty QC history table.
   - Replaces today's history rows during same-day reruns.
   - Does not modify the working report tables or calculations.
******************************************************************************************/

%macro RUN_ACO_QC_AND_EMAIL; /* Name retained for compatibility; email call is disabled */

/* These values must remain available after the QC macro finishes
   because the email is sent by a separate macro. */
%global QC_STATUS QC_FAIL_COUNT QC_WARN_COUNT QC_INFO_COUNT
        DISTRIBUTION_DECISION REPORT_INTEGRITY RECOMMENDED_ACTION
        QC_PRIOR_RUN_DT_CHAR;
%local QC_HAS_PRIOR;

%let QC_STATUS=UNKNOWN;
%let QC_FAIL_COUNT=0;
%let QC_WARN_COUNT=0;
%let QC_INFO_COUNT=0;
%let DISTRIBUTION_DECISION=UNKNOWN;
%let REPORT_INTEGRITY=PASS;
%let RECOMMENDED_ACTION=Review QC results before distribution.;
%let QC_PRIOR_RUN_DT_CHAR=;
%let QC_HAS_PRIOR=0;

/* Remove work tables left by an earlier failed QC attempt. */
proc datasets library=data nolist;
    delete QC_Current_Matrix
           QC_Current_Matrix2
           QC_Prior_Matrix
           QC_Check_Matrix
           QC_Prior_Run_Info
           QC_Flag_Summary
           QC_History_Stats
           QC_Check_Base
           QC_Check_Base0
           QC_Check_Base1
           QC_Matrix_Long
           QC_Email_Issues
           QC_Summary
           QC_History_Load
           QC_History_Verify;
quit;

/* Ensure the permanent Snowflake history table exists. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        CREATE TABLE IF NOT EXISTS ACOENR_QC_HISTORY_MATRIX
        (
            RUN_DT DATE,
            RUN_DTTM TIMESTAMP_NTZ,
            REPORT_SECTION VARCHAR,
            CATEGORY VARCHAR,
            PLAN_TYPE VARCHAR,
            MONTH_ID NUMBER,
            MBRS FLOAT
        )
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%if &sqlrc ne 0 %then %do;
    %put ERROR: Could not create or verify ACOENR_QC_HISTORY_MATRIX.;
    %return;
%end;

/* Read the prior date for display and a numeric prior-run indicator.
   The comparison query below independently selects MAX(RUN_DT), so it does
   not depend on macro-variable substitution inside Snowflake SQL. */
proc sql noprint;
    connect using my_snow1;

    create table data.QC_Prior_Run_Info as
    select *
    from connection to my_snow1
    (
        select
            coalesce(to_char(max(RUN_DT), 'YYYY-MM-DD'),'') as PRIOR_RUN_DT_CHAR,
            case when max(RUN_DT) is null then 0 else 1 end as HAS_PRIOR
        from MHDWPROD.MHA.ACOENR_QC_HISTORY_MATRIX
        where RUN_DT < to_date(&today, 'YYYY-MM-DD')
    );

    disconnect from my_snow1;
quit;

proc sql noprint;
    select coalescec(strip(PRIOR_RUN_DT_CHAR),''),
           coalesce(HAS_PRIOR,0)
      into :QC_PRIOR_RUN_DT_CHAR trimmed,
           :QC_HAS_PRIOR trimmed
    from data.QC_Prior_Run_Info;
quit;

%if %length(%superq(QC_PRIOR_RUN_DT_CHAR)) = 0 %then
    %let QC_PRIOR_RUN_DT_CHAR=Not available;




%put NOTE: ===============================================;
%put NOTE: QC_HAS_PRIOR=&QC_HAS_PRIOR.;
%put NOTE: QC_PRIOR_RUN_DT_CHAR=[%superq(QC_PRIOR_RUN_DT_CHAR)];
%put NOTE: ===============================================;


/********************************************************************
 BUILD ONLY THE FIVE APPROVED QC SUBTOTAL CATEGORIES

 Expected:
   CASELOAD       All                         41 rows
   ENROLLMENT     Auto-Assigned               41 rows
   ENROLLMENT     Family Based Assignment     41 rows
   ENROLLMENT     Member Choice               41 rows
   DISENROLLMENT  CSR - Member Driven         41 rows

 Total expected when 41 months are present: 205 rows
********************************************************************/

proc sql;
    create table data.QC_Current_Matrix as

    /* 1. CASELOAD - All subtotal */
    select
        'CASELOAD' as REPORT_SECTION length=20,
        'All' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from my_snow1.ACOENR_06_REP_W_PERC
    where type='snapshot'
      and membertype='All'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 2. ENROLLMENT - Auto-Assigned subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Auto-Assigned' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from my_snow1.ACOENR_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Auto-Assigned'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 3. ENROLLMENT - Family Based Assignment subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Family Based Assignment' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from my_snow1.ACOENR_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Family Based Assignment'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 4. ENROLLMENT - Member Choice subtotal */
    select
        'ENROLLMENT' as REPORT_SECTION length=20,
        'Member Choice' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from my_snow1.ACOENR_06_REP_W_PERC
    where type='enrollment'
      and membertype='All'
      and strip(enrdisClass)='Member Choice'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek


    union all


    /* 5. DISENROLLMENT - CSR - Member Driven subtotal */
    select
        'DISENROLLMENT' as REPORT_SECTION length=20,
        'CSR - Member Driven' as CATEGORY length=60,
        'TOTAL' as PLAN_TYPE length=30,
        firstdtweek as MONTH_ID,
        round(sum(mbrs),1) as MBRS format=comma18.2
    from my_snow1.ACOENR_06_REP_W_PERC
    where type='disenrollment'
      and membertype='All'
      and strip(enrdisClass)='CSR - Member Driven'
      and provtype2 not in ('ZZ - ACOB PCCB')
    group by firstdtweek
    ;
quit;

%stop_if_sql_error(step=Create five-category QC current matrix);


/********************************************************************
 CONSOLIDATE AND STANDARDIZE CURRENT MATRIX
********************************************************************/

proc sql;
    create table data.QC_Current_Matrix2 as
    select
        strip(REPORT_SECTION) as REPORT_SECTION length=20,
        strip(CATEGORY)       as CATEGORY length=60,
        strip(PLAN_TYPE)      as PLAN_TYPE length=30,
        MONTH_ID,
        sum(MBRS) as CURRENT_MBRS format=comma18.2
    from data.QC_Current_Matrix
    where not missing(CATEGORY)
      and strip(CATEGORY) ne ''
      and strip(CATEGORY) ne 'NULL'
      and strip(PLAN_TYPE)='TOTAL'
    group by
        calculated REPORT_SECTION,
        calculated CATEGORY,
        calculated PLAN_TYPE,
        MONTH_ID;
quit;

%stop_if_sql_error(step=Create consolidated five-category QC matrix);


/********************************************************************
 VERIFY CATEGORY COUNTS AND TOTAL ROWS
********************************************************************/

proc sql;
    create table data.QC_Current_Verification as
    select
        REPORT_SECTION,
        CATEGORY,
        count(*) as ROW_COUNT,
        min(MONTH_ID) as FIRST_MONTH,
        max(MONTH_ID) as LAST_MONTH
    from data.QC_Current_Matrix2
    group by
        REPORT_SECTION,
        CATEGORY
    order by
        REPORT_SECTION,
        CATEGORY;
quit;

proc print data=data.QC_Current_Verification noobs;
    title "QC CURRENT MATRIX VERIFICATION";
run;
title;


proc sql noprint;
    select count(*)
      into :QC_CURRENT_MATRIX_ROWS trimmed
    from data.QC_Current_Matrix2;

    select count(distinct cats(
               strip(REPORT_SECTION),'|',
               strip(CATEGORY)
           ))
      into :QC_CURRENT_CATEGORY_COUNT trimmed
    from data.QC_Current_Matrix2;
quit;

%if %length(%superq(QC_CURRENT_MATRIX_ROWS))=0 %then
    %let QC_CURRENT_MATRIX_ROWS=0;

%if %length(%superq(QC_CURRENT_CATEGORY_COUNT))=0 %then
    %let QC_CURRENT_CATEGORY_COUNT=0;

%put NOTE: ===============================================================;
%put NOTE: QC CURRENT CATEGORY COUNT=&QC_CURRENT_CATEGORY_COUNT.;
%put NOTE: QC CURRENT MATRIX ROWS=&QC_CURRENT_MATRIX_ROWS.;
%put NOTE: ===============================================================;











/* Compare with the most recent prior weekly run when one exists. */
%if %sysevalf(&QC_HAS_PRIOR = 1) %then %do;

    /* Most recent prior weekly matrix. */
    proc sql;
        connect using my_snow1;

        create table data.QC_Prior_Matrix as
        select *
        from connection to my_snow1
        (
            select
                trim(REPORT_SECTION) as REPORT_SECTION,
                trim(CATEGORY)       as CATEGORY,
                trim(PLAN_TYPE)      as PLAN_TYPE,
                MONTH_ID,
                sum(MBRS) as PRIOR_MBRS
            from MHDWPROD.MHA.ACOENR_QC_HISTORY_MATRIX
            where RUN_DT =
                  (
                    select max(RUN_DT)
                    from MHDWPROD.MHA.ACOENR_QC_HISTORY_MATRIX
                    where RUN_DT < to_date(&today, 'YYYY-MM-DD')
                  )
              and PLAN_TYPE = 'TOTAL'
              and trim(CATEGORY) <> 'NULL'
            group by
                trim(REPORT_SECTION),
                trim(CATEGORY),
                trim(PLAN_TYPE),
                MONTH_ID
        );

        disconnect from my_snow1;
    quit;

    /* Historical weekly-change statistics.

       A historical pair is one saved run compared with the immediately
       preceding saved run for the same section/category/month.

       Statistics are calculated separately for:
         CURRENT_MTD
         PREVIOUS_MONTH
         OLDER_MONTH

       Adaptive thresholds are activated only after at least 8 historical
       weekly pairs exist. Until then, fixed business thresholds are used. */
    proc sql;
        connect using my_snow1;

        create table data.QC_History_Stats as
        select *
        from connection to my_snow1
        (
            with ordered_history as
            (
                select
                    RUN_DT,
                    trim(REPORT_SECTION) as REPORT_SECTION,
                    trim(CATEGORY)       as CATEGORY,
                    trim(PLAN_TYPE)      as PLAN_TYPE,
                    MONTH_ID,
                    MBRS,
                    lag(MBRS) over
                    (
                        partition by
                            trim(REPORT_SECTION),
                            trim(CATEGORY),
                            trim(PLAN_TYPE),
                            MONTH_ID
                        order by RUN_DT
                    ) as PRIOR_MBRS,

                    case
                        when MONTH_ID =
                             to_number(to_char(date_trunc('month',RUN_DT),'YYYYMMDD'))
                            then 'CURRENT_MTD'
                        when MONTH_ID =
                             to_number(to_char(dateadd(month,-1,date_trunc('month',RUN_DT)),'YYYYMMDD'))
                            then 'PREVIOUS_MONTH'
                        else 'OLDER_MONTH'
                    end as MONTH_GROUP

                from MHDWPROD.MHA.ACOENR_QC_HISTORY_MATRIX
                where PLAN_TYPE = 'TOTAL'
                  and trim(CATEGORY) <> 'NULL'
            ),
            weekly_pairs as
            (
                select
                    REPORT_SECTION,
                    CATEGORY,
                    PLAN_TYPE,
                    MONTH_GROUP,
                    abs(MBRS - PRIOR_MBRS) as ABS_WEEKLY_DIFF
                from ordered_history
                where PRIOR_MBRS is not null
            )
            select
                REPORT_SECTION,
                CATEGORY,
                PLAN_TYPE,
                MONTH_GROUP,
                count(*) as HIST_PAIR_COUNT,
                avg(ABS_WEEKLY_DIFF) as AVG_ABS_DIFF,
                coalesce(stddev_samp(ABS_WEEKLY_DIFF),0) as STD_ABS_DIFF
            from weekly_pairs
            group by
                REPORT_SECTION,
                CATEGORY,
                PLAN_TYPE,
                MONTH_GROUP
        );

        disconnect from my_snow1;
    quit;

    /* Step 1: Join current and prior totals and derive MONTH_GROUP.
       MONTH_GROUP is created here first because SAS PROC SQL cannot use a
       CALCULATED column inside another JOIN condition in the same query. */
    proc sql;
        create table data.QC_Check_Base0 as
        select
            coalesce(a.REPORT_SECTION,b.REPORT_SECTION) as REPORT_SECTION length=20,
            coalesce(a.CATEGORY,b.CATEGORY)             as CATEGORY length=60,
            coalesce(a.PLAN_TYPE,b.PLAN_TYPE)           as PLAN_TYPE length=30,
            coalesce(a.MONTH_ID,b.MONTH_ID)             as MONTH_ID,

            input("%superq(QC_PRIOR_RUN_DT_CHAR)", yymmdd10.)
                as PRIOR_RUN_DT format=date9.,
            coalesce(b.PRIOR_MBRS,0) as PRIOR_MBRS format=comma18.2,

            input("&today_char.", yymmdd10.)
                as CURRENT_RUN_DT format=date9.,
            coalesce(a.CURRENT_MBRS,0) as CURRENT_MBRS format=comma18.2

        from data.QC_Current_Matrix2 a
        full join data.QC_Prior_Matrix b
            on a.REPORT_SECTION = b.REPORT_SECTION
           and a.CATEGORY       = b.CATEGORY
           and a.PLAN_TYPE      = b.PLAN_TYPE
           and a.MONTH_ID       = b.MONTH_ID;
    quit;

    data data.QC_Check_Base1;
        set data.QC_Check_Base0;

        length MONTH_GROUP $20;
        format DIFF_MBRS comma18.2 PCT_CHANGE percent9.2;

        DIFF_MBRS = CURRENT_MBRS - PRIOR_MBRS;

        if PRIOR_MBRS > 0 then
            PCT_CHANGE = DIFF_MBRS / PRIOR_MBRS;
        else
            PCT_CHANGE = .;

        if MONTH_ID =
           input(put(intnx('month',
                          input("&today_char.",yymmdd10.),
                          0,'b'),yymmddn8.),8.)
        then MONTH_GROUP='CURRENT_MTD';

        else if MONTH_ID =
                input(put(intnx('month',
                               input("&today_char.",yymmdd10.),
                               -1,'b'),yymmddn8.),8.)
        then MONTH_GROUP='PREVIOUS_MONTH';

        else MONTH_GROUP='OLDER_MONTH';
    run;

    /* Step 2: Attach historical statistics using the already-created
       MONTH_GROUP column. */
    proc sql;
        create table data.QC_Check_Base as
        select
            a.*,
            coalesce(h.HIST_PAIR_COUNT,0) as HIST_PAIR_COUNT,
            coalesce(h.AVG_ABS_DIFF,0)    as AVG_ABS_DIFF format=comma18.2,
            coalesce(h.STD_ABS_DIFF,0)    as STD_ABS_DIFF format=comma18.2
        from data.QC_Check_Base1 a
        left join data.QC_History_Stats h
            on a.REPORT_SECTION = h.REPORT_SECTION
           and a.CATEGORY       = h.CATEGORY
           and a.PLAN_TYPE      = h.PLAN_TYPE
           and a.MONTH_GROUP    = h.MONTH_GROUP
        order by
            a.REPORT_SECTION,
            a.CATEGORY,
            a.PLAN_TYPE,
            a.MONTH_ID;
    quit;

    /* Final adaptive PASS/WARNING/FAIL logic.

       When at least 8 historical weekly pairs exist:
         WARNING = max(business warning floor, average + 2 standard deviations)
         FAIL    = max(business fail floor,    average + 3 standard deviations)

       Before 8 pairs exist, the business floors are used by themselves. */
    data data.QC_Check_Matrix;
        set data.QC_Check_Base;

        length QC_FLAG $25 THRESHOLD_METHOD $12;
        format WARNING_THRESHOLD FAIL_THRESHOLD comma18.2;

        select (MONTH_GROUP);
            when ('CURRENT_MTD') do;
                /* Current MTD is still developing during the month.
                   Large week-to-week movements are expected and should not
                   be treated like changes to closed historical months. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=15000;
                    FAIL_FLOOR=30000;
                end;
                else do;
                    WARNING_FLOOR=25000;
                    FAIL_FLOOR=50000;
                end;
            end;

            when ('PREVIOUS_MONTH') do;
                /* The immediately prior month can continue to settle because
                   of late eligibility and transaction updates. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=5000;
                    FAIL_FLOOR=15000;
                end;
                else do;
                    WARNING_FLOOR=5000;
                    FAIL_FLOOR=15000;
                end;
            end;

            otherwise do;
                /* Older closed months normally change by only about 20-40 members.

                   CASELOAD totals are very large (approximately 1.1M members).
                   A revision of 100-200 members is operationally small and should
                   trigger analyst review, not automatically block distribution.

                   For CASELOAD:
                     50-499 members = review warning
                     500+ members   = blocking failure

                   Enrollment/disenrollment categories retain the original
                   50 warning / 100 failure floors because their monthly totals
                   are much smaller. */
                if REPORT_SECTION='CASELOAD' then do;
                    WARNING_FLOOR=50;
                    FAIL_FLOOR=500;
                end;
                else do;
                    WARNING_FLOOR=50;
                    FAIL_FLOOR=100;
                end;
            end;
        end;

        if HIST_PAIR_COUNT >= 8 then do;
            THRESHOLD_METHOD='ADAPTIVE';
            WARNING_THRESHOLD=max(WARNING_FLOOR,
                                  AVG_ABS_DIFF + 2*STD_ABS_DIFF);
            FAIL_THRESHOLD=max(FAIL_FLOOR,
                               AVG_ABS_DIFF + 3*STD_ABS_DIFF);
        end;
        else do;
            THRESHOLD_METHOD='FIXED';
            WARNING_THRESHOLD=WARNING_FLOOR;
            FAIL_THRESHOLD=FAIL_FLOOR;
        end;

        if PRIOR_MBRS=0 and CURRENT_MBRS=0 then
            QC_FLAG='OK';

        /* During CURRENT_MTD, new/missing rows and large movement are review items,
           but they do not force an overall FAIL because the month is still developing. */
        else if MONTH_GROUP='CURRENT_MTD' then do;
            if PRIOR_MBRS=0 and CURRENT_MBRS>0 then
                QC_FLAG='YELLOW - New MTD Row';
            else if PRIOR_MBRS>0 and CURRENT_MBRS=0 then
                QC_FLAG='YELLOW - Missing MTD Row';
            else if abs(DIFF_MBRS) >= WARNING_THRESHOLD then
                QC_FLAG='YELLOW - Check';
            else
                QC_FLAG='OK';
        end;

        /* Closed months retain strict row-level failure handling. */
        else if PRIOR_MBRS=0 and CURRENT_MBRS>0 then
            QC_FLAG='NEW ROW';
        else if PRIOR_MBRS>0 and CURRENT_MBRS=0 then
            QC_FLAG='MISSING ROW';
        else if abs(DIFF_MBRS) >= FAIL_THRESHOLD then
            QC_FLAG='RED - Large Diff';
        else if abs(DIFF_MBRS) >= WARNING_THRESHOLD then
            QC_FLAG='YELLOW - Check';
        else
            QC_FLAG='OK';

        drop WARNING_FLOOR FAIL_FLOOR;
    run;

    proc sql noprint;
        /* Blocking failures prevent distribution. */
        select count(*)
          into :QC_FAIL_COUNT trimmed
        from data.QC_Check_Matrix
        where MONTH_GROUP ne 'CURRENT_MTD'
          and QC_FLAG in
            ('RED - Large Diff','MISSING ROW','NEW ROW');

        /* Review warnings require analyst review but do not automatically
           prevent distribution. New MTD rows are counted separately as
           informational because they are expected at the start of a month. */
        select count(*)
          into :QC_WARN_COUNT trimmed
        from data.QC_Check_Matrix
        where QC_FLAG in
            ('YELLOW - Check','YELLOW - Missing MTD Row');

        select count(*)
          into :QC_INFO_COUNT trimmed
        from data.QC_Check_Matrix
        where QC_FLAG='YELLOW - New MTD Row';
    quit;

    %if %length(%superq(QC_FAIL_COUNT))=0 %then %let QC_FAIL_COUNT=0;
    %if %length(%superq(QC_WARN_COUNT))=0 %then %let QC_WARN_COUNT=0;
    %if %length(%superq(QC_INFO_COUNT))=0 %then %let QC_INFO_COUNT=0;

    /* Technical QC status remains available for matrix/detail titles. */
    %if %sysevalf(&QC_FAIL_COUNT > 0) %then
        %let QC_STATUS=FAIL;
    %else %if %sysevalf(&QC_WARN_COUNT > 0) %then
        %let QC_STATUS=WARNING;
    %else
        %let QC_STATUS=PASS;

    /* Operational decision shown on the first worksheet. */
    %if %sysevalf(&QC_FAIL_COUNT > 0) %then %do;
        %let DISTRIBUTION_DECISION=DO NOT DISTRIBUTE;
        %let RECOMMENDED_ACTION=Resolve blocking QC failures before sharing the report.;
    %end;
    %else %if %sysevalf(&QC_WARN_COUNT > 0) %then %do;
        %let DISTRIBUTION_DECISION=REVIEW BEFORE DISTRIBUTION;
        %let RECOMMENDED_ACTION=Review highlighted warning rows and distribute after analyst approval.;
    %end;
    %else %do;
        %let DISTRIBUTION_DECISION=READY TO DISTRIBUTE;
        %let RECOMMENDED_ACTION=No blocking or review-level issues were detected.;
    %end;

%end;
%else %do;

    %let QC_STATUS=BASELINE_ONLY;
    %let QC_FAIL_COUNT=0;
    %let QC_WARN_COUNT=1;
    %let QC_INFO_COUNT=0;
    %let DISTRIBUTION_DECISION=REVIEW BEFORE DISTRIBUTION;
    %let RECOMMENDED_ACTION=No prior weekly baseline exists. Perform manual review before distribution.;

    data data.QC_Check_Matrix;
        length REPORT_SECTION $20 CATEGORY $60 PLAN_TYPE $30
               QC_FLAG $25 MONTH_GROUP $20 THRESHOLD_METHOD $12;
        format PRIOR_RUN_DT CURRENT_RUN_DT date9.
               PRIOR_MBRS CURRENT_MBRS DIFF_MBRS
               AVG_ABS_DIFF STD_ABS_DIFF
               WARNING_THRESHOLD FAIL_THRESHOLD comma18.2
               PCT_CHANGE percent9.2;

        REPORT_SECTION = 'BASELINE';
        CATEGORY = 'No prior weekly QC run found';
        PLAN_TYPE = 'TOTAL';
        MONTH_ID = .;
        PRIOR_RUN_DT = .;
        PRIOR_MBRS = .;
        CURRENT_RUN_DT = input("&today_char.", yymmdd10.);
        CURRENT_MBRS = .;
        DIFF_MBRS = .;
        PCT_CHANGE = .;
        MONTH_GROUP = '';
        HIST_PAIR_COUNT = 0;
        AVG_ABS_DIFF = .;
        STD_ABS_DIFF = .;
        WARNING_THRESHOLD = .;
        FAIL_THRESHOLD = .;
        THRESHOLD_METHOD = 'FIXED';
        QC_FLAG = 'BASELINE ONLY';
        output;
    run;

%end;

%put NOTE: ===============================================;
%put NOTE: QC_STATUS=&QC_STATUS.;
%put NOTE: DISTRIBUTION_DECISION=&DISTRIBUTION_DECISION.;
%put NOTE: REPORT_INTEGRITY=&REPORT_INTEGRITY.;
%put NOTE: QC_FAIL_COUNT=&QC_FAIL_COUNT.;
%put NOTE: QC_WARN_COUNT=&QC_WARN_COUNT.;
%put NOTE: QC_INFO_COUNT=&QC_INFO_COUNT.;
%put NOTE: ===============================================;

proc sql;
    create table data.QC_Flag_Summary as
    select QC_FLAG, count(*) as ROWS
    from data.QC_Check_Matrix
    group by QC_FLAG
    order by QC_FLAG;
quit;

data _null_;
    set data.QC_Flag_Summary;
    put "NOTE: QC_FLAG_SUMMARY: " QC_FLAG= ROWS=;
run;

/* Create a report-style wide QC matrix.
   Only category TOTAL rows are included. Each category is shown as:
     Prior Members
     Current Members
     Difference
     % Change
     QC Flag
   Months run horizontally, matching the production report layout. */

data data.QC_Matrix_Long;
    set data.QC_Check_Matrix;

    length METRIC $20 VALUE $30 BLOCK_STATUS $25;
    format MONTH_ID 8.;

    /* Carry the QC decision to every metric row so the full 5-row block
       can be colored consistently in the wide matrix. */
    BLOCK_STATUS=strip(QC_FLAG);

    METRIC_ORDER=1;
    METRIC='Prior Members';
    if missing(PRIOR_MBRS) then VALUE='';
    else VALUE=strip(put(PRIOR_MBRS,comma18.));
    output;

    METRIC_ORDER=2;
    METRIC='Current Members';
    if missing(CURRENT_MBRS) then VALUE='';
    else VALUE=strip(put(CURRENT_MBRS,comma18.));
    output;

    METRIC_ORDER=3;
    METRIC='Difference';
    if missing(DIFF_MBRS) then VALUE='';
    else VALUE=strip(put(DIFF_MBRS,comma18.));
    output;

    METRIC_ORDER=4;
    METRIC='% Change';
    if missing(PCT_CHANGE) then VALUE='';
    else VALUE=strip(put(PCT_CHANGE,percent9.2));
    output;

    METRIC_ORDER=5;
    METRIC='QC Flag';
    VALUE=strip(QC_FLAG);
    output;

    keep REPORT_SECTION CATEGORY PLAN_TYPE MONTH_ID
         METRIC_ORDER METRIC VALUE BLOCK_STATUS;
run;

proc sort data=data.QC_Matrix_Long;
    by REPORT_SECTION CATEGORY METRIC_ORDER MONTH_ID;
run;

/* Month header format for the QC matrix.
   The current month is labeled YYYYMM01-MTD. */

proc sort data=data.QC_Check_Matrix(keep=MONTH_ID)
          out=work.QC_Month_Source nodupkey;
    by MONTH_ID;
run;

data work.QC_Month_Format;
    length FMTNAME $32 TYPE $1 LABEL $20;
    retain FMTNAME 'QC_MON' TYPE 'N';

    set work.QC_Month_Source;
    by MONTH_ID;

    if first.MONTH_ID then do;
        START=MONTH_ID;

        if MONTH_ID =
           input(put(intnx('month',
                          input("&today_char.",yymmdd10.),
                          0,'b'),yymmddn8.),8.)
        then LABEL=cats(put(MONTH_ID,8.),'-MTD');
        else LABEL=put(MONTH_ID,8.);

        output;
    end;

    keep FMTNAME TYPE START LABEL;
run;

proc sort data=work.QC_Month_Format nodupkey;
    by START;
run;

proc format cntlin=work.QC_Month_Format;
run;


/********************************************************************
 CALCULATE QC SUMMARY COUNTS BEFORE CREATING THE QC WORKBOOK
********************************************************************/
proc sql noprint;
    select count(*)
      into :QC_TOTAL_ROWS trimmed
    from data.QC_Check_Matrix;

    select count(*)
      into :QC_OK_COUNT trimmed
    from data.QC_Check_Matrix
    where QC_FLAG='OK';
quit;

%if %length(%superq(QC_TOTAL_ROWS)) = 0 %then
    %let QC_TOTAL_ROWS=0;

%if %length(%superq(QC_OK_COUNT)) = 0 %then
    %let QC_OK_COUNT=0;


/*--------------------------------------------------------------
  Export separate QC workbook
--------------------------------------------------------------*/

%global QCFILE;
%let QCFILE=/sas_mass_health/shared/output/ACOWeeklyReport/ReportTestMonthly-&repdt._SASQA.xls;

%put NOTE: QCFILE=&QCFILE;

ods tagsets.excelxp file="&QCFILE"
    options(
        orientation='landscape'
        autofilter='none'
        frozen_headers='yes'
        frozen_rowheaders='yes'
        sheet_interval='none'
        embedded_titles='yes'
        default_column_width='14'
        wraptext='on'
    )
    style=styles.minimal;


/*--------------------------------------------------------------
  QC Summary
--------------------------------------------------------------*/

ods tagsets.excelxp options(
    sheet_name="QC_Summary"
    sheet_interval="none"
    autofilter="none"
);

title "ACO Weekly Enrollment QC Summary";

data data.QC_Summary;
    length ITEM $40 VALUE $80;

    ITEM='Run Date';
    VALUE="&today_char.";
    output;

    ITEM='Prior Comparison Date';
    VALUE="%superq(QC_PRIOR_RUN_DT_CHAR)";
    output;

    ITEM='Distribution Decision';
    VALUE="&DISTRIBUTION_DECISION.";
    output;

    ITEM='Recommended Action';
    VALUE="&RECOMMENDED_ACTION.";
    output;

    ITEM='Report Integrity';
    VALUE="&REPORT_INTEGRITY.";
    output;

    ITEM='Technical QC Status';
    VALUE="&QC_STATUS.";
    output;

    ITEM='Rows Checked';
    VALUE="&QC_TOTAL_ROWS.";
    output;

    ITEM='Passed Rows';
    VALUE="&QC_OK_COUNT.";
    output;

    ITEM='Blocking Failures';
    VALUE="&QC_FAIL_COUNT.";
    output;

    ITEM='Review Warnings';
    VALUE="&QC_WARN_COUNT.";
    output;

    ITEM='Informational Flags';
    VALUE="&QC_INFO_COUNT.";
    output;

    ITEM='Decision Rule';
    VALUE='Blocking failure = do not distribute; warning = analyst review';
    output;

    ITEM='Adaptive Threshold Rule';
    VALUE='Activates after 8 historical weekly comparisons';
    output;
run;

proc report data=data.QC_Summary nowd
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center];

    columns ITEM VALUE;

    define ITEM / display "QC Summary Item"
        style(column)=[font_weight=bold];

    define VALUE / display "Value";

    compute VALUE;
        if ITEM='Distribution Decision' then do;
            if VALUE='READY TO DISTRIBUTE' then
                call define(_ROW_,'style',
                    'style=[background=#C6EFCE color=#006100 font_weight=bold]');
            else if VALUE='REVIEW BEFORE DISTRIBUTION' then
                call define(_ROW_,'style',
                    'style=[background=#FFEB9C color=#9C6500 font_weight=bold]');
            else if VALUE='DO NOT DISTRIBUTE' then
                call define(_ROW_,'style',
                    'style=[background=#FFC7CE color=#9C0006 font_weight=bold]');
        end;
        else if ITEM='Report Integrity' and VALUE='PASS' then
            call define(_ROW_,'style',
                'style=[background=#C6EFCE color=#006100 font_weight=bold]');
    endcomp;
run;


/*--------------------------------------------------------------
  QC Matrix
--------------------------------------------------------------*/

ods tagsets.excelxp options(
    sheet_name="QC_Matrix"
    sheet_interval="none"
    autofilter="none"
);

title "ACO Enrollment QC Matrix - Prior Weekly Run Compared to Current Run";
title2 "Category TOTAL Rows Only - QC Status: &QC_STATUS.";
title3 "Prior Run: %superq(QC_PRIOR_RUN_DT_CHAR)   Current Run: &today_char.";

proc report data=data.QC_Matrix_Long nowd missing
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center]
    style(column)=[vjust=middle];

    columns
        REPORT_SECTION
        CATEGORY
        PLAN_TYPE
        METRIC_ORDER
        METRIC
        BLOCK_STATUS
        MONTH_ID,VALUE
    ;

    define REPORT_SECTION / group "Section"
        style(column)=[just=left];

    define CATEGORY / group "Category"
        style(column)=[just=left];

    define PLAN_TYPE / group "Plan Type"
        style(column)=[just=left];

    define METRIC_ORDER / group noprint;

    define METRIC / group "Measure"
        style(column)=[just=left font_weight=bold];

    define BLOCK_STATUS / group noprint;

    define MONTH_ID / across "Month"
        order=internal
        format=QC_MON.;

    define VALUE / group ""
        style(column)=[just=right];

    compute VALUE;

        if BLOCK_STATUS='OK' then
            call define(
                _COL_,
                'style',
                'style=[background=#C6EFCE color=#006100]'
            );

        else if index(BLOCK_STATUS,'YELLOW') > 0 then
            call define(
                _COL_,
                'style',
                'style=[background=#FFEB9C color=#9C6500 font_weight=bold]'
            );

        else if index(BLOCK_STATUS,'RED') > 0
             or BLOCK_STATUS in ('MISSING ROW','NEW ROW') then
            call define(
                _COL_,
                'style',
                'style=[background=#FFC7CE color=#9C0006 font_weight=bold]'
            );

        else if BLOCK_STATUS='BASELINE ONLY' then
            call define(
                _COL_,
                'style',
                'style=[background=#D9EAF7 color=#1F4E78 font_weight=bold]'
            );

    endcomp;

    break after CATEGORY / skip;
run;


/*--------------------------------------------------------------
  QC Detail - one row per section/category/month TOTAL
--------------------------------------------------------------*/

ods tagsets.excelxp options(
    sheet_name="QC_Detail"
    sheet_interval="none"
    autofilter="all"
    frozen_headers="yes"
);

title "ACO Enrollment QC Detail";
title2 "Category TOTAL Rows Only - QC Status: &QC_STATUS.";

proc report data=data.QC_Check_Matrix nowd missing
    style(report)=[rules=all frame=box]
    style(header)=[font_weight=bold just=center]
    style(column)=[vjust=middle];

    columns REPORT_SECTION CATEGORY PLAN_TYPE MONTH_ID MONTH_GROUP
            PRIOR_RUN_DT PRIOR_MBRS CURRENT_RUN_DT CURRENT_MBRS
            DIFF_MBRS PCT_CHANGE HIST_PAIR_COUNT AVG_ABS_DIFF STD_ABS_DIFF
            WARNING_THRESHOLD FAIL_THRESHOLD THRESHOLD_METHOD QC_FLAG;

    define REPORT_SECTION / display "Section";
    define CATEGORY       / display "Category";
    define PLAN_TYPE      / display "Plan Type";
    define MONTH_ID       / display "Month";
    define MONTH_GROUP    / display "Month Group";
    define PRIOR_RUN_DT   / display "Prior Run" format=date9.;
    define PRIOR_MBRS     / display "Prior Members" format=comma18.1;
    define CURRENT_RUN_DT / display "Current Run" format=date9.;
    define CURRENT_MBRS   / display "Current Members" format=comma18.1;
    define DIFF_MBRS      / display "Difference" format=comma18.1;
    define PCT_CHANGE     / display "% Change" format=percent9.2;
    define HIST_PAIR_COUNT / display "History Pairs";
    define AVG_ABS_DIFF   / display "Avg Abs Diff" format=comma18.1;
    define STD_ABS_DIFF   / display "Std Abs Diff" format=comma18.1;
    define WARNING_THRESHOLD / display "Warning Threshold" format=comma18.1;
    define FAIL_THRESHOLD / display "Fail Threshold" format=comma18.1;
    define THRESHOLD_METHOD / display "Threshold Method";
    define QC_FLAG        / display "QC Flag";

    compute QC_FLAG;
        if QC_FLAG='OK' then
            call define(_ROW_,'style','style=[background=#C6EFCE color=#006100]');
        else if index(QC_FLAG,'YELLOW') > 0 then
            call define(_ROW_,'style','style=[background=#FFEB9C color=#9C6500 font_weight=bold]');
        else if index(QC_FLAG,'RED') > 0
             or QC_FLAG in ('MISSING ROW','NEW ROW') then
            call define(_ROW_,'style','style=[background=#FFC7CE color=#9C0006 font_weight=bold]');
        else if QC_FLAG='BASELINE ONLY' then
            call define(_ROW_,'style','style=[background=#D9EAF7 color=#1F4E78 font_weight=bold]');
    endcomp;
run;

/*--------------------------------------------------------------
  Close QC workbook before saving history or attaching it
--------------------------------------------------------------*/

title;
title2;
title3;

ods tagsets.excelxp close;

%put NOTE: QC workbook creation completed: &QCFILE;

/************************************************************/
/* SAVE CURRENT TOTAL-CATEGORY MATRIX TO QC HISTORY             */
/*                                                              */
/* This is the validated save method tested on 30JUL2026.       */
/* Same-day reruns delete and replace today's rows.              */
/************************************************************/

%global QC_HISTORY_SAVED_ROWS;
%let QC_HISTORY_SAVED_ROWS=0;

/* Confirm the current category-total matrix exists and has rows. */
proc sql noprint;
    select count(*)
      into :QC_CURRENT_HISTORY_ROWS trimmed
    from data.QC_Current_Matrix
    where strip(CATEGORY) ne 'NULL'
      and strip(CATEGORY) ne ''
      and strip(PLAN_TYPE) = 'TOTAL';
quit;

%put NOTE: QC CURRENT TOTAL-CATEGORY ROWS=&QC_CURRENT_HISTORY_ROWS.;

%if %length(%superq(QC_CURRENT_HISTORY_ROWS)) = 0 %then %do;
    %put ERROR: QC current matrix row count was not populated. History was not updated.;
    %return;
%end;

%if %sysevalf(&QC_CURRENT_HISTORY_ROWS <= 0) %then %do;
    %put ERROR: QC current matrix contains zero TOTAL-category rows. History was not updated.;
    %return;
%end;

/* Remove the prior temporary Snowflake staging table. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        DROP TABLE IF EXISTS ACOENR_QC_CURRENT_MATRIX_STAGE
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Drop QC history stage table);

/* Copy the current TOTAL-category matrix to Snowflake staging. */
proc sql;
    create table my_snow1.ACOENR_QC_CURRENT_MATRIX_STAGE as
    select
        strip(REPORT_SECTION) as REPORT_SECTION,
        strip(CATEGORY)       as CATEGORY,
        'TOTAL'               as PLAN_TYPE,
        MONTH_ID,
        MBRS
    from data.QC_Current_Matrix
    where strip(CATEGORY) ne 'NULL'
      and strip(CATEGORY) ne ''
      and strip(PLAN_TYPE) = 'TOTAL';
quit;

%stop_if_sql_error(step=Create QC history stage table);

/* Delete and replace the current run-date history rows. */
proc sql;
    connect using my_snow1;

    execute (USE DATABASE MHDWPROD) by my_snow1;
    execute (USE SCHEMA MHA) by my_snow1;
    execute (USE WAREHOUSE MHA_WH) by my_snow1;
    execute (USE ROLE MHA_TEAM_ROLE) by my_snow1;

    execute (
        DELETE FROM ACOENR_QC_HISTORY_MATRIX
        WHERE RUN_DT = TO_DATE(&today, 'YYYY-MM-DD')
    ) by my_snow1;

    execute (
        INSERT INTO ACOENR_QC_HISTORY_MATRIX
        (
            RUN_DT,
            RUN_DTTM,
            REPORT_SECTION,
            CATEGORY,
            PLAN_TYPE,
            MONTH_ID,
            MBRS
        )
        SELECT
            TO_DATE(&today, 'YYYY-MM-DD'),
            CURRENT_TIMESTAMP(),
            REPORT_SECTION,
            CATEGORY,
            PLAN_TYPE,
            MONTH_ID,
            MBRS
        FROM ACOENR_QC_CURRENT_MATRIX_STAGE
    ) by my_snow1;

    disconnect from my_snow1;
quit;

%stop_if_sql_error(step=Save current QC history);

/* Verify the exact number of rows saved for this run date. */
proc sql noprint;
    select count(*)
      into :QC_HISTORY_SAVED_ROWS trimmed
    from my_snow1.ACOENR_QC_HISTORY_MATRIX
    where run_dt=input("&today_char.",yymmdd10.)
      and strip(PLAN_TYPE)='TOTAL';
quit;

%if %length(%superq(QC_HISTORY_SAVED_ROWS)) = 0 %then
    %let QC_HISTORY_SAVED_ROWS=0;

%put NOTE: ===============================================================;
%put NOTE: QC HISTORY ROWS SAVED FOR &today_char.=&QC_HISTORY_SAVED_ROWS.;
%put NOTE: EXPECTED QC HISTORY ROWS=&QC_CURRENT_HISTORY_ROWS.;
%put NOTE: ===============================================================;

%if %sysevalf(&QC_HISTORY_SAVED_ROWS ne &QC_CURRENT_HISTORY_ROWS) %then %do;
    %put ERROR: QC history verification failed. Saved row count does not match current matrix.;
    %abort cancel;
%end;

/*--------------------------------------------------------------
  Send QC email only after workbook has been closed
--------------------------------------------------------------*/

/* %SEND_ACO_QC_EMAIL;  Email disabled for automation testing */



%mend RUN_ACO_QC_AND_EMAIL;

/* Run the QC and email process */
%RUN_ACO_QC_AND_EMAIL;

/* To resend only the QC email in the same SAS session, run:
      /* %SEND_ACO_QC_EMAIL;  Email disabled for automation testing */
*/


/*******************Report Output*********************/
/*
   ACTIVE PRODUCTION WORKSHEETS IN THIS FINAL v3 FILE:
     1. Summary
     2. Summary-Enroll-Region
     3. Summary-Caseload-Reg x SA
     4. Summary-Enroll-Reg X SA
     5. Summary-DisEnroll-Reg X SA
     6. Caseload
     7. Caseload-Reg X SA
     8. Enrollment
     9. Enrollment-Reg X SA
    10. Disenrollment
    11. Disenrollment_Reg X SA

   All other worksheet code is preserved below but wrapped in SKIP_* macros,
   so it remains available for future reference and does not run.
*/
/*****************************************************************
 Dynamic Month Format
 Automatically marks the report month as MTD.
 FIRSTDTWEEK is numeric YYYYMMDD.
*****************************************************************/

%put NOTE: REPDT=&repdt;
%put NOTE: TODAY_CHAR=&today_char.;

data fmt_mon_value;
    length fmtname $32 type $1 label $20;
    retain fmtname 'MON_VALUE'
           type 'N';

    /* Derive the report month inside the DATA step.
       This avoids an empty REPORT_MONTH_DATE macro variable. */
    report_month_date=intnx(
        'month',
        input("&today_char.",yymmdd10.),
        0,
        'beginning'
    );

    sas_month='01MAR2023'd;

    do while (sas_month <= report_month_date);

        start=input(put(sas_month,yymmddn8.),8.);
        end=start;

        if sas_month=report_month_date then
            label=cats(put(start,8.),'-MTD');
        else
            label=put(start,8.);

        output;

        sas_month=intnx('month',sas_month,1,'beginning');
    end;

    keep fmtname type start end label;
run;

proc format cntlin=fmt_mon_value;
run;
%let style = %nrstr( missing nowd spanrows center headline headskip split='*' 
     style(report) =[ verticalalign=m  borderwidth=1  bordercolor=black /*Rules=rows*/ Background=white Frame=box cellspacing=0 cellpadding=0 ] 
     style(Header) =[ verticalalign=m  background=blue color=white  font_weight=bold  font_size=11pt  just=center ]
     style(lines)  =[ color=black ]   
     style(column) =[ textalign=right vjust=c  verticalalign=m  backgroundposition=right_center ] ); 

%put &style;

ods html close;
ods listing close;
ods graphics on/reset=all antialias=on height=3in width=6in border=off scale=on scalemarkers=on;
ods noresults noproctitle ;
options nodate number 
topmargin="0.5in" leftmargin="0.25in" bottommargin="0.5in" rightmargin="0.25in";

ods tagsets.excelxp file="&OUTFILE" 
options( 
        Orientation='Landscape'
        skip_space='3,2,0,0,1'
        CENTER_VERTICAL='yes'
        CENTER_HORIZONTAL='yes'
        autofilter='none'
        default_column_width='10' 
        wraptext='on'
        autofit_height='off' 
        row_heights='18'
        Pages_FitWidth='1'
        Pages_FitHeight='13'
        FROZEN_HEADERS='no'
        FROZEN_ROWHEADERS='no'
        GRIDLINES='no'
        sheet_interval='none'
        row_repeat='header'
        Embedded_Footnotes='yes'
        embedded_titles='no' 
      ) 
       style=styles.minimal;

/* 1a. Summary Caseloads by ACOs without Region/service areas */

ods tagsets.excelxp options(sheet_name="Summary" sheet_interval="none" );

proc report data=  data.myCaseload2  out=caseload_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members'/* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/

  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/

  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_  / style = {just = l font_weight=bold font_size=11pt vjust=m just=left};
    line @1 "Weekly ACO/MCO/PCC Enrollment Report for week of &repdt." ; 
  line @1 "MH Analytics" ;
    line ' ';
    line @1 "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." ;
    line @1 "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" ;
    line ' ';
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') /*and provname2 is not null /*and MCO_region ^= 'Out of state/Unknown'*/;
run;


/*---------------------------------------------------------------*/

/* 1b. Summary Enrollments by ACOs without Regions/Service Areas */

proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );

  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/

  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
    
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
 compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments" ;
    line ' ';
  endcomp;
  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
   where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and membertype='All';
run;



/*---------------------------------------------------------*/


/* 1c. Summary Disenrollments by ACOs without Regions/Service Areas */

proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
 
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' ';
  endcomp;
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass is not null and membertype='All';
run;



/*1d. last 3 months of data (1 quarter) auto-assignments */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Auto-Assigned Enroll 3m ===== */
%macro SKIP_AUTO_ASSIGNED_ENROLL_3M();
ods tagsets.excelxp options(sheet_name="Auto-Assigned Enroll 3m" sheet_interval="none" );

proc report data=  data.myEnrAgg2  out=enroll2_&repdt. &style.;  
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   

  columns ( 'Number of Members' MCO_REGION, SERVICE_AREA, /*firstdtweek,*/ mbrs);  
  columns ( 'Percent of Members' MCO_REGION, SERVICE_AREA, /*firstdtweek,*/ pcttype); 
    /*---------------------------------------*/

  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  define MCO_REGION/across '' order=internal descending ;
  define SERVICE_AREA/across '' order=internal descending ;
  
  /*define firstdtweek/across ''format=MON_value.  ;*/
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Auto-Assigned Enrollments By Reions and Srv. Areas" ;
    line ' ';
  endcomp;  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and firstdtweek in (20190101, 20190201, 20190301) and enrdisClass = 'Auto-Assigned'
        and membertype='All';
run;



/*----------------------------------------------------------*/

/* 2a. Summary Caseloads by Region/ACOs */


%mend SKIP_AUTO_ASSIGNED_ENROLL_3M;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Auto-Assigned Enroll 3m ===== */

/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Region ===== */
%macro SKIP_SUMMARY_CASELOAD_REGION();
ods tagsets.excelxp options(sheet_name="Summary-Caseload-Region" sheet_interval="none" );

proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
 
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
    

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_  / style = {just = l font_weight=bold font_size=11pt vjust=m just=left};
    line @1 "Weekly ACO/MCO/PCC Enrollment By regions - Report for week of &repdt." ; 
  line @1 "MH Analytics" ;
    line ' ';
    line @1 "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." ;
    line @1 "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" ;
    line ' ';
    line @1 "MassHealth ACO/MCO/PCC Members by Regions - Report for week of &repdt." ; 
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;


/*----------------------------------------------------------*/

/* 2b. Summary Enrollments by Regions/ACOs */


%mend SKIP_SUMMARY_CASELOAD_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Region ===== */
ods tagsets.excelxp options(sheet_name="Summary-Enroll-Region" sheet_interval="none" );


proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );

  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
 compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments By regions - Report for week of &repdt." ; 
    line ' ';
  endcomp;  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null
       and membertype='All';
run;

/*----------------------------------------------------------------------*/


/* 2c. Summary Disenrollments by Regions /ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnroll-Region ===== */
%macro SKIP_SUMMARY_DISENROLL_REGION();
ods tagsets.excelxp options(sheet_name="Summary-DisEnroll-Region" sheet_interval="none" );

proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'Reason' enrdisClass );
   
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments By regions - Report for week of &repdt." ; 
    line ' ';
  endcomp;
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region is not null and MCO_region ^= 'Out of state/Unknown'
         and membertype='All' and enrdisClass ne '';
run;



/*----------------------------------------------------------*/

/* 3a-1. Summary Caseloads by Region/service areas/ACOs */


%mend SKIP_SUMMARY_DISENROLL_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnroll-Region ===== */
ods tagsets.excelxp options(sheet_name="Summary-Caseload-Reg x SA" sheet_interval="none" );

proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA);  
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };    
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };   
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
   

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_  / style = {just = l font_weight=bold font_size=11pt vjust=m just=left};
    line @1 "Weekly ACO/MCO/PCC Enrollment By Regions and Srv Areas Report for week of &repdt." ; 
  line @1 "MH Analytics" ;
    line ' ';
    line @1 "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." ;
    line @1 "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" ;
    line ' ';
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;



/* 3a-2. Summary Caseloads by Region/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Reg x RC ===== */
%macro SKIP_SUMMARY_CASELOAD_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Summary-Caseload-Reg x RC" sheet_interval="none" );

proc report data=  data.myCaseload2  out=caseload_&repdt. &style.;
  columns ( 'Caseload' membertype);  
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */ 
  columns ( 'Plan Type' provtype2);
  columns ( 'Caseload' membertype); 
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /*timeperiod, */firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };    
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };  */ 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
   

  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_  / style = {just = l font_weight=bold font_size=11pt vjust=m just=left};
    line @1 "Weekly ACO/MCO/PCC Enrollment By Regions and Srv Areas Report for week of &repdt." ; 
  line @1 "MH Analytics" ;
    line ' ';
    line @1 "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." ;
    line @1 "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" ;
    line ' ';
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;


/*------------------------------------------------------*/


/* 2c-1. Summary Enrollments by Regions/Service Areas/ACOs */


%mend SKIP_SUMMARY_CASELOAD_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Caseload-Reg x RC ===== */
ods tagsets.excelxp options(sheet_name="Summary-Enroll-Reg X SA" sheet_interval="none" );

proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
 compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments By Regions and Srv Areas Report for week of &repdt." ; 
    line ' ';
  endcomp;  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass ne '' ;
run;


/* 2c-2. Summary Enrollments by Regions/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-Enroll-Reg X RC ===== */
%macro SKIP_SUMMARY_ENROLL_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Summary-Enroll-Reg X RC" sheet_interval="none" );

proc report data=  data.myEnrAgg2  out=enroll_&repdt. &style.;   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA);*/ 
  columns ( 'Plan Type' provtype2);
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ( 'Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ( 'Percent of Members' /* timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  
 /* define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
 compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments By Regions and Srv Areas Report for week of &repdt." ; 
    line ' ';
  endcomp;  

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass ne '' ;
run;


/*---------------------------------------------------------*/



/* 3c-1. Summary Disenrollments by Regions/Service Areas /ACOs */


%mend SKIP_SUMMARY_ENROLL_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-Enroll-Reg X RC ===== */
ods tagsets.excelxp options(sheet_name="Summary-DisEnroll-Reg X SA" sheet_interval="none" );

proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'Disnrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' ';
  endcomp;
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB')  and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;


/* 3c-2. Summary Disenrollments by Regions/RC/ACOs */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnoll-Reg X RC ===== */
%macro SKIP_SUMMARY_DISENOLL_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Summary-DisEnoll-Reg X RC" sheet_interval="none" );

proc report data=  data.myEnrAgg2 out=disenroll_&repdt.  &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'Disnrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define membertype /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; 
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal    width = 7  style(column)={vjust=m just=left background=white };   
  define enrdisClass /group '' order=internal  width = 11  style(column)={vjust=m just=left background=white };  
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' ';
  endcomp;
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;

    where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB')  and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;


/*----------------------------------------------*/

/* Caseload */


%mend SKIP_SUMMARY_DISENOLL_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Summary-DisEnoll-Reg X RC ===== */
ods tagsets.excelxp options(sheet_name="Caseload" sheet_interval="none" autofilter="no");

proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across ''format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB');
run;



/*---------------------------------------------------*/


/* Caseload By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Caseload-Region ===== */
%macro SKIP_CASELOAD_REGION();
ods tagsets.excelxp options(sheet_name="Caseload-Region" sheet_interval="none" autofilter="no");

proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
      
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
 
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;

/*-------------------------------------------------------------------------*/


/* Caseload By Regions By Service Area*/

%mend SKIP_CASELOAD_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Caseload-Region ===== */
ods tagsets.excelxp options(sheet_name="Caseload-Reg X SA" sheet_interval="none" autofilter="no");

proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/    
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;

/*-------------------------------------------------------------------------*/
/*-------------------------------------------------------------------------*/


/* Caseload By Regions By RC*/

/* ===== COMMENTED OUT UNUSED WORKSHEET: Caseload-Reg X RC ===== */
%macro SKIP_CASELOAD_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Caseload-Reg X RC" sheet_interval="none" autofilter="no");

proc report data=  data.myCaseload2  out=caseload_tab_&repdt. &style.; 
  columns ( 'Caseload' membertype); 
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2); 
  columns ( 'Caseload' membertype);
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members' /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/    
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
 /* define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal  width = 10  style(column)={vjust=m just=left background=white }; 
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Members" ;
    line ' ';
  endcomp;
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown'
and MCO_region ^='';
run;

/*-------------------------------------------------------------------------*/




/* Enrollments*/


%mend SKIP_CASELOAD_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Caseload-Reg X RC ===== */
ods tagsets.excelxp options(sheet_name="Enrollment" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments" ;
    line ' ';
    line @1 "Auto-Assigned : Member Enrolled through Auto Assignment" ;
    line @1 "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" ;
    line @1 "Special Assignment : Enrollment Created as part of Special Assignment work" ;
    line @1 "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" ;
    line @1 "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) The batch fixes, such as moving Tufts UMASS members to the PCC plan are classified as Re-enrollment on 3/1 in the report.";
    line @1 "2) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and membertype='All';
run;


/*----------------------------------------------*/


/* Enrollments By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Enrollment-Region ===== */
%macro SKIP_ENROLLMENT_REGION();
ods tagsets.excelxp options(sheet_name="Enrollment-Region" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments" ;
    line ' ';
    line @1 "Auto-Assigned : Member Enrolled through Auto Assignment" ;
    line @1 "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" ;
    line @1 "Special Assignment : Enrollment Created as part of Special Assignment work" ;
    line @1 "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" ;
    line @1 "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown'
        and membertype='All';
run;



/*----------------------------------------------------*/

/* Enrollments By Regions By Service Area */


%mend SKIP_ENROLLMENT_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Enrollment-Region ===== */
ods tagsets.excelxp options(sheet_name="Enrollment-Reg X SA" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA); 
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments" ;
    line ' ';
    line @1 "Auto-Assigned : Member Enrolled through Auto Assignment" ;
    line @1 "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" ;
    line @1 "Special Assignment : Enrollment Created as part of Special Assignment work" ;
    line @1 "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" ;
    line @1 "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown';
run;



/*----------------------------------------------------*/
/*----------------------------------------------------*/

/* Enrollments By Regions By RC */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Enrollment-Reg X RC ===== */
%macro SKIP_ENROLLMENT_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Enrollment-Reg X RC" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=enr_tab_&repdt. &style.; 
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA); */
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Enrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);  
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/  
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
 /* define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };*/ 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white };
  define provname2 /group '' order=internal   width = 10  style(column)={vjust=m just=left background=white };
  
  /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Enrollments" ;
    line ' ';
    line @1 "Auto-Assigned : Member Enrolled through Auto Assignment" ;
    line @1 "Re-enrollment : Member automatically enrolled in plan but not through auto assignment, such as having prior history with a plan" ;
    line @1 "Special Assignment : Enrollment Created as part of Special Assignment work" ;
    line @1 "Member Choice : Member Choose to enroll in plan (note: this is created when a member enrolls through a CSR, can also occur when CSRs manually fix enrollments)" ;
    line @1 "Family Based Assignment : Member was automatically assigned to a plan because a family member was assigned to the plan (includes when a newborn is assigned to the Mom's plan)" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) Family Based Assignment added as option to the report to highlight Newborns and members joining plans due to familial relationships.";
  endcomp;
  
  where type = 'enrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass ne '' and MCO_region ^= 'Out of state/Unknown';
run;



/*----------------------------------------------------*/



/* Disenrollments*/


%mend SKIP_ENROLLMENT_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Enrollment-Reg X RC ===== */
ods tagsets.excelxp options(sheet_name="Disenrollment" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);  
  columns ( 'Reason' enrdisClass );
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
 
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across ''format=MON_value.  ;
  /*---------------------------------------*/ 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' '; 
    line @1 "CSR - Member Driven : Code used by CSR for closing a case when a member calls" ;
    line @1 "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" ;
    line @1 "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" ;
    line @1 "System Generated : Automatic Disenrollment created by the System" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and membertype='All' and enrdisClass is not null;
run;


/*----------------------------------------------------*/


/* Disenrollments By Regions */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Region ===== */
%macro SKIP_DISENROLLMENT_REGION();
ods tagsets.excelxp options(sheet_name="Disenrollment_Region" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Reason' enrdisClass );
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
 
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format=MON_value. ;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' '; 
    line @1 "CSR - Member Driven : Code used by CSR for closing a case when a member calls" ;
    line @1 "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" ;
    line @1 "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" ;
    line @1 "System Generated : Automatic Disenrollment created by the System" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; 
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null
        and membertype='All';
run;

/*----------------------------------------------------*/

/* Disenrollments By Regions by Service Areas */


%mend SKIP_DISENROLLMENT_REGION;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Region ===== */
ods tagsets.excelxp options(sheet_name="Disenrollment_Reg X SA" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  columns ( 'Service Areas' SERVICE_AREA);
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; 
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format= MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' '; 
    line @1 "CSR - Member Driven : Code used by CSR for closing a case when a member calls" ;
    line @1 "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" ;
    line @1 "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" ;
    line @1 "System Generated : Automatic Disenrollment created by the System" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;

/*----------------------------------------------------*/
/* Disenrollments By Regions by RC */


/* ===== COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Reg X RC ===== */
%macro SKIP_DISENROLLMENT_REG_X_RC();
ods tagsets.excelxp options(sheet_name="Disenrollment_Reg X RC" sheet_interval="none" autofilter="no");

proc report data=  data.myEnrAgg2  out=disenr_tab_&repdt. &style.; 
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'MCO Regions' MCO_REGION);
  /*columns ( 'Service Areas' SERVICE_AREA);*/
  columns ( 'Plan Type' provtype2);
  columns ( 'ACO/MCO' provname2);   
  columns ( 'Disenrollment' membertype);  
  columns ( 'Reason' enrdisClass );
  columns ( 'Running Date' Running_DT); /*added running date as of 4/14/2020*/
  
  columns ('Number of Members'  /*timeperiod,*/ firstdtweek, mbrs);  
  columns ('Percent of Members' /*timeperiod,*/ firstdtweek, pcttype);   
  /*---------------------------------------*/
  define membertype /group '' order=internal width = 10  style(column)={vjust=m just=left background=white };  
  define Running_DT /group '' order=internal width = 11  style(column)={vjust=m just=left background=white }; /*added running date as of 4/14/2020*/
  define enrdisClass /group '' order=internal width = 11  style(column)={vjust=m just=left background=white };
  define MCO_REGION /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white };
  /*define SERVICE_AREA /group '' order=internal  width = 7  style(column)={vjust=m just=left background=white }; */
  define provtype2 /group '' order=internal   width = 7  style(column)={vjust=m just=left background=white }; 
  define provname2 /group '' order=internal   width = 10 style(column)={vjust=m just=left background=white };
 
 /*define timeperiod/across '' order=internal descending ;*/
  define firstdtweek/across '' format= MON_value.;
  /*---------------------------------------*/ 
 
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right }  style={tagattr='format:###,###,###,##0_);\(###,###,###,##0\)'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  compute before _page_ / style = {just = l font_weight=bold font_size=11pt};
    line @1 "MassHealth ACO/MCO/PCC Disenrollments" ;
    line ' '; 
    line @1 "CSR - Member Driven : Code used by CSR for closing a case when a member calls" ;
    line @1 "Other : Codes used by a CSR for other purposes (such as manual enrollment work) or system driven disenrollments" ;
    line @1 "CSR - Unclassified/Dual Use : Codes used by a CSR that can be used as part of manual work or can be given as a reason for member driven enrollment change" ;
    line @1 "System Generated : Automatic Disenrollment created by the System" ;
    line ' ';
  endcomp;

  compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically.";
  endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and MCO_region ^= 'Out of state/Unknown' and enrdisClass is not null;
run;

/*----------------------------------------------------*/




%mend SKIP_DISENROLLMENT_REG_X_RC;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Disenrollment_Reg X RC ===== */

/* ===== COMMENTED OUT UNUSED WORKSHEET: Code Crosswalk ===== */
%macro SKIP_CODE_CROSSWALK();
ods tagsets.excelxp options(sheet_name="Code Crosswalk" sheet_interval="none" autofilter="no");
proc print data=data.code_xwalk; run;


%mend SKIP_CODE_CROSSWALK;
/* ===== END COMMENTED OUT UNUSED WORKSHEET: Code Crosswalk ===== */
ods tagsets.excelxp close;

%symdel SF_KEY_PWD / nowarn;
/*---------------------------------------------*/










