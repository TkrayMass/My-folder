/*======================================================================
  Monthly Advocacy Report
  MASTER CONTROLLER - Production Full Run v7.1 - STARTS AT PROC 0

  PURPOSE
    Run the validated Monthly Advocacy production process end-to-end:

      PROC 0  -> Eligibility / Caseload history
      PROC 1  -> Adds / Reopens
      PROC 2  -> Adds / Reopens by Budget Group
      PROC 3  -> New Eligibility by Agency
      PROC 4  -> New Eligibility by Budget Group
      PROC 5  -> New Terminations by Eligibility Stop
      PROC 6  -> New Terminations by Budget Group
      PROC 7  -> Caseload/Reopens by Budget Group
      PROC 8  -> Caseload with Adds and Terms
      PROC 9  -> Caseload with Adds and Terms by Budget Group
      PROC 10 -> Caseload with Adds and Terms by Reopens

  DESIGN
    - Uses 00_Project_Settings.sas for the reporting month.
    - Runs production programs in dependency-safe order.
    - Does NOT hard-code long production filenames.
    - For each step, automatically finds exactly one production SAS
      file in &MASTER_CODE_DIR whose name begins with 0_ through 10_.
    - Uses DATA-step directory scanning (not macro character comparisons),
      so background SAS Studio runs resolve filenames safely.
    - Supports MASTER_START_PROC so a failed/interrupted chain can restart
      without rerunning already validated earlier procedures.
    - Ignores filenames containing TEST, QC, DIAGNOSTIC, or VALIDATION.
    - Stops if zero or multiple eligible files are found for a step.
    - Verifies the expected permanent DYN output exists.
    - Verifies the current reporting month exists in that output.
    - Uses expected-output/month validation as the primary PASS/FAIL gate.
    - Records SYSCC but does not stop solely on a nonzero return code.
    - Stops before downstream steps if required output validation fails.
    - Creates WORK.ADV_MASTER_STATUS as a run summary.

  IMPORTANT
    This version is for the FIRST MANUAL FULL-RUN VALIDATION.
    LOW-LOG MODE suppresses MPRINT/MLOGIC/SYMBOLGEN/SOURCE/SOURCE2
    so SAS Studio is not overwhelmed by Proc 0 history-loop logging.
    Do not schedule until a complete master run is verified.
    PRODUCTION SETTING: MASTER_START_PROC=0 so every normal monthly
    run begins with Proc 0.  Set 1-10 only for an intentional restart.
======================================================================*/

%include "/sas_mass_health/shared/Advocacy_Dynamic/Include/00_Project_Settings.sas";

options compress=yes nomprint nomlogic nosymbolgen nosource nosource2 nosyntaxcheck;

%let MASTER_CODE_DIR=/sas_mass_health/shared/Advocacy_Dynamic/Code;

/* FULL_RUN executes Proc 0-10 sequentially. */
%let MASTER_MODE=FULL_RUN;

/* RESTART CONTROL
   0 = normal full run from Proc 0
   1-10 = restart mode only, used after a verified prior step
   Change only when intentionally restarting after a verified prior step. */
%let MASTER_START_PROC=0;

libname dyn "/sas_mass_health/shared/Advocacy_Dynamic/Data";

data work.adv_master_status;
    length step $8 program $256 expected_data $64 month_var $32
           status $12 message $300;
    format start_time end_time datetime20.;
    stop;
run;

%macro add_master_status(step=,program=,expected=,monthvar=,status=,message=,start=.,end=.);
    data work._master_status_row;
        length step $8 program $256 expected_data $64 month_var $32
               status $12 message $300;
        format start_time end_time datetime20.;
        step="&step";
        program="&program";
        expected_data="&expected";
        month_var="&monthvar";
        status="&status";
        message="&message";
        start_time=&start;
        end_time=&end;
    run;
    proc append base=work.adv_master_status data=work._master_status_row force;
    run;
    proc datasets library=work nolist;
        delete _master_status_row;
    quit;
%mend add_master_status;

