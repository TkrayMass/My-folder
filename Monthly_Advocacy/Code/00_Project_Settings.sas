/*===============================================================
  Monthly Advocacy Dynamic Project Settings
  Production Automation Version v1

  PURPOSE
    Central project settings for the automated Monthly Advocacy
    Report.

  PRODUCTION BEHAVIOR
    - RUN_DATE is the actual SAS server run date.
    - The reporting month is always the prior calendar month.
    - The extraction date is the first day of the run month.
    - The monthly output folder is created automatically as MM_YYYY.
================================================================*/


/*---------------------------------------------------------------
  1. Project folders
----------------------------------------------------------------*/
%let ADV_BASE=/sas_mass_health/shared/Advocacy_Dynamic;
%let ADV_CODE=&ADV_BASE/Code;
%let ADV_DATA=&ADV_BASE/Data;
%let ADV_INCLUDE=&ADV_BASE/Include;
%let ADV_OUTPUT=&ADV_BASE/Output;
%let ADV_QC=&ADV_BASE/QC;
%let ADV_LOGS=&ADV_BASE/Logs;
%let ADV_ARCHIVE=&ADV_BASE/Archive;
%let ADV_DOC=&ADV_BASE/Documentation;


/*---------------------------------------------------------------
  2. Production run date

  AUTOMATION:
    Uses the actual SAS server date.

  Example:
    Run on 02SEP2026
      RUN_DATE          = 02SEP2026
      REPORT month      = AUG2026
      REPORT_YYYYMM     = 202608
      OUTPUT_FOLDER     = 08_2026
----------------------------------------------------------------*/
%let RUN_DATE=%sysfunc(today());


/*---------------------------------------------------------------
  3. Dynamic reporting dates
----------------------------------------------------------------*/
%let REPORT_MONTH_BEGIN=%sysfunc(intnx(month,&RUN_DATE,-1,b));
%let REPORT_MONTH_END=%sysfunc(intnx(month,&RUN_DATE,-1,e));

/* First day of the current/run month */
%let EXTRACTION_DATE=%sysfunc(intnx(month,&RUN_DATE,0,b));

/* End of month immediately before the reporting month */
%let PRIOR_MONTH_END=%sysfunc(intnx(month,&RUN_DATE,-2,e));

%let REPORT_YYYYMM=%sysfunc(putn(&REPORT_MONTH_END,yymmn6.));
%let PRIOR_YYYYMM=%sysfunc(putn(&PRIOR_MONTH_END,yymmn6.));
%let REPORT_YYYYMMDD=%sysfunc(putn(&REPORT_MONTH_END,yymmddn8.));

/* MM_YYYY output folder */
%let OUTPUT_FOLDER=%substr(&REPORT_YYYYMM,5,2)_%substr(&REPORT_YYYYMM,1,4);


/*---------------------------------------------------------------
  4. Dynamic development / production library
----------------------------------------------------------------*/
libname dyn "&ADV_DATA";


/*---------------------------------------------------------------
  5. Ensure monthly output folder exists

  Creates:
    &ADV_OUTPUT/&OUTPUT_FOLDER

  Example:
    /sas_mass_health/shared/Advocacy_Dynamic/Output/08_2026
----------------------------------------------------------------*/
%let ADV_OUTPUT_MONTH=&ADV_OUTPUT/&OUTPUT_FOLDER;
%let ADV_OUTPUT_FOLDER_STATUS=UNKNOWN;

data _null_;
    length folder_path parent_path folder_name $500
           created_path $500;

    folder_path="&ADV_OUTPUT_MONTH";
    parent_path="&ADV_OUTPUT";
    folder_name="&OUTPUT_FOLDER";

    rc=filename('_advout',folder_path);
    did=dopen('_advout');

    if did > 0 then do;
        rc=dclose(did);
        call symputx('ADV_OUTPUT_FOLDER_STATUS','EXISTS','g');
    end;
    else do;
        created_path=dcreate(strip(folder_name),strip(parent_path));

        if not missing(created_path) then
            call symputx('ADV_OUTPUT_FOLDER_STATUS','CREATED','g');
        else
            call symputx('ADV_OUTPUT_FOLDER_STATUS','FAILED','g');
    end;

    rc=filename('_advout');
run;


/*---------------------------------------------------------------
  6. Production safety check
----------------------------------------------------------------*/
%macro adv_settings_validate;

    %if %upcase(&ADV_OUTPUT_FOLDER_STATUS)=FAILED %then %do;
        %put ============================================================;
        %put ERROR: ADVOCACY PROJECT SETTINGS FAILED.;
        %put ERROR: MONTHLY OUTPUT FOLDER COULD NOT BE CREATED:;
        %put ERROR: &ADV_OUTPUT_MONTH;
        %put ============================================================;
        %abort cancel;
    %end;

%mend adv_settings_validate;

%adv_settings_validate;


/*---------------------------------------------------------------
  7. Settings display / audit trail
----------------------------------------------------------------*/
%put ============================================================;
%put ADVOCACY DYNAMIC PROJECT SETTINGS - PRODUCTION;
%put RUN_DATE=%sysfunc(putn(&RUN_DATE,date9.));
%put REPORT_MONTH_BEGIN=%sysfunc(putn(&REPORT_MONTH_BEGIN,date9.));
%put REPORT_MONTH_END=%sysfunc(putn(&REPORT_MONTH_END,date9.));
%put EXTRACTION_DATE=%sysfunc(putn(&EXTRACTION_DATE,date9.));
%put PRIOR_MONTH_END=%sysfunc(putn(&PRIOR_MONTH_END,date9.));
%put REPORT_YYYYMM=&REPORT_YYYYMM;
%put PRIOR_YYYYMM=&PRIOR_YYYYMM;
%put REPORT_YYYYMMDD=&REPORT_YYYYMMDD;
%put OUTPUT_FOLDER=&OUTPUT_FOLDER;
%put OUTPUT_PATH=&ADV_OUTPUT_MONTH;
%put OUTPUT_FOLDER_STATUS=&ADV_OUTPUT_FOLDER_STATUS;
%put ============================================================;

