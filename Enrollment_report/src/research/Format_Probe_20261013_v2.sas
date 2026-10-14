ods _all_ close;
options nodate nonumber;
%let EndDate_char=2026-10-13;

/* Formatting reference: published October 7 report. Native numeric widths
   grow with the reporting months, so no fixed last-column limit is used. */
%macro U_NATIVE_WIDTHS(prefix=,num=);
 %local _i _months;
 %let _months=%eval(%sysfunc(intck(month,%sysfunc(inputn(20230301,yymmdd8.)),%sysfunc(inputn(&EndDate_char.,yymmdd10.))))+1);
 &prefix.%do _i=1 %to %eval(2*&_months.);,&num.%end;
%mend;

data work.sample; length A B C $10; array m M1-M88; do row=1 to 5; A="All";B="ACO A";C="All";do i=1 to 88;m[i]=1000+i;end;output;end;drop i row;run;
ods excel file="/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/probe/Format_Probe_20261013_v2.xlsx" options(sheet_name="Summary" sheet_interval="none" absolute_column_width="%U_NATIVE_WIDTHS(prefix=%str(17.17,10.623125,17.17),num=8.986406)" frozen_headers="3" frozen_rowheaders="off") style=minimal;
proc print data=work.sample noobs;run;ods excel close;
%put NOTE: FORMAT_PROBE_COMPLETE;