%macro resolve_program(step);
    %global MASTER_STEP_FILE MASTER_MATCH_COUNT MASTER_MATCH_LIST MASTER_DIR_OPEN;

    %let MASTER_STEP_FILE=;
    %let MASTER_MATCH_COUNT=0;
    %let MASTER_MATCH_LIST=;
    %let MASTER_DIR_OPEN=0;

    /* DATA-step directory scan avoids the macro %IF character-comparison
       failure that occurred in SAS Studio background mode. */
    filename _advcode "&MASTER_CODE_DIR";

    data work._master_file_matches;
        length fname upname $256 fullpath $512 prefix $16;
        retain match_count 0;
        did=dopen('_ADVCODE');

        if did <= 0 then do;
            call symputx('MASTER_DIR_OPEN',0,'g');
            stop;
        end;

        call symputx('MASTER_DIR_OPEN',1,'g');
        prefix=upcase(cats("&step",'_'));

        do i=1 to dnum(did);
            fname=dread(did,i);
            upname=upcase(fname);

            if upcase(scan(fname,-1,'.'))='SAS'
               and substr(upname,1,lengthn(prefix))=prefix
               and index(upname,'TEST')=0
               and index(upname,'QC')=0
               and index(upname,'DIAGNOSTIC')=0
               and index(upname,'VALIDATION')=0
            then do;
                match_count+1;
                fullpath=cats("&MASTER_CODE_DIR",'/',fname);
                output;
            end;
        end;

        rc=dclose(did);
        call symputx('MASTER_MATCH_COUNT',match_count,'g');
        keep fname fullpath;
    run;

    filename _advcode clear;

    %if &MASTER_DIR_OPEN = 0 %then %do;
        %put ============================================================;
        %put ERROR: MASTER COULD NOT OPEN CODE DIRECTORY:;
        %put ERROR: &MASTER_CODE_DIR;
        %put ============================================================;
        %let MASTER_MATCH_COUNT=-1;
        %return;
    %end;

    %if &MASTER_MATCH_COUNT > 0 %then %do;
        proc sql noprint;
            select fname
              into :MASTER_MATCH_LIST separated by ' | '
            from work._master_file_matches;

            %if &MASTER_MATCH_COUNT = 1 %then %do;
                select fullpath
                  into :MASTER_STEP_FILE trimmed
                from work._master_file_matches;
            %end;
        quit;
    %end;

    proc datasets library=work nolist;
        delete _master_file_matches;
    quit;
%mend resolve_program;

%let MASTER_STOP=0;

