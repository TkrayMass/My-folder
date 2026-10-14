/* Visual capability probe: sample data only, no source queries or publication. */
ods _all_ close;
options nodate nonumber;
proc template;
 define style styles.ACOVisual;
 parent=styles.minimal;
 style fonts from fonts /
  'docFont'=('Arial',11pt) 'headingFont'=('Arial',11pt,bold)
  'TitleFont'=('Arial',11pt,bold) 'TitleFont2'=('Arial',11pt,bold)
  'FixedFont'=('Arial',11pt) 'BatchFixedFont'=('Arial',11pt)
  'StrongFont'=('Arial',11pt,bold);
 end;
run;
data sample;
 length category plan $12;
 input plan $ members;
 category='All';
 datalines;
ACO_A 722790
ACO_B 487511
MCO 119178
PCC 134231
;
run;
ods excel file='/sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/probe/Visual_Match_Probe.xlsx'
 options(sheet_name='Summary' sheet_interval='none' flow='text' gridlines='off'
         absolute_column_width='17.17,10.623125,8.986406' frozen_headers='7') style=styles.ACOVisual;
proc odstext;
 p 'Weekly ACO/MCO/PCC Enrollment Report for week of 20261013' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p 'MH Analytics' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ';
 p "Member caseload taken from state eligibility and represent an average unique member count per week for the 'Week of' and unique member count per day for the 'Day of'." / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p 'Member enrollment and disenrollment taken from enrollment table and the add and end codes grouped based on the crosswalk on the Code Crosswalk Tab' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ';
 p 'MassHealth ACO/MCO/PCC Members' / style=[font_face='Arial' font_size=11pt font_weight=bold just=left];
 p ' ';
run;
ods excel options(flow='tables');
proc report data=sample nowd spanrows missing
 style(report)=[font_face='Arial' font_size=11pt rules=all frame=box bordercolor=black borderwidth=1]
 style(header)=[font_face='Arial' font_size=11pt font_weight=bold background=blue foreground=white]
 style(column)=[font_face='Arial' font_size=11pt foreground=black];
 columns category plan members;
 define category / group 'Caseload';
 define plan / display 'Plan Type';
 define members / analysis sum '20230301' format=comma12. style(column)=[tagattr='format:#,##0'];
 break after category / summarize style=[font_weight=bold];
run;
ods excel close;
%put NOTE: VISUAL_MATCH_PROBE_COMPLETE;
