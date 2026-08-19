# ACO Weekly Enrollment Report Automation

## Production Implementation

This repository contains the production automation used to generate,
validate, publish, and distribute the ACO Weekly Enrollment Report.

The process combines SAS, Snowflake, Linux cron, Linux retry/error
handling, Windows Task Scheduler, PowerShell, Python/SCP file transfer,
Microsoft Excel automation, Outlook email distribution, and OneDrive /
SharePoint publishing.

## 1. Production Workflow

The weekly process is intentionally divided into two stages.

### Wednesday -- Report Generation, QC, and Publishing

At **9:00 AM Eastern**, Linux cron starts the weekly SAS process on
`dph-pr-sgn-lap09`.

Cron entry:

``` bash
CRON_TZ=America/New_York
0 9 * * 3 /sas_mass_health/shared/tkray/Enrollment/Reports/run_aco_weekly_retry.sh >> /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_Weekly_Cron.log 2>&1
```

The Linux wrapper `run_aco_weekly_retry.sh` runs:

`/sas_mass_health/shared/pgm/ACOWeeklyReport/Monthly_View_Report_Automated_Production.sas`

The wrapper allows up to **3 attempts**, with **10 minutes between
failed attempts**.

A run is considered successful only when: 1. SAS returns exit code 0. 2.
The SAS log does not contain a line beginning with `ERROR:`.

Individual attempt logs are written to:

`/sas_mass_health/shared/tkray/Enrollment/Reports/`

Example:

`ACO_Weekly_20260819_130002_attempt1.log`

Master retry history:

`ACO_Weekly_Master.log`

Cron output:

`ACO_Weekly_Cron.log`

## 2. Production SAS Program

Production SAS file:

`Monthly_View_Report_Automated_Production.sas`

Current production version:

`v3.13.1 PRODUCTION - DISTRIBUTION DECISION QC`

The program: - Preserves the validated manual report calculations. -
Reads dynamic report dates from Snowflake. - Calls
`ACOENR_WEEKLY_REFRESH()`. - Validates `ACOENR_02_ENRDIS`. - Rebuilds
the ACO enrollment reporting tables. - Creates the required enrollment
Excel workbook. - Creates the SAS QA/QC workbook. - Performs prior-week
QC comparisons. - Produces `QC_Summary`, `QC_Matrix`, and `QC_Detail`. -
Separates blocking failures, warnings, and informational MTD flags. -
Produces an operational Distribution Decision.

Possible Distribution Decisions:

-   `READY TO DISTRIBUTE`
-   `REVIEW BEFORE DISTRIBUTION`
-   `DO NOT DISTRIBUTE`

`READY TO DISTRIBUTE` is required before the automated Friday
distribution email can be sent.

## 3. Wednesday Windows Automation

After the SAS report is generated, the Windows automation performs the
remaining processing.

Main orchestration script:

`Run_ACO_Weekly_Full_Process.ps1`

Supporting batch launcher:

`run_aco_weekly_full_process.bat`

Supporting transfer automation:

`Enrollment_Weekly_Automation.py`

The Wednesday Windows process handles: 1. Detection/retrieval of the
completed SAS output. 2. Transfer from the Linux/SAS environment. 3.
Verification that required files exist. 4. Excel formatting. 5. QC
verification. 6. Publishing of the approved REGXSA workbook. 7. Logging
of the automation result.

## 4. Excel Formatting

PowerShell formatting script:

`Format_Enrollment_Workbook.ps1`

Batch launcher:

`format_enrollment_workbook.bat`

The formatting step uses Microsoft Excel automation to prepare the
generated workbook for distribution.

The batch file accepts the full path of the REGXSA workbook and calls
the PowerShell formatting script.

Example:

``` bat
format_enrollment_workbook.bat "full-path-to-REGXSA.xls"
```

A non-zero PowerShell exit code causes the formatting step to fail.

## 5. Report Output Location

The approved weekly report is stored under:

`Z:\Analytics\Rouba\Enrollment and switcher report\`

Each weekly run receives its own folder.

Example:

`Enrollment Report 8-19-2026`

Primary report:

`ReportTestMonthly-YYYYMMDD_REGXSA.xlsx`

QC workbook:

`ReportTestMonthly-YYYYMMDD_SASQA.xlsx`

## 6. Publishing Location

After successful Wednesday processing, the approved REGXSA workbook is
published to:

`OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report`

This OneDrive location is shared through SharePoint and is the location
used by report recipients.

The Wednesday process does **not** send the final distribution email.
This separation allows the report and QC results to be reviewed before
Friday distribution.

## 7. Friday Distribution

Friday distribution is handled separately from Wednesday report
generation.

PowerShell script:

`Send_ACO_Weekly_Friday_Distribution.ps1`

Batch launcher:

`run_aco_weekly_friday_distribution.bat`

The Friday script defaults to the most recent Wednesday report date.

Before sending an email, it verifies: 1. The Wednesday REGXSA workbook
exists. 2. The SASQA workbook exists. 3. The published OneDrive copy
exists. 4. None of the required files are zero bytes. 5. The published
REGXSA file size matches the approved shared-drive REGXSA file. 6. The
QC workbook contains a valid Distribution Decision. 7. The Distribution
Decision is exactly `READY TO DISTRIBUTE`.

If the decision is `REVIEW BEFORE DISTRIBUTION` or `DO NOT DISTRIBUTE`,
Friday distribution is blocked.

## 8. Duplicate Email Protection

The Friday script creates a sent marker only after Outlook successfully
accepts the distribution message.

Marker naming convention:

`ACO_Weekly_Email_Sent_YYYYMMDD.ok`

The marker prevents the same weekly report from being distributed twice
accidentally.

The script supports `-ForceSend` for an intentional manual resend. This
option should only be used when a duplicate distribution is specifically
required.

## 9. Distribution Email

The automated Outlook message uses:

**Subject:** `Enrollment`

Message:

``` text
Hello all, please find the enrollment report (as of MM/DD/YYYY) shared. As always please let me know if you have any questions.