%macro run_adv_step(step=,expected=,monthvar=);
    %local step_start step_end current_rows total_rows syserr_after syscc_after;

    /* Restart support: earlier verified steps are intentionally skipped. */
    %if %sysevalf(&step < &MASTER_START_PROC) %then %do;
        %let step_start=%sysfunc(datetime());
        %let step_end=&step_start;
        %put NOTE: MASTER SKIPPING PROC &step BECAUSE MASTER_START_PROC=&MASTER_START_PROC.;
        %add_master_status(
            step=&step,
            program=SKIPPED BY RESTART,
            expected=&expected,
            monthvar=&monthvar,
            status=SKIPPED,
            message=Skipped because MASTER_START_PROC=&MASTER_START_PROC,
            start=&step_start,
            end=&step_end
        );
        %return;
    %end;

    %if &MASTER_STOP = 1 %then %return;

    %let step_start=%sysfunc(datetime());

    %put ;
    %put ################################################################;
    %put MASTER STARTING PROC &step;
    %put REPORT MONTH=&REPORT_YYYYMM;
    %put ################################################################;

    %resolve_program(&step);

    %if &MASTER_MATCH_COUNT = -1 %then %do;
        %let step_end=%sysfunc(datetime());
        %add_master_status(step=&step,program=NOT RESOLVED,expected=&expected,
            monthvar=&monthvar,status=FAIL,message=Code directory could not be opened,
            start=&step_start,end=&step_end);
        %let MASTER_STOP=1;
        %return;
    %end;

    %if &MASTER_MATCH_COUNT = 0 %then %do;
        %put ============================================================;
        %put ERROR: MASTER STOPPED BEFORE PROC &step.;
        %put ERROR: NO ELIGIBLE PRODUCTION SAS FILE FOUND WITH PREFIX &step._;
        %put ERROR: DIRECTORY=&MASTER_CODE_DIR;
        %put ============================================================;
        %let step_end=%sysfunc(datetime());
        %add_master_status(step=&step,program=NOT FOUND,expected=&expected,
            monthvar=&monthvar,status=FAIL,message=No eligible production SAS file found,
            start=&step_start,end=&step_end);
        %let MASTER_STOP=1;
        %return;
    %end;

    %if &MASTER_MATCH_COUNT > 1 %then %do;
        %put ============================================================;
        %put ERROR: MASTER STOPPED BEFORE PROC &step.;
        %put ERROR: MORE THAN ONE ELIGIBLE PRODUCTION FILE WAS FOUND.;
        %put ERROR: MATCHES=&MASTER_MATCH_LIST;
        %put ERROR: KEEP ONLY ONE PRODUCTION FILE WITH PREFIX &step._;
        %put ERROR: TEST/QC/DIAGNOSTIC/VALIDATION FILES MAY REMAIN.;
        %put ============================================================;
        %let step_end=%sysfunc(datetime());
        %add_master_status(step=&step,program=&MASTER_MATCH_LIST,expected=&expected,
            monthvar=&monthvar,status=FAIL,message=Multiple eligible production SAS files found,
            start=&step_start,end=&step_end);
        %let MASTER_STOP=1;
        %return;
    %end;

    %put NOTE: MASTER PROC &step PROGRAM=&MASTER_STEP_FILE;

    %let SYSCC=0;
    %include "&MASTER_STEP_FILE";

    %let syserr_after=&SYSERR;
    %let syscc_after=&SYSCC;
    %put NOTE: MASTER PROC &step SYSERR=&syserr_after SYSCC=&syscc_after;

    /* Do not stop solely because SYSCC is above 4.
       Some validated Advocacy programs can leave a nonzero return code
       even when the required permanent output is successfully created.
       The master therefore records the code and validates the actual
       expected dataset and reporting month before deciding PASS/FAIL. */

    %if %sysevalf(&syscc_after > 4) %then %do;
        %put WARNING: MASTER PROC &step RETURNED SYSCC=&syscc_after.;
        %put WARNING: MASTER WILL CONTINUE TO OUTPUT VALIDATION BEFORE DECIDING PASS/FAIL.;
    %end;

    %if not %sysfunc(exist(&expected)) %then %do;
        %put ============================================================;
        %put ERROR: MASTER STOPPED AFTER PROC &step.;
        %put ERROR: EXPECTED OUTPUT DATASET DOES NOT EXIST:;
        %put ERROR: &expected;
        %put ============================================================;
        %let step_end=%sysfunc(datetime());
        %add_master_status(step=&step,program=&MASTER_STEP_FILE,expected=&expected,
            monthvar=&monthvar,status=FAIL,message=Expected permanent output dataset was not created,
            start=&step_start,end=&step_end);
        %let MASTER_STOP=1;
        %return;
    %end;

    proc sql noprint;
        select count(*),
               sum(case when &monthvar = &REPORT_YYYYMM then 1 else 0 end)
        into :total_rows trimmed, :current_rows trimmed
        from &expected;
    quit;

    %if %sysevalf(&current_rows = 0) %then %do;
        %put ============================================================;
        %put ERROR: MASTER STOPPED AFTER PROC &step.;
        %put ERROR: EXPECTED OUTPUT EXISTS BUT REPORT MONTH IS MISSING.;
        %put ERROR: DATASET=&expected;
        %put ERROR: MONTH VARIABLE=&monthvar;
        %put ERROR: REPORT MONTH=&REPORT_YYYYMM;
        %put ============================================================;
        %let step_end=%sysfunc(datetime());
        %add_master_status(step=&step,program=&MASTER_STEP_FILE,expected=&expected,
            monthvar=&monthvar,status=FAIL,message=Output exists but current reporting month is missing,
            start=&step_start,end=&step_end);
        %let MASTER_STOP=1;
        %return;
    %end;

    %let step_end=%sysfunc(datetime());
    %put ============================================================;
    %put MASTER PROC &step PASSED.;
    %put PROGRAM=&MASTER_STEP_FILE;
    %put OUTPUT=&expected;
    %put TOTAL ROWS=&total_rows;
    %put CURRENT MONTH ROWS=&current_rows;
    %put ============================================================;

    %add_master_status(step=&step,program=&MASTER_STEP_FILE,expected=&expected,
        monthvar=&monthvar,status=PASS,
        message=Production step completed and current month was verified (SYSCC=&syscc_after),
        start=&step_start,end=&step_end);
%mend run_adv_step;

/* Resolution pre-check. This does not execute production Procs. */
%put ;
%put ============================================================;
%put MASTER FILE RESOLUTION TEST STARTING;
%put ============================================================;

%macro test_resolve_all;
    %local s;
    %do s=0 %to 10;
        %resolve_program(&s);
        %put ------------------------------------------------------------;
        %put PROC &s;
        %put MATCH COUNT=&MASTER_MATCH_COUNT;
        %put FILE=&MASTER_STEP_FILE;
        %if &MASTER_MATCH_COUNT = 1 %then %put STATUS=PASS;
        %else %if &MASTER_MATCH_COUNT = 0 %then %put STATUS=FAIL - NO PRODUCTION FILE FOUND;
        %else %if &MASTER_MATCH_COUNT > 1 %then %do;
            %put STATUS=FAIL - MULTIPLE PRODUCTION FILES FOUND;
            %put MATCHES=&MASTER_MATCH_LIST;
        %end;
        %else %put STATUS=FAIL - CODE DIRECTORY COULD NOT BE OPENED;
    %end;
%mend test_resolve_all;

%test_resolve_all;

