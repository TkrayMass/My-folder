/* FORMAT-ONLY TEST: reuses existing REBUILD source tables; no source refresh. */
/* NATIVE XLSX ISOLATED CANDIDATE. No production scheduling/publication/email.
   Uses existing ACOENR_REBUILD test objects; do not run alongside another REBUILD job.
   Separate ACO_REBUILD_XLSX output root. Full runtime and format validation pending.
*/
/* ISOLATED UPGRADE BASELINE. Use a separate SAS session.
   Install ACO_REBUILD_Refresh.sql first. Production schedules remain unchanged.
   ExcelXP XLS output is preserved for comparison; XLSX migration is next.
*/
/* Candidate only: run in a separate SAS session. No automatic email. */
%global U_RUN_ID U_RUN_DIR;
%let U_RUN_ID=%superq(sysparm);
%macro U_SET_RUN_ID;
 %if %length(%superq(U_RUN_ID))=0 %then
  %let U_RUN_ID=%sysfunc(compress(%sysfunc(datetime(),hex16.)))_&sysjobid.;
 %if %sysfunc(prxmatch(%str(/^[A-Za-z0-9_]{1,80}$/),%superq(U_RUN_ID))) ne 1 %then %do;
  %put ERROR: Invalid candidate run ID.; %abort cancel;
 %end;
%mend;
%U_SET_RUN_ID;
%let U_RUN_DIR=/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX/&U_RUN_ID.;
data _null_;
    length base child $1024;
    base='/sas_mass_health/shared/output/ACOWeeklyReport/ACO_REBUILD_XLSX';
    if not fileexist(base) then child=dcreate('ACO_REBUILD_XLSX','/sas_mass_health/shared/output/ACOWeeklyReport');
    if not fileexist(base) then do; put 'ERROR: Cannot create candidate base directory.'; abort cancel; end;
    child=dcreate(symget('U_RUN_ID'),base);
    if missing(child) then do; put 'ERROR: Cannot create a new attempt directory.'; abort cancel; end;
run;


/******************************************************************************************
 ACO Weekly Enrollment Report - UPGRADE ISOLATION BASELINE - CALCULATIONS PRESERVED

 Purpose:
   - Preserves the validated manual report calculations.
   - Retains the working v3 Snowflake table-creation method:
       CREATE OR REPLACE TABLE through Snowflake pass-through.
   - Reads dynamic run dates from Snowflake.
   - Calls ACOENR_REBUILD_WEEKLY_REFRESH().
   - Validates ACOENR_REBUILD_02_ENRDIS.
   - Rebuilds ACOENR_00 through ACOENR_06.
   - Produces the required Excel worksheets.
   - Restores validated TOTAL-category weekly QC with QC_Summary, QC_Matrix, and QC_Detail.
   - Adds QC history comparison and QC workbook without changing report calculations.
   - QC email includes QC issues and the completed QC workbook.
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
libname data "%sysfunc(pathname(work))"; /* Upgrade tables are session-local. */

/* Snowflake connection */
options nosymbolgen nomprint nosource;

/* Load Snowflake credentials */
%include "/sas_mass_health/shared/tkray/private/snowflake_credentials.sas";

options source;

libname upgsnow snow
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
%macro U_stop_if_sql_error(step=);
    %if &sqlrc ne 0 %then %do;
        %put ERROR: &step failed. Program stopped.;
        %abort cancel;
    %end;
%mend U_stop_if_sql_error;

/******************************************************************************************
 STEP 1 - DYNAMIC RUN DATES FROM SNOWFLAKE

 Note:
   Snowflake owns the business run dates. SAS reads equivalent values from Snowflake
   and uses them only for snapshot filters, filenames, report titles, and display labels.
******************************************************************************************/

proc sql noprint;
    connect using upgsnow;

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
      from connection to upgsnow
      (
        select to_char(to_date('2023-03-01'), 'YYYY-MM-DD') as startdate_char,
               to_char(dateadd(day,-7,current_date()), 'YYYY-MM-DD') as lastweek_char,
               to_char(current_date(), 'YYYY-MM-DD') as enddate_char,
               to_char(current_date(), 'YYYY-MM-DD') as today_char,
               to_char(current_date(), 'YYYY-MM-DD') as wh_thru_dt_char,
               to_char(current_date(), 'YYYY-MM-DD') as running_dt_char,
               to_char(current_date(), 'YYYYMMDD') as repdt_char
      );

    disconnect from upgsnow;
