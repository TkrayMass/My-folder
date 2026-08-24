
# Monthly Advocacy Report Automation

## Overview

The Monthly Advocacy Report is a SAS-based monthly reporting process used to produce Advocacy enrollment, eligibility, termination, caseload, adds, and reopen reports.

The original process required manual monthly date changes, manual execution of multiple SAS programs, and manual movement of the completed Excel reports to the shared Advocate Report folder.

The process is being converted to a dynamic and automated monthly workflow.

---

## Production Architecture

### SAS Linux Environment

Primary project location:

/sas_mass_health/shared/Advocacy_Dynamic

Project structure:

- Archive
- Code
- Data
- Documentation
- Include
- Logs
- Output
- QC

Shared project settings are maintained in:

00_Project_Settings.sas

The settings program dynamically determines the reporting month and related monthly date variables used throughout the process.

---

## Monthly Processing Flow

The Advocacy process consists of the monthly SAS processing chain, including Proc 0 through Proc 10.

The programs are designed so that downstream procedures use the outputs created by earlier procedures.

General processing sequence:

1. Determine monthly reporting dates
2. Build monthly eligibility/caseload data
3. Run the Advocacy processing procedures
4. Produce final report datasets
5. Export the final Excel reports
6. Perform QC
7. Create the monthly SUCCESS flag
8. Transfer completed reports to the Windows shared drive

The transfer process will not publish reports unless the monthly SUCCESS flag exists.

---

## Monthly SUCCESS Flag

After successful completion of the Advocacy master process, the following QC flag is expected:

/sas_mass_health/shared/Advocacy_Dynamic/QC/Advocacy_Master_YYYYMM_SUCCESS.flag

Example:

Advocacy_Master_202607_SUCCESS.flag

This flag is a safety control.

If the flag does not exist, the Windows transfer process stops and does not publish potentially incomplete or stale reports.

---

## Linux Output Location

Monthly Excel reports are created under:

/sas_mass_health/shared/Advocacy_Dynamic/Output/MM_YYYY

Example:

/sas_mass_health/shared/Advocacy_Dynamic/Output/07_2026

The Windows transfer process expects 9 final monthly report files.

---

## Windows Transfer Automation

The monthly transfer is performed by:

Advocacy_Monthly_Transfer.py

Windows launcher:

run_advocacy_monthly_transfer.bat

The transfer process:

1. Determines the prior reporting month dynamically.
2. Connects to the SAS Linux server using passwordless SSH.
3. Verifies the monthly SUCCESS flag.
4. Locates the monthly Advocacy output folder.
5. Verifies the expected final reports.
6. Downloads files to local staging.
7. Verifies downloaded file sizes.
8. Publishes the reports to the shared drive.
9. Verifies the published files.
10. Records processing information in the transfer log.

Local staging location:

C:\Users\TKray\Advocacy_Monthly_Staging\YYYYMM

Transfer log:

C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Advocacy_Monthly_Transfer.log

---

## SAS Linux Connection

The transfer script supports the SAS Linux host:

dph-pr-sgn-lap09

and the fully qualified hostname:

dph-pr-sgn-lap09.cs.govt.state.ma.us

The script retries the connection when temporary hostname or network resolution problems occur.

Passwordless SSH authentication is used.

---

## Final Shared-Drive Destination

Completed reports are published to:

\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget\Enrollments & Advocacy\Advocate report

The existing Advocate Report folder remains the production distribution location.

---

## Windows Task Scheduler

Task name:

Monthly Advocacy Transfer

Schedule:

First Wednesday of every month at 1:00 PM Eastern Time.

The task runs:

run_advocacy_monthly_transfer.bat

Important Task Scheduler settings:

- Run task as soon as possible after a scheduled start is missed
- Stop task if it runs longer than 1 hour
- Do not start a new instance if the task is already running
- No AC-power restriction
- No idle requirement

The monthly transfer is intentionally scheduled after the SAS monthly processing window so that completed reports can be verified before publication.

---

## Failure Protection

The transfer process is designed to fail safely.

Reports are NOT published when:

- the monthly SUCCESS flag is missing
- the SAS Linux host cannot be reached
- expected report files are missing
- downloaded files fail verification
- shared-drive publication fails verification

Temporary SSH/DNS failures are retried automatically.

Local staging is used so that large files are fully downloaded and verified before being copied to the shared drive.

---

## July 2026 Validation

July 2026 is the validation baseline for the dynamic conversion.

Validation reporting month:

202607

Report period:

July 1, 2026 through July 31, 2026

Dynamic results are compared with the verified July 2026 manually produced reports before the automated process is considered fully production validated.

---

## Monthly Snapshot Summary

In addition to the Proc 0–10 reporting chain, the Advocacy process includes a distributed monthly Snapshot summary report.

The Snapshot report is generated from the monthly eligibility snapshot and summarizes member counts by:

- YR_MTH
- CDE_BUDGET_GROUP

This report is part of the monthly Advocacy reporting deliverables.

---

## Current Automation Status

As of August 24, 2026:

- Dynamic Advocacy project structure established
- Dynamic monthly date architecture established
- Proc 0 dynamic conversion validated through July 2026
- Windows Advocacy transfer program created
- Passwordless SSH transfer verified
- Shared-drive destination configured
- Transfer safety check for monthly SUCCESS flag verified
- Windows Task Scheduler task created
- Monthly Advocacy Transfer scheduled for the first Wednesday at 1:00 PM
- Next production-cycle validation will occur with the next completed monthly Advocacy run

The transfer test correctly stopped when the July 2026 SUCCESS flag was not present, confirming that incomplete reports will not be published.