[SharePoint folder link]

Thank you,
Tanya
```

Current distribution list: - Richard Blackman - Nathan Dean - Terence
Finnigan - Tatyana Kray - Robert Roche - Rouba Youssef -
alejandro.e.garciadavalos@mass.gov - Elizabeth Neal

Outlook resolves the recipient names before sending. If one or more
recipients cannot be resolved, distribution fails rather than sending an
incomplete email.

## 10. Friday Distribution Log

Friday processing is logged to:

`ACO_Weekly_Friday_Distribution.log`

Successful distribution ends with:

`FINAL STATUS = SUCCESS - FRIDAY DISTRIBUTION SENT`

If the report was already distributed:

`FINAL STATUS = SUCCESS - ALREADY SENT / NO ACTION`

A failure ends with:

`FINAL STATUS = FAILED`

## 11. Production Code Files

The GitHub `Code` folder contains the production automation components.

### SAS

-   `Monthly_View_Report_Automated_Production.sas` --- Main ACO Weekly
    Enrollment report and QC generation.

### Linux

-   `run_aco_weekly_retry.sh` --- Runs the SAS production program and
    provides three-attempt retry protection.

### Windows / PowerShell

-   `Run_ACO_Weekly_Full_Process.ps1`
-   `Format_Enrollment_Workbook.ps1`
-   `Send_ACO_Weekly_Friday_Distribution.ps1`

### Windows Batch Launchers

-   `run_enrollment_weekly.bat`
-   `format_enrollment_workbook.bat`
-   `run_aco_weekly_friday_distribution.bat`

### Python

-   `Enrollment_Weekly_Automation.py`

## 12. Production Schedule

  -----------------------------------------------------------------------
  Day                                 Process
  ----------------------------------- -----------------------------------
  Wednesday 9:00 AM ET                Linux cron starts SAS

  Wednesday                           SAS generates REGXSA and SASQA

  Wednesday                           Retry wrapper retries failed SAS
                                      runs up to 3 times

  Wednesday                           Windows process transfers and
                                      validates outputs

  Wednesday                           REGXSA workbook is formatted

  Wednesday                           QC Distribution Decision is
                                      evaluated

  Wednesday                           Approved report is published to
                                      OneDrive/SharePoint

  Thursday                            Report/QC can be reviewed if
                                      necessary

  Friday                              Distribution process rechecks QC

  Friday                              Outlook notification is sent only
                                      if QC = READY TO DISTRIBUTE
  -----------------------------------------------------------------------

## 13. Failure Protection

The final distribution should **not** occur when: - SAS fails. - SAS log
contains an `ERROR:`. - Required report files are missing. - Required
files are zero bytes. - Published report does not match the approved
report size. - QC Distribution Decision cannot be found. - QC says
`REVIEW BEFORE DISTRIBUTION`. - QC says `DO NOT DISTRIBUTE`. - An
Outlook recipient cannot be resolved. - Outlook submission fails.

The report is distributed only after all required checks succeed.

## 14. Useful Linux Verification Commands

Check the production cron schedule:

``` bash
crontab -l
```

Check whether the SAS report is currently running:

``` bash
ps -ef | grep Monthly_View
```

View the Linux retry script:

``` bash
cat /sas_mass_health/shared/tkray/Enrollment/Reports/run_aco_weekly_retry.sh
```

Review the retry/master log:

``` bash
tail -100 /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_Weekly_Master.log
```

Review cron output:

``` bash
tail -100 /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_Weekly_Cron.log
```

Find recent ACO run logs:

``` bash
ls -lt /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_Weekly_*.log
```

## 15. Production Design Principle

The automation intentionally separates:

``` text
REPORT CREATION
       ↓
QC
       ↓
PUBLISHING
       ↓
DISTRIBUTION
```

Generating a report does not automatically mean that the report is safe
to distribute.

The QC Distribution Decision is the control point between report
production and final distribution.

Only `READY TO DISTRIBUTE` permits automated Friday distribution.

## Current Production Baseline

As of August 19, 2026, the production baseline consists of:

-   `Monthly_View_Report_Automated_Production.sas`
-   `run_aco_weekly_retry.sh`
-   `Enrollment_Weekly_Automation.py`
-   `Run_ACO_Weekly_Full_Process.ps1`
-   `Format_Enrollment_Workbook.ps1`
-   `format_enrollment_workbook.bat`
-   `Send_ACO_Weekly_Friday_Distribution.ps1`
-   `run_aco_weekly_friday_distribution.bat`
-   `run_enrollment_weekly.bat`

These files should be preserved in GitHub as the production
recovery/reference copy whenever changes are made to the live
automation.

## Security

Do not store passwords, SAS passwords, Windows credentials, or other
authentication credentials in GitHub.