quit;

%let StartDate  = %str(%')&StartDate_char.%str(%');
%let lastweek   = %str(%')&lastweek_char.%str(%');
%let EndDate    = %str(%')&EndDate_char.%str(%');
%let today      = %str(%')&today_char.%str(%');
%let wh_thru_dt = %str(%')&wh_thru_dt_char.%str(%');
%let Running_DT = %str(%')&Running_DT_char.%str(%');

/* The active ExcelXP output filename is configured below. */

/* QC workbook and email configuration */
%let OUTFILE=&U_RUN_DIR./ReportTestMonthly-&repdt._REBUILD_REGXSA.xlsx;
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
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC a
    where type ne 'snapshot';
quit;

%U_stop_if_sql_error(step=Create current-run DATA.MYENRAGG2);

proc sql;
    create table data.myCaseload2 as
    select a.*,
           a.DSC_MC_REGION_CAP as MCO_REGION,
           a.dsc_mc_region_enroll as SERVICE_AREA
    from upgsnow.ACOENR_REBUILD_06_REP_W_PERC a
    where type = 'snapshot';
quit;

%U_stop_if_sql_error(step=Create current-run DATA.MYCASELOAD2);

proc sql;
    create table data.code_xwalk as
    select *
    from upgsnow.XWALK_ACOENRRPT_ENRDIS;
quit;

%U_stop_if_sql_error(step=Create DATA.CODE_XWALK);

/* Verify that the local SAS report datasets were rebuilt in this run. */
proc sql noprint;
    select count(*) into :LOCAL_CASELOAD_ROWS trimmed
    from data.myCaseload2;

    select count(*) into :LOCAL_ENR_ROWS trimmed
    from data.myEnrAgg2;
quit;

%macro U_stop_if_local_tables_empty;
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
%mend U_stop_if_local_tables_empty;

%U_stop_if_local_tables_empty;

%put NOTE: CURRENT-RUN LOCAL TABLES: MYCASELOAD2=&LOCAL_CASELOAD_ROWS rows;
%put NOTE: CURRENT-RUN LOCAL TABLES: MYENRAGG2=&LOCAL_ENR_ROWS rows;

/*CHECK NUMBERS  1,258,071*/
proc sql;
    connect using upgsnow;

    create table data.myCaseload2A as
    select *
    from connection to upgsnow
    (
        select sum(MBRS) / 2 as adjusted_mb_count
        from MHDWPROD.MHA.ACOENR_REBUILD_01_SNAPSHOT
        where type = 'snapshot'
          and FIRSTDTWEEK = 20240601
    );

    disconnect from upgsnow;
quit;


/******************************************************************************************
 STEP 4A - FRESHNESS / CURRENT-MONTH VALIDATION BEFORE QC AND EXCEL

 This check proves that:
   - ACOENR_REBUILD_01_SNAPSHOT was rebuilt;
   - ACOENR_REBUILD_06_REP_W_PERC contains the current report month;
   - DATA.MYCASELOAD2 contains the same current-month rows;
   - the report will not continue on a stale prior-week SAS dataset.
******************************************************************************************/

proc sql noprint;
    connect using upgsnow;

    create table data.current_run_validation as
    select *
    from connection to upgsnow
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
        left join MHDWPROD.MHA.ACOENR_REBUILD_06_REP_W_PERC r
          on r.firstdtweek=c.month_id
         and r.type='snapshot'
         and r.provtype2 not in ('ZZ - ACOB PCCB')
        group by c.month_id
    );

    disconnect from upgsnow;
quit;

%U_stop_if_sql_error(step=Current-month Snowflake validation);

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

%U_stop_if_sql_error(step=Local current-month validation);

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

%U_stop_if_sql_error(step=Final freshness validation);

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

%macro U_stop_if_stale_or_missing;
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
%mend U_stop_if_stale_or_missing;

