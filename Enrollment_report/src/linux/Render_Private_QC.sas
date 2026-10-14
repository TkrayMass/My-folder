/* Render prepared private QC inputs only. No refresh, mail or publication.
   SYSPARM = absolute prepared render directory under the isolated audit root. */
ods _all_ close;
options nodate nonumber;
%let qcdir=%superq(sysparm);
%macro validate_path;
 %if not %sysfunc(prxmatch(%str(/^\/sas_mass_health\/shared\/tkray\/Enrollment\/Reports\/ACO_REBUILD(?:_XLSX)?\/runs\/[A-Za-z0-9_]+\/qc_versions\/[A-Za-z0-9_]+\/[A-Za-z0-9_]+$/),%superq(qcdir))) %then %do;
  %put ERROR: Invalid private QC render directory.; %abort cancel;
 %end;
%mend;
%validate_path;
filename summary "&qcdir./QC_Display_Summary.csv";
filename details "&qcdir./QC_Display_Detail.csv";
data qc_summary;
 infile summary dsd firstobs=2 lrecl=32767 truncover;
 length CHECK $80 RESULT $24 EVIDENCE $1000;
 input CHECK :$80. RESULT :$24. EVIDENCE :$1000.;
run;
data qc_detail;
 infile details dsd firstobs=2 lrecl=32767 truncover;
 length STATUS $12 CHECK $32 WORKSHEET $80 MEMBER_GROUP $80 CATEGORY $80 MEASURE $24 REASON $1000;
 input STATUS :$12. CHECK :$32. WORKSHEET :$80. MEMBER_GROUP :$80. CATEGORY :$80.
       MONTH :yymmdd8. MEASURE :$24. REFERENCE CURRENT DIFFERENCE TOLERANCE BLOCKING_THRESHOLD REASON :$1000.;
 format MONTH monyy7. REFERENCE CURRENT DIFFERENCE TOLERANCE BLOCKING_THRESHOLD comma18.4;
run;
ods excel file="&qcdir./ACO_Weekly_Final_QC_Colored.xlsx"
 options(sheet_name='QC Summary' sheet_interval='none' flow='tables' embedded_titles='yes'
         absolute_column_width='29,18,90' row_heights='30,38,20,30,20,10,10' gridlines='off') style=minimal;
title justify=left font='Arial' height=16pt bold 'ACO Weekly Enrollment QC';
proc report data=qc_summary nowd missing
 style(header)=[background=cx24445B foreground=white font_face='Arial' font_size=10pt font_weight=bold]
 style(column)=[font_face='Arial' font_size=10pt vjust=center];
 columns CHECK RESULT EVIDENCE;
 define CHECK / display 'Check'; define RESULT / display 'Result'; define EVIDENCE / display 'Evidence';
 compute RESULT;
  if RESULT='REVIEW' then call define(_row_,'style','style=[background=cxFFF2CC]');
  else if RESULT='FAIL' then call define(_row_,'style','style=[background=cxFF9999]');
 endcomp;
run;
ods excel options(sheet_name='QC Detail' sheet_interval='now' autofilter='all'
                 frozen_headers='on' frozen_rowheaders='3' row_heights='36,32,20,30,20,10,10'
                 absolute_column_width='13,24,31,24,30,15,23,18,18,18,18,18,68');
title justify=left font='Arial' height=16pt bold 'ACO Weekly Enrollment QC Detail';
proc report data=qc_detail nowd missing
 style(header)=[background=cx24445B foreground=white font_face='Arial' font_size=10pt font_weight=bold]
 style(column)=[font_face='Arial' font_size=10pt vjust=center];
 columns STATUS CHECK WORKSHEET MEMBER_GROUP CATEGORY MONTH MEASURE REFERENCE CURRENT DIFFERENCE TOLERANCE BLOCKING_THRESHOLD REASON;
 define STATUS / display 'Status'; define CHECK / display 'Check'; define WORKSHEET / display 'Worksheet';
 define MEMBER_GROUP / display 'Member / group'; define CATEGORY / display 'Category'; define MONTH / display 'Month';
 define MEASURE / display 'Measure'; define REFERENCE / display 'Reference value'; define CURRENT / display 'Current value';
 define DIFFERENCE / display 'Difference'; define TOLERANCE / display 'Tolerance / warning';
 define BLOCKING_THRESHOLD / display 'Blocking threshold'; define REASON / display 'Reason';
 compute STATUS;
  if STATUS='REVIEW' then call define(_row_,'style','style=[background=cxFFF2CC]');
  else if STATUS='FAIL' then call define(_row_,'style','style=[background=cxFF9999]');
 endcomp;
run;
ods excel close;
%macro complete;
 %if &syscc > 4 %then %do; %put ERROR: Private QC rendering failed SYSCC=&syscc.; %abort cancel; %end;
 %put NOTE: PRIVATE_QC_RENDER_COMPLETE;
%mend;
%complete;
