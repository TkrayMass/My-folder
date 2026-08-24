/*======================================================================
  Monthly Advocacy Report
  AUTOMATION WRAPPER - First Wednesday Production Run v1

  PURPOSE
    Run the validated Monthly Advocacy master controller unattended,
    preserve a permanent run log/status file, and create a SUCCESS marker
    only when Proc 0 through Proc 10 all PASS.

  SCHEDULE TARGET
    First Wednesday of each month.

  MASTER CALLED
    /sas_mass_health/shared/Advocacy_Dynamic/Code/
    MASTER_Advocacy_Monthly_Production_v7_1_START_PROC0.sas

  OUTPUTS
    Logs:
      /sas_mass_health/shared/Advocacy_Dynamic/Logs/
      Advocacy_Master_<YYYYMM>_<timestamp>.log

    QC status CSV:
      /sas_mass_health/shared/Advocacy_Dynamic/QC/
      Advocacy_Master_Status_<YYYYMM>_<timestamp>.csv

    Success marker:
      /sas_mass_health/shared/Advocacy_Dynamic/QC/
      Advocacy_Master_<YYYYMM>_SUCCESS.flag

  IMPORTANT
    - The SUCCESS marker is deleted at the beginning of every run.
    - It is recreated only if all 11 steps (Proc 0-10) are PASS.
    - The later Windows transfer job should require this SUCCESS marker
      before copying files to the shared drive.
======================================================================*/

%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options nomprint nomlogic nosymbolgen nosource nosource2;

%let ADV_MASTER_PROGRAM=/sas_mass_health/shared/Advocacy_Dynamic/Code/MASTER_Advocacy_Monthly_Production_v7_1_START_PROC0.sas;
%let ADV_LOG_DIR=/sas_mass_health/shared/Advocacy_Dynamic/Logs;
%let ADV_QC_DIR=/sas_mass_health/shared/Advocacy_Dynamic/QC;

data _null_;
    length stamp $15;
    stamp = cats(put(date(),yymmddn8.),'_',compress(put(time(),time8.),':'));
    call symputx('ADV_RUN_STAMP',stamp,'g');
run;

%let ADV_RUN_LOG=&ADV_LOG_DIR./Advocacy_Master_&REPORT_YYYYMM._&ADV_RUN_STAMP..log;
%let ADV_STATUS_CSV=&ADV_QC_DIR./Advocacy_Master_Status_&REPORT_YYYYMM._&ADV_RUN_STAMP..csv;
%let ADV_SUCCESS_FLAG=&ADV_QC_DIR./Advocacy_Master_&REPORT_YYYYMM._SUCCESS.flag;

filename advflag "&ADV_SUCCESS_FLAG";

data _null_;
    if fexist('advflag') then rc=fdelete('advflag');
run;

filename advflag clear;

proc printto log="&ADV_RUN_LOG" new;
run;

%put ============================================================;
%put MONTHLY ADVOCACY AUTOMATION WRAPPER STARTING;
%put REPORT MONTH=&REPORT_YYYYMM;
%put RUN STAMP=&ADV_RUN_STAMP;
%put MASTER=&ADV_MASTER_PROGRAM;
%put LOG=&ADV_RUN_LOG;
%put ============================================================;

%include "&ADV_MASTER_PROGRAM";

%let ADV_AUTOMATION_PASS=0;
%let ADV_STATUS_ROWS=0;
%let ADV_PASS_ROWS=0;
%let ADV_FAIL_ROWS=0;
%let ADV_SKIP_ROWS=0;

%macro adv_validate_master;

    %if not %sysfunc(exist(work.adv_master_status)) %then %do;
        %put ERROR: AUTOMATION WRAPPER - WORK.ADV_MASTER_STATUS DOES NOT EXIST.;
        %return;
    %end;

    proc sql noprint;
        select count(*),
               sum(upcase(status)='PASS'),
               sum(upcase(status)='FAIL'),
               sum(upcase(status)='SKIPPED')
        into :ADV_STATUS_ROWS trimmed,
             :ADV_PASS_ROWS trimmed,
             :ADV_FAIL_ROWS trimmed,
             :ADV_SKIP_ROWS trimmed
        from work.adv_master_status;
    quit;

    %if &ADV_STATUS_ROWS = 11
        and &ADV_PASS_ROWS = 11
        and &ADV_FAIL_ROWS = 0
        and &ADV_SKIP_ROWS = 0
    %then %do;
        %let ADV_AUTOMATION_PASS=1;
    %end;

%mend adv_validate_master;

%adv_validate_master;

%if %sysfunc(exist(work.adv_master_status)) %then %do;

    proc export
        data=work.adv_master_status
        outfile="&ADV_STATUS_CSV"
        dbms=csv
        replace;
    run;

%end;

%if &ADV_AUTOMATION_PASS = 1 %then %do;

    filename advflag "&ADV_SUCCESS_FLAG";

    data _null_;
        file advflag;
        put "STATUS=SUCCESS";
        put "REPORT_YYYYMM=&REPORT_YYYYMM";
        put "RUN_STAMP=&ADV_RUN_STAMP";
        put "PASS_ROWS=&ADV_PASS_ROWS";
        put "STATUS_ROWS=&ADV_STATUS_ROWS";
        put "MASTER=&ADV_MASTER_PROGRAM";
        put "LOG=&ADV_RUN_LOG";
        put "STATUS_CSV=&ADV_STATUS_CSV";
    run;

    filename advflag clear;

    %put ============================================================;
    %put MONTHLY ADVOCACY AUTOMATION WRAPPER SUCCESS;
    %put REPORT MONTH=&REPORT_YYYYMM;
    %put PASS ROWS=&ADV_PASS_ROWS;
    %put SUCCESS FLAG=&ADV_SUCCESS_FLAG;
    %put ============================================================;

%end;
%else %do;

    %put ============================================================;
    %put ERROR: MONTHLY ADVOCACY AUTOMATION WRAPPER FAILED QC.;
    %put ERROR: REPORT MONTH=&REPORT_YYYYMM;
    %put ERROR: STATUS ROWS=&ADV_STATUS_ROWS;
    %put ERROR: PASS ROWS=&ADV_PASS_ROWS;
    %put ERROR: FAIL ROWS=&ADV_FAIL_ROWS;
    %put ERROR: SKIPPED ROWS=&ADV_SKIP_ROWS;
    %put ERROR: SUCCESS FLAG WAS NOT CREATED.;
    %put ============================================================;

%end;

proc printto;
run;
