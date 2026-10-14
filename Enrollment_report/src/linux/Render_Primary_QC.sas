/* Primary QC: all baseline/current periods, plus meaningful flags only. */
ods _all_ close;
options nodate nonumber;
%let qcdir=%superq(sysparm);
%macro checkpath;
 %if not %sysfunc(prxmatch(%str(/^\/sas_mass_health\/shared\/tkray\/Enrollment\/Reports\/ACO_REBUILD_XLSX\/runs\/[A-Za-z0-9_]+\/qc_versions\/[A-Za-z0-9_]+\/Primary_Render$/),%superq(qcdir))) %then %abort cancel;
%mend;
%checkpath;
%macro readcsv(member,file);
 data &member.;
  infile "&qcdir./&file..csv" dsd firstobs=2 lrecl=32767 truncover;
  length SECTION $24 CATEGORY $100 MONTH $7 STATUS $12;
  input SECTION :$24. CATEGORY :$100. MONTH :$7. PRIOR CURRENT DIFFERENCE PCT_CHANGE WARNING BLOCKING STATUS :$12.;
  format PRIOR CURRENT DIFFERENCE WARNING BLOCKING comma20.2 PCT_CHANGE percent12.2;
 run;
%mend;
%readcsv(primary,Primary_All);
%readcsv(flags,Primary_Flags);
ods excel file="&qcdir./ACO_Enrollment_Comparison_QC.xlsx"
 options(sheet_name='QC Summary' sheet_interval='none' embedded_titles='yes'
   frozen_headers='on' autofilter='all' gridlines='off' flow='tables'
   absolute_column_width='20,38,12,19,19,19,16,18,18,14') style=minimal;
%macro table(member);
 proc report data=&member. nowd missing
  style(header)=[background=cx24445B foreground=white font_face='Arial' font_size=11pt font_weight=bold]
  style(column)=[font_face='Arial' font_size=11pt];
  columns SECTION CATEGORY MONTH PRIOR CURRENT DIFFERENCE PCT_CHANGE WARNING BLOCKING STATUS;
  define SECTION / display 'Report section'; define CATEGORY / display 'Category';
  define MONTH / display 'Month'; define PRIOR / display 'Last distributed';
  define CURRENT / display 'Current report'; define DIFFERENCE / display 'Change';
  define PCT_CHANGE / display 'Change %'; define WARNING / display 'Warning threshold';
  define BLOCKING / display 'Blocking threshold'; define STATUS / display 'Status';
  compute STATUS;
   if STATUS='REVIEW' then call define(_row_,'style','style=[background=cxFFF2CC]');
   else if STATUS='FAIL' then call define(_row_,'style','style=[background=cxFF9999]');
  endcomp;
 run;
%mend;
title justify=left font='Arial' height=15pt bold 'Enrollment QC: current versus last distributed report';
title2 justify=left font='Arial' height=10pt 'MTD warnings remain nonblocking. Blank change % means the prior value was zero.';
%table(primary);
ods excel options(sheet_name='QC Detail' sheet_interval='now');
title 'Enrollment QC: threshold warnings and failures';
title2;
%table(flags);
ods excel close;
%macro complete;
 %if &syscc > 4 %then %abort cancel;
 %put NOTE: PRIMARY_QC_RENDER_COMPLETE;
%mend;
%complete;
