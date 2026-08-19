
# ACO Weekly Enrollment Report Automation

## Overview

This repository contains the production automation for the **ACO Weekly Enrollment Report**.

The process automates the weekly enrollment report from data refresh through report generation, QC, formatting, publication, and email notification.

The production workflow uses:

* **Snowflake** for the enrollment data refresh
* **SAS on Linux** for report and QC workbook generation
* **Linux scheduling** for the weekly SAS execution
* **Python** for transferring generated files from Linux to Windows
* **PowerShell** for Windows-side orchestration, QC gating, formatting, publication, email notification, and cleanup
* **Windows Task Scheduler** for the Windows portion of the automated process
* **Outlook** for report distribution notification

---

## Production Workflow

The automated process follows this sequence:

**1. Snowflake Data Refresh**

The weekly enrollment data is refreshed in Snowflake using the production ACO enrollment refresh process.

**2. SAS Report Generation**

The production SAS program creates:

* Weekly enrollment report
* QC workbook
* Supporting QC results

The current production SAS baseline is based on the finalized automated weekly enrollment report code.

**3. Linux Execution**

The SAS process runs on the designated SAS Linux environment.

The working Linux host used by the automation must be verified because available SAS application hosts can change.

**4. File Transfer**

After SAS finishes, the Windows automation retrieves the generated files from the Linux SAS environment.

Python is used for the Linux-to-Windows transfer.

**5. QC Gate**

The automation evaluates the generated QC results before publication.

The QC workbook provides information needed to determine whether the weekly report is acceptable for distribution.

A report should not be distributed when the automated QC gate identifies a blocking failure.

**6. Excel Formatting**

The generated enrollment workbook is processed on Windows to improve usability and presentation.

Formatting includes appropriate worksheet formatting, sizing, wrapping, and workbook cleanup.

**7. Publication**

After the report passes the required QC checks, the finalized workbook is copied to the production enrollment-report location.

Production destination:

`Z:\Analytics\Rouba\Enrollment Report <M-D-YYYY>`

**8. Email Notification**

After successful publication, Outlook sends the weekly notification to the approved ACO Enrollment distribution list.

The email is sent only after the required processing and QC steps have completed successfully.

**9. Cleanup**

Temporary/intermediate report files are removed after successful completion when they are no longer required.

The final published workbook and required QC/audit information are retained.

---

## Main Production Components

### SAS

The production SAS program performs the weekly enrollment report generation and creates the associated QC output.

### Python

The Python transfer process retrieves the SAS-generated files from the Linux environment and places them in the Windows working location.

### PowerShell

The master PowerShell process controls the Windows-side workflow:

**Transfer → Wait/Validate → QC → Format → Publish → Email → Cleanup**

The master controller is the primary Windows orchestration script for the production process.

### Batch Files

Batch files are used as launchers so that Windows Task Scheduler can reliably start the required Python and PowerShell processes.

---

## Scheduling

The automation uses coordinated Linux and Windows scheduling.

The Linux process runs first to generate the SAS report.

The Windows process runs afterward and waits for/verifies the expected report output before continuing with transfer, QC, formatting, publication, and notification.

The schedules must leave sufficient time for the SAS report to finish before the downstream Windows processing begins.

---

## QC and Distribution Control

QC is a required part of the production workflow.

The automated process is designed so that report publication and distribution occur only after the required QC conditions have been evaluated.

QC information includes comparisons and validation measures intended to identify unexpected enrollment changes or processing problems.

A failed blocking QC condition should stop downstream publication/distribution and require investigation.

---

## Logging and Troubleshooting

The production automation maintains logs for troubleshooting and run verification.

Important Windows logs include:

`ACO_Weekly_Full_Process.log`

`ACO_Weekly_Transfer.log`

These logs should be reviewed when:

* A scheduled run does not complete
* The expected report is missing
* Linux-to-Windows transfer fails
* Excel formatting fails
* QC prevents publication
* Outlook notification is not sent

---

## Repository Organization

Recommended structure:

```text
Enrollment_report/
│
├── Code/
│   ├── SAS/
│   ├── Python/
│   ├── PowerShell/
│   └── Batch/
│
├── Documentation/
│
└── README.md
```

The repository should contain only the **current production code and current documentation** in the active folders.

Older development versions should be removed from the production folders or retained separately in an archive when historical reference is necessary.

---

## Production Change Control

When modifying the automation:

1. Preserve the current working production version before making significant changes.
2. Test changes before replacing production code.
3. Confirm SAS report generation.
4. Confirm Linux-to-Windows transfer.
5. Confirm QC results.
6. Confirm workbook formatting.
7. Confirm publication location.
8. Confirm email notification.
9. Confirm scheduled execution.
10. Update this README and the detailed production documentation when the architecture changes.

---

## Current Status

**Status:** Production automation implemented.

The workflow currently includes:

**Snowflake refresh → SAS report generation → Linux execution → Windows transfer → QC gate → Excel formatting → publication → Outlook notification → cleanup**

This README should be maintained as the high-level description of the production process. Detailed commands, configuration, troubleshooting procedures, and complete production code are maintained in the accompanying implementation documentation and repository code folders.
