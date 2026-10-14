/* Small destination capability test only. No Snowflake, email, or report refresh. */
ods _all_ close;
options nodate nonumber;
ods excel file='/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/probe/Native_XLSX_Probe.xlsx'
 options(sheet_interval='none' sheet_name='Summary' embedded_titles='yes'
         absolute_column_width='18' flow='tables' frozen_headers='on') style=minimal;
title 'Native XLSX capability check';
proc print data=sashelp.class(obs=3) noobs; run;
title 'Second table on Summary';
proc print data=sashelp.class(obs=2) noobs; run;
ods excel options(sheet_name='Detail' sheet_interval='now');
title 'Detail sheet';
proc print data=sashelp.class(obs=4) noobs; run;
ods excel options(sheet_interval='none');
ods excel close;
%macro complete;
 %if &syscc > 4 %then %abort cancel;
 %put NOTE: ACO_NATIVE_XLSX_PROBE_COMPLETE;
%mend;
%complete;