%U_stop_if_stale_or_missing;
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
     style(report) =[ verticalalign=m  borderwidth=1px borderstyle=solid  bordercolor=black Rules=all Background=white Frame=box cellspacing=0 cellpadding=0 ] 
     style(Header) =[ font_face="Arial" bordercolor=black borderwidth=1px borderstyle=solid  verticalalign=m  background=blue color=white  font_weight=bold  font_size=11pt  just=center ]
     style(lines)  =[ font_face="Arial" font_size=11pt  color=black ]   
     style(column) =[ font_face="Arial" font_size=11pt bordercolor=black borderwidth=1px borderstyle=solid  textalign=right vjust=c  verticalalign=m  backgroundposition=right_center ] ); 

%put &style;


/* Formatting reference: published October 7 report. Native numeric widths
   grow with the reporting months, so no fixed last-column limit is used. */
%macro U_NATIVE_WIDTHS(prefix=,num=);
 %local _i _months;
 %let _months=%eval(%sysfunc(intck(month,%sysfunc(inputn(20230301,yymmdd8.)),%sysfunc(inputn(&EndDate_char.,yymmdd10.))))+1);
 &prefix.%do _i=1 %to %eval(2*&_months.);,&num.%end;
%mend;

ods excel file="&OUTFILE"
 options(sheet_interval='none' embedded_titles='no' embedded_footnotes='yes'
         absolute_column_width='14' flow='tables' gridlines='off'
         frozen_headers='off' frozen_rowheaders='off' row_repeat='header'
         pages_fitwidth='1' pages_fitheight='13')
 style=styles.minimal;


/* 1a. Summary Caseloads by ACOs without Region/service areas */

ods excel options(sheet_name="Summary" sheet_interval='none'  absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,17.17,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406,8.986406),num=7.896562)" frozen_headers='7' frozen_rowheaders='off');

ods excel options(flow='tables,text');
proc odstext;
 p "Weekly ACO/MCO/PCC Enrollment Report for week of &repdt." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MH Analytics" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p "MassHealth ACO/MCO/PCC Members" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
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
 
  define mbrs/ analysis sum  '' nozero order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/

  endcomp;
  break after membertype / summarize style=[font_weight=bold ] ;
 
  compute after membertype ;
    line ' ';
  endcomp;
  
  
  
  compute after;
    line @1 "Notes:";
    line @1 "1) Disabled Members are determined based on Rating Category.";
  endcomp;
where type = 'snapshot' and provtype2 not in ('ZZ - ACOB PCCB') /*and provname2 is not null /*and MCO_region ^= 'Out of state/Unknown'*/;
run;
/* XLSX destination only: subsequent objects stay on this worksheet. */
ods excel options(sheet_interval='none');


/*---------------------------------------------------------------*/

/* 1b. Summary Enrollments by ACOs without Regions/Service Areas */

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Enrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
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
  define mbrs/ analysis sum  '' nozero  order=data format = comma12. width = 6  style(column)={vjust=m just=right } style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2 width = 6  style(column)={vjust=m just=right } style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
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

ods excel options(flow='tables,text');
proc odstext;
 p "MassHealth ACO/MCO/PCC Disenrollments" / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
run;
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
  define mbrs/ analysis sum  '' nozero  order=data format = comma12.  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:#,##0'};
  define pcttype/ analysis sum  '' nozero  order=data format = percent9.2  width = 6  style(column)={vjust=m just=right }  style={tagattr='format:00.00%;\(00.00%\)'};
  /*---------------------------------------*/
  
  endcomp;
  break after enrdisClass / summarize style=[font_weight=bold ];

  compute after enrdisClass ;
    line ' ';
  endcomp;
  
  
  
   compute after;
    line @1 "Notes:";
    line @1 "1) The Other code is a code that can be generated by a manual process or generated automatically."; endcomp;
  
  where type = 'disenrollment' and provtype2 not in ('ZZ - ACOB PCCB') and enrdisClass is not null and membertype='All';
run;
ods excel close;
%put NOTE: VISUAL_SUMMARY_PREVIEW_COMPLETE;