%put ;
%put ============================================================;
%put MASTER FILE RESOLUTION TEST FINISHED;
%put ============================================================;

%macro execute_master_by_mode;

    %if not (%sysevalf(&MASTER_START_PROC >= 0) and %sysevalf(&MASTER_START_PROC <= 10)) %then %do;
        %put ################################################################;
        %put ERROR: INVALID MASTER_START_PROC=&MASTER_START_PROC;
        %put ERROR: VALID VALUES ARE 0 THROUGH 10.;
        %put ERROR: NOTHING WAS EXECUTED.;
        %put ################################################################;
        %return;
    %end;

    %if %upcase(&MASTER_MODE) = RESOLVE_ONLY %then %do;
        %put ;
        %put ################################################################;
        %put MASTER CONTROLLER RESOLUTION-ONLY TEST COMPLETE.;
        %put NO PROC 0-10 PRODUCTION PROGRAMS WERE EXECUTED.;
        %put ################################################################;
    %end;

    %else %if %upcase(&MASTER_MODE) = FULL_RUN %then %do;

        %put ;
        %put ==================================================================;
        %put MONTHLY ADVOCACY MASTER STARTING;
        %put REPORT MONTH=&REPORT_YYYYMM;
        %put RUN DATE=%sysfunc(date(),date9.);
        %put CODE DIRECTORY=&MASTER_CODE_DIR;
%put START PROC=&MASTER_START_PROC;
        %put ==================================================================;

        %run_adv_step(step=0,expected=DYN.BUDGET_ADV_ELIG_&REPORT_YYYYMM._X_DYN,monthvar=YR_MTH);
        %run_adv_step(step=1,expected=DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV4_DYN,monthvar=YR_MTH);
        %run_adv_step(step=2,expected=DYN.ADV_&REPORT_YYYYMM._ADDS_NEWV5_DYN,monthvar=YR_MTH);
        %run_adv_step(step=3,expected=DYN.ADV_&REPORT_YYYYMM._ELIG_AGCY_DYN,monthvar=CURRMONTH);
        %run_adv_step(step=4,expected=DYN.ADV_&REPORT_YYYYMM._ADDS_BG_DYN,monthvar=YR_MTH);
        %run_adv_step(step=5,expected=DYN.ADV_&REPORT_YYYYMM._TERMS_DYN,monthvar=CURRMONTH);
        %run_adv_step(step=6,expected=DYN.ADV_&REPORT_YYYYMM._TERMS_BG_DYN,monthvar=YR_MTH);
        %run_adv_step(step=7,expected=DYN.ADV_&REPORT_YYYYMM._CASELOAD_REOPENS_DYN,monthvar=CURRMONTH);
        %run_adv_step(step=8,expected=DYN.ADV_&REPORT_YYYYMM._CASELOAD_AT_DYN,monthvar=CURRMONTH);
        %run_adv_step(step=9,expected=DYN.ADV_&REPORT_YYYYMM._CASELOAD_BG_DYN,monthvar=CURRMONTH);
        %run_adv_step(step=10,expected=DYN.ADV_&REPORT_YYYYMM._REOPENS_V10_DYN,monthvar=CURRMONTH);

        %if &MASTER_STOP = 0 %then %do;
            %put ;
            %put ################################################################;
            %put MONTHLY ADVOCACY MASTER FINISHED SUCCESSFULLY;
            %put REPORT MONTH=&REPORT_YYYYMM;
            %put ALL EXECUTED PROCS FROM &MASTER_START_PROC THROUGH PROC 10 PASSED.;
            %put ################################################################;
        %end;
        %else %do;
            %put ;
            %put ################################################################;
            %put MONTHLY ADVOCACY MASTER STOPPED BEFORE COMPLETION;
            %put REPORT MONTH=&REPORT_YYYYMM;
            %put REVIEW WORK.ADV_MASTER_STATUS AND THE FIRST ERROR IN THE LOG.;
            %put ################################################################;
        %end;

        title "Monthly Advocacy Master Run Status";
        proc print data=work.adv_master_status noobs;
            var step status program expected_data month_var message start_time end_time;
        run;
        title;

        filename _advcode clear;
        %put ==================================================================;
        %put MONTHLY ADVOCACY MASTER END;
        %put MASTER_STOP=&MASTER_STOP;
        %put ==================================================================;
    %end;

    %else %do;
        %put ;
        %put ################################################################;
        %put ERROR: INVALID MASTER_MODE=&MASTER_MODE;
        %put ERROR: VALID VALUES ARE RESOLVE_ONLY OR FULL_RUN.;
        %put ERROR: NOTHING WAS EXECUTED.;
        %put ################################################################;
    %end;

%mend execute_master_by_mode;

%execute_master_by_mode;
