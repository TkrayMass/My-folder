
# Monthly Caseload Automation

## Production Quick Reference & Detailed End-to-End Process

**Snowflake Task • Snowflake Stored Procedures • Windows Task Scheduler • Python • Excel • Shared Budget Folder • Outlook**

**Purpose:** Automate the monthly Caseload report from the Snowflake historical rebuild through Excel export, publication to the shared Budget folder, and monthly distribution notification.

**Production design:** The Caseload process does **not** append only the newest month to a separate historical table. Each monthly production run rebuilds the complete historical Caseload period month-by-month, beginning with July 2006 and ending with the most recently completed month. This makes the resulting `CASELOAD_MEMBER_DAYS` table a complete rebuilt history for the current run.

---

# 1. End-to-End Production Flow

| Step | System / App | Code / Process | What Happens |
|---|---|---|---|
| 1 | Snowflake Task | `CASELOAD_MONTHLY_REFRESH_TASK` | Runs on the scheduled Tuesday cadence and calls the scheduling wrapper. |
| 2 | Snowflake | `CASELOAD_MONTHLY_SCHEDULED_RUN()` | Determines whether the current Tuesday is the first Tuesday of the month. If not, the run is skipped. If yes, it calls the production Caseload rebuild procedure. |
| 3 | Snowflake | `CASELOAD_MONTHLY_DB3()` | Rebuilds the complete Caseload member-day history month-by-month from July 2006 through the prior completed month. |
| 4 | Snowflake | `CASELOAD_MEMBER_DAYS` | Receives the rebuilt historical monthly Caseload results used for reporting/export. |
| 5 | QC / Validation | Procedure return values and table checks | Confirms the rebuilt period, number of months processed, row counts, and member-day totals before downstream distribution. |
| 6 | Windows Task Scheduler | Caseload monthly export task | Starts the Windows-side export after the Snowflake monthly refresh window. |
| 7 | Windows batch | `run_caseload_export.bat` | Launches the Python export program and provides a schedulable Windows entry point. |
| 8 | Python | `caseload_monthly_export.py` | Reads the refreshed Caseload table, creates the monthly Excel workbook, and saves/copies the report to the production Budget location. |
| 9 | Shared drive | Budget folder | Stores the production Caseload Excel report for business use. |
| 10 | Monthly email process | `monthly_email.py` | Sends the monthly Snapshot and Caseload report notification to the established recipients after the reporting files are available. |

---

# 2. Detailed Production Process

## Step 1 - Snowflake Task Starts the Monthly Caseload Process

**System:** Snowflake  
**Task:** `CASELOAD_MONTHLY_REFRESH_TASK`

The Snowflake task is the scheduler for the database portion of the monthly Caseload process.

The production schedule is:

```sql
CRON 0 10 * * TUE America/New_York
```

This means the task is eligible to run every Tuesday at 10:00 AM Eastern Time.

The task itself does not assume that every Tuesday should produce a monthly Caseload rebuild. Instead, it calls the wrapper procedure `CASELOAD_MONTHLY_SCHEDULED_RUN()`, which contains the first-Tuesday business rule.

This design separates:

- **Scheduling:** Snowflake Task
- **Calendar/business rule:** scheduling wrapper
- **Caseload calculation:** production rebuild procedure

---

## Step 2 - Scheduling Wrapper Enforces the First-Tuesday Rule

**Procedure:** `CASELOAD_MONTHLY_SCHEDULED_RUN()`

The wrapper protects the expensive historical Caseload rebuild from running every Tuesday.

Its responsibility is to determine whether the current execution date is the **first Tuesday of the month**.

Conceptually:

```text
CASELOAD_MONTHLY_REFRESH_TASK
        |
        v
CASELOAD_MONTHLY_SCHEDULED_RUN()
        |
        +-- Not first Tuesday --> SKIPPED
        |
        +-- First Tuesday -----> CASELOAD_MONTHLY_DB3()
```

A non-first-Tuesday task execution should therefore be interpreted as a normal scheduled check rather than a failed monthly refresh.

When the date qualifies as the first Tuesday, the wrapper calls the production rebuild procedure.

---

## Step 3 - `CASELOAD_MONTHLY_DB3()` Rebuilds the Complete History

**Primary procedure:** `CASELOAD_MONTHLY_DB3()`

This procedure performs the actual monthly Caseload calculation.

The key architectural principle is:

> **Every monthly run rebuilds the full historical reporting period. It does not merely append the newest month.**

The production history begins with:

```text
START_MONTH = 2006-07-01
```

The procedure determines the current run boundary using the first day of the current month as the as-of date.

For example, for an August 2026 production run:

```text
ASOFDT    = 2026-08-01
TRUE_END  = 2026-07-31
```

Therefore, July 2026 is the latest completed month eligible for the rebuild.

The procedure prevents the requested end period from extending beyond `TRUE_END`.

### Monthly rebuild logic

The procedure iterates through the reporting period one month at a time:

```text
July 2006
August 2006
September 2006
...
June 2026
July 2026
```

For every month, it applies the Caseload eligibility/member-day logic and adds that month's results to the rebuilt output.

At completion, the output represents the entire supported Caseload history for that production run.

---

# 3. Why the Caseload Process Rebuilds History

The Caseload architecture intentionally differs from a simple monthly append process.

A monthly append design would operate like:

```text
Historical table
      +
Newest month
      =
Updated historical table
```

The Caseload process instead operates like:

```text
Source eligibility/history data
        |
        v
Recalculate July 2006
        |
        v
Recalculate August 2006
        |
        v
...
        |
        v
Recalculate latest completed month
        |
        v
Complete CASELOAD_MEMBER_DAYS rebuild
```

This approach produces a complete internally consistent result based on the source data available at the time of the run.

It also means that the runtime is materially longer than a one-month append process and that a successful run should be validated as a **complete rebuild**, not simply by checking whether the latest month exists.

---

# 4. Production Output Table

**Snowflake output:** `CASELOAD_MEMBER_DAYS`

This table contains the complete rebuilt monthly Caseload/member-day reporting history produced by `CASELOAD_MONTHLY_DB3()`.

A successful production run should be checked for:

- Expected first reporting month
- Expected latest completed reporting month
- Expected number of months processed
- Non-zero row count
- Non-zero total member days
- Successful procedure completion

For the August 2026 validation run, the completed rebuild returned:

| QC Measure | Validated Result |
|---|---:|
| First YR_MTH | 200607 |
| Last YR_MTH | 202607 |
| Months processed | 241 |
| Rows | 20,889 |
| Total member days | 15,439,002,289 |
| Approximate runtime | 17 minutes |

These values are a historical validation reference, **not permanent fixed thresholds**. Future monthly runs should naturally contain a later `LAST_YR_MTH`, an additional month processed, and potentially different row/member-day totals.

---

# 5. Monthly Date Logic

The Caseload process is designed so the report only includes completed months.

For a run occurring during August 2026:

```text
Current run month: August 2026
ASOFDT:            2026-08-01
TRUE_END:          2026-07-31
Latest YR_MTH:     202607
```

For a September 2026 run, the expected latest month becomes August 2026:

```text
ASOFDT:            2026-09-01
TRUE_END:          2026-08-31
Latest YR_MTH:     202608
```

No manual date edit should be required for the normal monthly production run.

---

# 6. QC and Validation

A successful procedure call should not be treated as the only QC condition.

At minimum, validate the following:

| QC Check | Expected Behavior |
|---|---|
| Procedure status | SUCCESS |
| First month | Remains `200607` unless production requirements change |
| Latest month | Equals the month immediately preceding the current run month |
| Months processed | Increases as new completed months are added |
| Row count | Greater than zero and reasonable relative to prior run |
| Total member days | Greater than zero and reasonable relative to prior run |
| Output table | `CASELOAD_MEMBER_DAYS` exists and is populated |
| Export | Current monthly Excel workbook exists and is non-zero |

Unexpected changes in the historical starting month, missing recent months, zero rows, or an unexpectedly short runtime should be investigated before relying on the exported report.

---

# 7. Windows Task Scheduler Starts the Export

After the Snowflake processing window, Windows Task Scheduler starts the downstream Caseload export process.

The Windows task does not calculate Caseload. Its responsibility is to launch the local export workflow after Snowflake has had sufficient time to complete the rebuild.

The Windows-side sequence is:

```text
Windows Task Scheduler
        |
        v
run_caseload_export.bat
        |
        v
caseload_monthly_export.py
```

Because the Snowflake rebuild can take approximately 17 minutes based on production validation, the Windows task should be scheduled with enough separation from the Snowflake start time to avoid attempting to export a table that is still being rebuilt.

---

# 8. Batch Wrapper - `run_caseload_export.bat`

The batch file provides the Windows Task Scheduler entry point for the Python export.

Its responsibilities are to:

- Start the Caseload Python export
- Use the correct Python environment/path
- Allow the export to run unattended
- Produce/retain execution information through the established logging process
- Return an execution status that can be investigated when the scheduled process fails

The related Caseload export log is:

```text
Caseload_Monthly_Export.log
```

When the Excel report is missing, this log and the Windows Task Scheduler history are the first Windows-side places to inspect.

---

# 9. Python Export - `caseload_monthly_export.py`

**Program:** `caseload_monthly_export.py`

The Python program handles the report-export portion of the automation.

Its production role is to take the refreshed Snowflake Caseload result and create the monthly Excel deliverable.

The report naming convention is based on the most recently completed month-end. A validated example is:

```text
Caseload_Member_Days_20260731.xlsx
```

The date in the filename represents the month-end corresponding to the latest completed reporting month.

The Python process was initially tested using a personal working location and then configured for the production shared Budget location.

---

# 10. Production Shared Budget Folder

The final production Caseload workbook is copied/saved to the established Budget shared folder:

```text
\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget
```

This is the production distribution/storage location for the monthly report.

During development/testing, the personal working location used was:

```text
Z:\Analytics\Tanya\Snapshot
```

The personal location is not the intended final production publication location.

---

# 11. Monthly Email Notification

The Caseload report is included in the monthly report email process together with the Snapshot report.

**Program:** `monthly_email.py`

The established subject format is:

```text
<Month YYYY> Snapshot and Caseload Reports
```

The established recipients are:

```text
Tatyana.Kray@mass.gov
Marissa.Jones@mass.gov
Julia.Paolino@mass.gov
```

The email process is scheduled after the report-generation/export process so recipients are notified only after the expected monthly files should be available.

The email automation should be treated as a downstream notification step. If an email is not received, first determine whether the Caseload workbook itself was successfully created and copied to the Budget folder.

---

# 12. Production Architecture at a Glance

```text
SNOWFLAKE
============================================================

CASELOAD_MONTHLY_REFRESH_TASK
    |
    | Scheduled Tuesday execution
    v
CASELOAD_MONTHLY_SCHEDULED_RUN()
    |
    +-- Is this the first Tuesday?
            |
            +-- NO --> SKIPPED
            |
            +-- YES
                 |
                 v
          CASELOAD_MONTHLY_DB3()
                 |
                 | Rebuild full historical period
                 | July 2006 -> prior completed month
                 v
          CASELOAD_MEMBER_DAYS
                 |
                 v
          QC / VALIDATION


WINDOWS
============================================================

WINDOWS TASK SCHEDULER
        |
        v
run_caseload_export.bat
        |
        v
caseload_monthly_export.py
        |
        v
Caseload_Member_Days_YYYYMMDD.xlsx
        |
        v
SHARED BUDGET FOLDER
        |
        v
monthly_email.py
        |
        v
MONTHLY REPORT NOTIFICATION
```

---

# 13. Production Objects and Files

| Type | Production Object / File | Purpose |
|---|---|---|
| Snowflake procedure | `CASELOAD_MONTHLY_DB3()` | Rebuilds the complete historical Caseload/member-day dataset |
| Snowflake wrapper | `CASELOAD_MONTHLY_SCHEDULED_RUN()` | Enforces first-Tuesday monthly execution |
| Snowflake task | `CASELOAD_MONTHLY_REFRESH_TASK` | Provides the Snowflake Tuesday schedule |
| Snowflake output | `CASELOAD_MEMBER_DAYS` | Complete rebuilt Caseload history |
| Windows batch | `run_caseload_export.bat` | Launches the Python export |
| Python | `caseload_monthly_export.py` | Creates the monthly Excel workbook and publishes it |
| Export log | `Caseload_Monthly_Export.log` | Windows/Python export troubleshooting |
| Email Python | `monthly_email.py` | Sends the monthly Snapshot/Caseload notification |
| Excel output | `Caseload_Member_Days_YYYYMMDD.xlsx` | Monthly Caseload deliverable |

---

# 14. Key Production Locations

| Location | Path / Name |
|---|---|
| Production Budget folder | `\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget` |
| Development/test output location | `Z:\Analytics\Tanya\Snapshot` |
| Caseload export log | `Caseload_Monthly_Export.log` |
| Production Snowflake schema | `MHTEAM.MHA` |
| Snowflake warehouse | `MHA_WH` |

---

# 15. Expected Monthly Result

For a normal successful monthly cycle:

1. The Snowflake task reaches the first Tuesday.
2. The wrapper recognizes that the run is eligible.
3. `CASELOAD_MONTHLY_DB3()` rebuilds the complete history.
4. `CASELOAD_MEMBER_DAYS` contains July 2006 through the prior completed month.
5. QC confirms the expected period and reasonable totals.
6. Windows Task Scheduler starts the export.
7. Python creates `Caseload_Member_Days_YYYYMMDD.xlsx`.
8. The workbook is copied/saved to the shared Budget folder.
9. The monthly email process notifies the report recipients.

---

# 16. Troubleshooting - Where to Start

| Symptom | First Place to Check |
|---|---|
| Monthly rebuild did not occur | Check `CASELOAD_MONTHLY_REFRESH_TASK` task history and confirm the execution date was the first Tuesday |
| Task ran but reported SKIPPED | Verify whether the date was actually the first Tuesday; SKIPPED is expected on other Tuesdays |
| Wrapper ran but Caseload failed | Review the result/error from `CASELOAD_MONTHLY_SCHEDULED_RUN()` and `CASELOAD_MONTHLY_DB3()` |
| Latest month is missing | Verify `ASOFDT`, `TRUE_END`, and the procedure's effective end-month logic |
| Historical period starts later than 200607 | Stop and investigate the rebuild logic/source data before export |
| Row count or member days are zero/unreasonable | Investigate Snowflake source logic and monthly processing before distributing |
| Snowflake succeeded but Excel is missing | Check Windows Task Scheduler, `run_caseload_export.bat`, and `Caseload_Monthly_Export.log` |
| Excel exists locally but not in Budget folder | Check shared-drive/network access and the copy/save portion of `caseload_monthly_export.py` |
| Report exists but email did not arrive | Check `monthly_email.py`, its scheduled task/log, Outlook availability, and recipient configuration |
| Need to isolate the failing layer | Test in order: Snowflake task -> wrapper -> DB3 -> output table -> Windows task -> batch -> Python -> shared folder -> email |

---

# 17. Manual Recovery Procedure

If the automated monthly process fails, recovery should follow the same production order rather than rerunning unrelated downstream steps.

## A. Verify Snowflake first

Confirm whether `CASELOAD_MEMBER_DAYS` was successfully rebuilt through the expected latest month.

If the rebuild did not complete, manually execute the approved Caseload production procedure/wrapper according to production permissions and validate the returned QC information.

Do **not** start the Excel export while the Snowflake rebuild is incomplete.

## B. Validate the rebuilt table

Confirm:

```text
FIRST_YR_MTH
LAST_YR_MTH
MONTHS_PROCESSED
ROWS
TOTAL_MEM_DAYS
```

The latest month must correspond to the prior completed month.

## C. Rerun only the Windows export if Snowflake is already correct

If Snowflake completed successfully but the Excel file was not produced, rerun the established Windows Caseload export rather than rebuilding Snowflake unnecessarily.

## D. Verify the Budget-folder copy

Confirm the final `Caseload_Member_Days_YYYYMMDD.xlsx` file exists in the production Budget folder and is non-zero.

## E. Rerun notification only if necessary

If the report exists correctly but recipients were not notified, troubleshoot/rerun the email step without rebuilding the report.

This layered recovery approach avoids unnecessary full historical rebuilds when only a downstream Windows or email step failed.

---

# 18. Production Ownership / Key Principles

**Snowflake Task responsibility:** Start the scheduled monthly database workflow.

**Scheduling-wrapper responsibility:** Enforce the first-Tuesday rule and prevent unnecessary weekly historical rebuilds.

**`CASELOAD_MONTHLY_DB3()` responsibility:** Rebuild the complete Caseload history from July 2006 through the latest completed month.

**`CASELOAD_MEMBER_DAYS` responsibility:** Serve as the complete rebuilt monthly Caseload/member-day output used by downstream reporting.

**Windows responsibility:** Start the export after the Snowflake processing window.

**Python responsibility:** Export the refreshed Caseload data to Excel and place the production workbook in the shared Budget location.

**Email responsibility:** Notify the established recipients after the monthly reporting files are available.

**Core production principle:** A successful monthly Caseload process is not merely the creation of the newest month. It is the successful rebuild and validation of the **entire supported historical period** followed by a successful Excel export and publication.

---

# 19. Monthly Operations Checklist

- [ ] Confirm the scheduled date is the first Tuesday of the month.
- [ ] Confirm `CASELOAD_MONTHLY_REFRESH_TASK` executed.
- [ ] Confirm `CASELOAD_MONTHLY_SCHEDULED_RUN()` called the rebuild rather than returning an unexpected skip.
- [ ] Confirm `CASELOAD_MONTHLY_DB3()` returned SUCCESS.
- [ ] Confirm `FIRST_YR_MTH = 200607`.
- [ ] Confirm `LAST_YR_MTH` equals the prior completed month.
- [ ] Confirm the expected number of months was processed.
- [ ] Confirm row count and total member days are non-zero and reasonable.
- [ ] Confirm `CASELOAD_MEMBER_DAYS` is populated.
- [ ] Confirm Windows Task Scheduler ran the Caseload export.
- [ ] Confirm `Caseload_Member_Days_YYYYMMDD.xlsx` was created.
- [ ] Confirm the Excel file exists in the production Budget folder.
- [ ] Confirm the monthly Snapshot/Caseload email notification was sent/received.
- [ ] If any stage failed, restart only from the earliest failed layer.

---

# 20. Notes for GitHub Maintenance

This README documents the production architecture and operating sequence. When production code or scheduling changes, update this document at the same time.

Items that should always remain synchronized with production include:

- Stored procedure names
- Wrapper procedure name
- Snowflake task name and schedule
- Historical start month
- Output table name
- Windows task/batch names
- Python export filename
- Production folder
- Email process and recipients
- QC/recovery instructions

For security and maintainability, credentials, passwords, tokens, or other secrets should **never** be committed to GitHub.

Where full production SQL, Python, or batch source code is maintained in the repository, keep the executable files as separate repository files and use this README as the operational guide explaining how those components work together.




SNAPSHOT



# Monthly Snapshot Automation

## Production Quick Reference & Detailed End-to-End Process

**Snowflake Task • Snowflake Stored Procedures • Windows Task Scheduler • Python • Excel • Shared Budget Folder • Outlook**

**Purpose:** Automate the monthly eligibility Snapshot report from Snowflake snapshot creation and QC through historical-table refresh, Excel export, publication to the shared Budget folder, and monthly distribution notification.

**Production design:** Unlike the Caseload process, which rebuilds its full historical period each month, the Snapshot process creates the applicable monthly eligibility snapshot and updates the Snapshot history used for reporting. The Snowflake procedure performs the data creation and QC before the downstream Windows export begins.

---

# 1. End-to-End Production Flow

| Step | System / App | Code / Process | What Happens |
|---|---|---|---|
| 1 | Snowflake Task | `SNAPSHOT_MONTHLY_TASK` | Runs on the scheduled Tuesday cadence and calls the first-Tuesday wrapper. |
| 2 | Snowflake | `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` | Determines whether the current execution date is the first Tuesday of the month. If not, the monthly refresh is skipped. |
| 3 | Snowflake | `SNAPSHOT_MONTHLY_DYNAMIC()` | Creates the applicable monthly eligibility snapshot, performs QC, and updates the Snapshot eligibility history. |
| 4 | Snowflake | `SNAPSHOT_ELIGENR_HISTORY` | Stores the historical Snapshot results used for the monthly export. |
| 5 | QC / Validation | Procedure return values and history checks | Confirms successful processing, row counts, and the expected first/latest reporting months. |
| 6 | Windows Task Scheduler | Snapshot monthly export task | Starts the downstream Windows export after the Snowflake processing window. |
| 7 | Windows batch | `run_snapshot_export.bat` | Launches the Python Snapshot export. |
| 8 | Python | Snapshot monthly export program | Exports the refreshed Snapshot history to Excel and saves/copies the production workbook to the Budget shared folder. |
| 9 | Shared drive | Budget folder | Stores the production Snapshot workbook for business use. |
| 10 | Monthly email process | `monthly_email.py` | Sends the combined Snapshot and Caseload monthly notification after the reports are available. |

---

# 2. Detailed Production Process

## Step 1 - Snowflake Task Starts the Monthly Snapshot Process

**System:** Snowflake  
**Task:** `SNAPSHOT_MONTHLY_TASK`

The Snowflake task provides the automated schedule for the database portion of the monthly Snapshot process.

The production schedule is:

```sql
CRON 0 10 * * TUE America/New_York
```

The task is therefore eligible to execute every Tuesday at 10:00 AM Eastern Time.

The task calls `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` rather than directly calling the main Snapshot procedure. This allows the scheduling layer and the first-Tuesday business rule to remain separate from the actual Snapshot processing logic.

Conceptually:

```text
SNAPSHOT_MONTHLY_TASK
        |
        v
SNAPSHOT_MONTHLY_FIRST_TUESDAY()
        |
        +-- Not first Tuesday --> SKIPPED
        |
        +-- First Tuesday -----> SNAPSHOT_MONTHLY_DYNAMIC()
```

---

## Step 2 - First-Tuesday Wrapper Controls Monthly Execution

**Procedure:** `SNAPSHOT_MONTHLY_FIRST_TUESDAY()`

The wrapper determines whether the current task execution falls on the first Tuesday of the month.

If the date is not the first Tuesday, the monthly processing is skipped.

If the date is the first Tuesday, the wrapper calls:

```text
SNAPSHOT_MONTHLY_DYNAMIC()
```

This prevents the Snapshot refresh from being repeated on every Tuesday even though the Snowflake task itself uses a weekly Tuesday schedule.

A `SKIPPED` result on a later Tuesday is therefore expected behavior rather than a production failure.

---

# 3. `SNAPSHOT_MONTHLY_DYNAMIC()` - Main Production Procedure

**Primary procedure:** `MHTEAM.MHA.SNAPSHOT_MONTHLY_DYNAMIC()`

This is the main Snowflake procedure for the monthly Snapshot process.

Its production responsibilities are to:

- Determine the applicable monthly Snapshot date
- Create the monthly eligibility Snapshot
- Apply the established eligibility/Snapshot logic
- Perform Snapshot QC
- Update the historical Snapshot reporting table
- Return a production status/result for validation

The procedure is the core data-processing component of the Snapshot automation.

A successful task execution alone is not sufficient evidence that the monthly report is complete. The procedure result and refreshed history should also be validated before relying on the downstream Excel export.

---

# 4. Snapshot Date Logic

The Snapshot process uses dynamic dates so the analyst does not need to manually change the reporting month for each production cycle.

For an August 2026 production cycle, the applicable completed reporting month is July 2026.

The validated August run therefore produced a latest reporting month of:

```text
202607
```

and an Excel file based on the July 31, 2026 month-end:

```text
Snapshot_eligenr_20260731disabfix_v1.xlsx
```

As the process advances to later months, the reporting period and exported filename advance automatically according to the production date logic.

---

# 5. Snapshot Historical Table

**Historical output:** `SNAPSHOT_ELIGENR_HISTORY`

The Snapshot procedure updates the historical Snapshot table used by the downstream reporting/export process.

This is an important architectural difference from Caseload.

### Snapshot

```text
Current monthly eligibility Snapshot
        |
        v
QC
        |
        v
Update Snapshot history
        |
        v
SNAPSHOT_ELIGENR_HISTORY
```

### Caseload

```text
Historical source data
        |
        v
Rebuild every month from July 2006
        |
        v
CASELOAD_MEMBER_DAYS
```

Therefore:

> **Snapshot maintains/updates its historical reporting result, while Caseload performs a complete multi-year rebuild during each monthly production run.**

This distinction is important when troubleshooting and deciding whether a full rerun is required.

---

# 6. QC and Validation

The Snowflake Snapshot procedure includes QC as part of the monthly processing.

A successful monthly run should be validated for:

| QC Check | Expected Behavior |
|---|---|
| Procedure status | SUCCESS |
| Snapshot creation | Current applicable monthly Snapshot created successfully |
| QC result | No production-blocking error returned |
| Historical update | `SNAPSHOT_ELIGENR_HISTORY` updated successfully |
| First reporting month | Remains consistent with the established Snapshot history |
| Latest reporting month | Equals the expected latest completed month |
| Row count | Non-zero and reasonable |
| Excel export | Current Snapshot workbook exists and is non-zero |

For the validated August 2026 production run, the result included:

| QC Measure | Validated Result |
|---|---:|
| Status | SUCCESS |
| Rows | 15,350 |
| First month | 201207 |
| Latest month | 202607 |
| Export month-end | 2026-07-31 |

These values are a historical validation reference. Future monthly runs should naturally advance the latest reporting month and may have different row counts.

---

# 7. Windows Task Scheduler Starts the Snapshot Export

After the Snowflake Snapshot refresh window, Windows Task Scheduler starts the downstream export.

The Windows process does not calculate Snapshot eligibility. It exports the Snowflake results that have already been created and QC'd.

The Windows-side flow is:

```text
Windows Task Scheduler
        |
        v
run_snapshot_export.bat
        |
        v
Snapshot Python export
```

The Windows task should run after sufficient time has been allowed for the Snowflake process to complete.

---

# 8. Batch Wrapper - `run_snapshot_export.bat`

**Batch file:** `run_snapshot_export.bat`

This file provides a simple Windows Task Scheduler entry point for the Snapshot Python export.

Its role is to:

- Start the Python export automatically
- Use the established Python environment/path
- Support unattended execution
- Allow Windows Task Scheduler to run the process consistently
- Support troubleshooting through the related export log

The established Snapshot export log is:

```text
Snapshot_Monthly_Export.log
```

If Snowflake succeeded but the Excel workbook was not created, check the Windows scheduled task, this batch wrapper, and the export log.

---

# 9. Python Snapshot Export

The Python export reads the refreshed Snapshot history and creates the monthly Excel deliverable.

A validated output example is:

```text
Snapshot_eligenr_20260731disabfix_v1.xlsx
```

During development, the personal Snapshot folder was used as the temporary output location:

```text
Z:\Analytics\Tanya\Snapshot
```

For production, the report is saved/copied to the shared Budget folder.

The Python layer is a downstream reporting step. It should not be used to compensate for an incomplete or failed Snowflake Snapshot refresh.

---

# 10. Production Shared Budget Folder

The final production Snapshot workbook is placed in the established Budget shared folder:

```text
\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget
```

This is the shared production location used for the monthly Snapshot and Caseload reporting deliverables.

The personal folder:

```text
Z:\Analytics\Tanya\Snapshot
```

was used during development/testing and should not be treated as the final production publication location.

---

# 11. Monthly Email Notification

Snapshot and Caseload are included in the same monthly distribution notification.

**Program:** `monthly_email.py`

The established subject format is:

```text
<Month YYYY> Snapshot and Caseload Reports
```

The established recipients are:

```text
Tatyana.Kray@mass.gov
Marissa.Jones@mass.gov
Julia.Paolino@mass.gov
```

The email process is downstream of the report creation/export process.

If the notification is missing, verify the report files first. A missing email does not necessarily indicate that the Snowflake Snapshot process failed.

---

# 12. Production Architecture at a Glance

```text
SNOWFLAKE
============================================================

SNAPSHOT_MONTHLY_TASK
    |
    | Scheduled Tuesday execution
    v
SNAPSHOT_MONTHLY_FIRST_TUESDAY()
    |
    +-- Is this the first Tuesday?
            |
            +-- NO --> SKIPPED
            |
            +-- YES
                 |
                 v
          SNAPSHOT_MONTHLY_DYNAMIC()
                 |
                 +-- Create monthly eligibility Snapshot
                 |
                 +-- Perform QC
                 |
                 +-- Update Snapshot history
                 |
                 v
          SNAPSHOT_ELIGENR_HISTORY
                 |
                 v
          QC / VALIDATION


WINDOWS
============================================================

WINDOWS TASK SCHEDULER
        |
        v
run_snapshot_export.bat
        |
        v
SNAPSHOT PYTHON EXPORT
        |
        v
Snapshot_eligenr_YYYYMMDD....xlsx
        |
        v
SHARED BUDGET FOLDER
        |
        v
monthly_email.py
        |
        v
MONTHLY SNAPSHOT + CASELOAD NOTIFICATION
```

---

# 13. Production Objects and Files

| Type | Production Object / File | Purpose |
|---|---|---|
| Snowflake procedure | `SNAPSHOT_MONTHLY_DYNAMIC()` | Creates the monthly Snapshot, performs QC, and updates Snapshot history |
| Snowflake wrapper | `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` | Enforces first-Tuesday monthly execution |
| Snowflake task | `SNAPSHOT_MONTHLY_TASK` | Provides the automated Tuesday Snowflake schedule |
| Snowflake history | `SNAPSHOT_ELIGENR_HISTORY` | Historical Snapshot reporting data used for export |
| Windows batch | `run_snapshot_export.bat` | Launches the Snapshot Python export |
| Export log | `Snapshot_Monthly_Export.log` | Troubleshooting log for the Windows/Python export |
| Email Python | `monthly_email.py` | Sends the combined monthly Snapshot/Caseload notification |
| Excel output | `Snapshot_eligenr_YYYYMMDD....xlsx` | Monthly Snapshot Excel deliverable |

---

# 14. Key Production Locations

| Location | Path / Name |
|---|---|
| Production Budget folder | `\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget` |
| Development/test Snapshot location | `Z:\Analytics\Tanya\Snapshot` |
| Snapshot export log | `Snapshot_Monthly_Export.log` |
| Production Snowflake schema | `MHTEAM.MHA` |
| Snowflake warehouse | `MHA_WH` |

---

# 15. Expected Monthly Result

For a normal successful monthly Snapshot cycle:

1. `SNAPSHOT_MONTHLY_TASK` executes on Tuesday.
2. `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` confirms that the date is the first Tuesday.
3. `SNAPSHOT_MONTHLY_DYNAMIC()` creates the applicable monthly eligibility Snapshot.
4. Snapshot QC completes successfully.
5. `SNAPSHOT_ELIGENR_HISTORY` is updated.
6. QC confirms the expected latest reporting month and reasonable row count.
7. Windows Task Scheduler starts the Snapshot export.
8. Python creates the monthly Snapshot Excel workbook.
9. The workbook is saved/copied to the shared Budget folder.
10. The monthly email process notifies the established Snapshot/Caseload recipients.

---

# 16. Troubleshooting - Where to Start

| Symptom | First Place to Check |
|---|---|
| Snapshot refresh did not occur | Check `SNAPSHOT_MONTHLY_TASK` history and confirm the date was the first Tuesday |
| Task executed but processing was skipped | Verify whether the date was actually the first Tuesday; a later-Tuesday skip is expected |
| Wrapper ran but Snapshot failed | Review the result/error from `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` and `SNAPSHOT_MONTHLY_DYNAMIC()` |
| Latest month is missing | Check the dynamic Snapshot/reporting-date logic |
| History was not updated | Check the historical-table update portion of `SNAPSHOT_MONTHLY_DYNAMIC()` |
| Row count is zero/unreasonable | Investigate the Snowflake Snapshot eligibility logic before export |
| Snowflake succeeded but Excel is missing | Check Windows Task Scheduler, `run_snapshot_export.bat`, and `Snapshot_Monthly_Export.log` |
| Excel exists in test folder but not Budget | Check network/shared-folder access and the production copy/save step |
| Snapshot and Caseload files exist but no email arrived | Check `monthly_email.py`, its Windows schedule/log, Outlook availability, and recipient configuration |
| Need to isolate the failing layer | Test in order: Snowflake task -> wrapper -> Snapshot procedure -> history -> Windows task -> batch -> Python -> Budget folder -> email |

---

# 17. Manual Recovery Procedure

If the automated monthly Snapshot process fails, recover from the earliest failed layer.

## A. Verify Snowflake first

Confirm whether the monthly Snapshot was successfully created and whether `SNAPSHOT_ELIGENR_HISTORY` contains the expected latest reporting month.

If Snowflake did not complete successfully, correct/rerun the approved Snowflake production process before attempting the Excel export.

## B. Validate the Snapshot result

Confirm:

```text
Procedure status
Snapshot row count
First reporting month
Latest reporting month
Historical table update
```

The latest month should correspond to the applicable completed reporting month.

## C. Rerun only the Windows export when Snowflake is already correct

If the Snapshot table/history is correct but the Excel workbook was not created, rerun the established Windows Snapshot export rather than unnecessarily rerunning Snowflake.

## D. Verify the Budget-folder copy

Confirm that the final Snapshot workbook exists in:

```text
\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St\File Services\Adhoc\JF\Budget
```

and that the file is non-zero and opens successfully.

## E. Rerun notification only when necessary

If both Snapshot and Caseload reports exist correctly but the email was not received, troubleshoot the email process independently.

Do not rerun Snowflake simply because the notification step failed.

---

# 18. Production Ownership / Key Principles

**Snowflake Task responsibility:** Start the scheduled Snapshot database workflow.

**First-Tuesday wrapper responsibility:** Ensure the production Snapshot refresh occurs only for the intended monthly cycle.

**`SNAPSHOT_MONTHLY_DYNAMIC()` responsibility:** Create the monthly eligibility Snapshot, perform QC, and update the historical Snapshot reporting data.

**`SNAPSHOT_ELIGENR_HISTORY` responsibility:** Maintain the historical Snapshot results used by downstream reporting.

**Windows responsibility:** Start the export after Snowflake processing.

**Python responsibility:** Export the refreshed Snapshot history to Excel and place the production workbook in the shared Budget location.

**Email responsibility:** Notify the established recipients after the Snapshot and Caseload reports are available.

**Core production principle:** Snapshot creation, QC, historical update, Excel export, publication, and notification are separate layers. A downstream failure does not automatically require rerunning the upstream Snowflake process.

---

# 19. Monthly Operations Checklist

- [ ] Confirm the scheduled date is the first Tuesday of the month.
- [ ] Confirm `SNAPSHOT_MONTHLY_TASK` executed.
- [ ] Confirm `SNAPSHOT_MONTHLY_FIRST_TUESDAY()` called the main procedure rather than returning an unexpected skip.
- [ ] Confirm `SNAPSHOT_MONTHLY_DYNAMIC()` returned SUCCESS.
- [ ] Confirm the monthly Snapshot row count is non-zero and reasonable.
- [ ] Confirm the expected first reporting month remains present.
- [ ] Confirm the latest reporting month equals the expected completed month.
- [ ] Confirm `SNAPSHOT_ELIGENR_HISTORY` was updated.
- [ ] Confirm Windows Task Scheduler ran the Snapshot export.
- [ ] Confirm the monthly Snapshot Excel workbook was created.
- [ ] Confirm the workbook exists in the production Budget folder.
- [ ] Confirm the monthly Snapshot/Caseload notification was sent/received.
- [ ] If any stage failed, restart only from the earliest failed layer.

---

# 20. Snapshot and Caseload Relationship

Snapshot and Caseload are related monthly Budget reporting processes and share the downstream publication/notification environment, but their Snowflake processing designs are different.

| Feature | Snapshot | Caseload |
|---|---|---|
| Monthly scheduler | First-Tuesday controlled | First-Tuesday controlled |
| Main procedure | `SNAPSHOT_MONTHLY_DYNAMIC()` | `CASELOAD_MONTHLY_DB3()` |
| Primary output | `SNAPSHOT_ELIGENR_HISTORY` | `CASELOAD_MEMBER_DAYS` |
| Historical strategy | Creates monthly Snapshot and updates history | Rebuilds complete history every monthly run |
| Historical beginning | 201207 in validated production history | 200607 |
| Windows export | Snapshot export | Caseload export |
| Production location | Shared Budget folder | Shared Budget folder |
| Notification | Combined monthly email | Combined monthly email |

The two processes ultimately converge at the production Budget folder and the combined monthly email notification.

---

# 21. Notes for GitHub Maintenance

This README section should be updated whenever the production Snapshot architecture changes.

Keep the following synchronized with production:

- Snowflake procedure name
- First-Tuesday wrapper name
- Snowflake task and schedule
- Historical table name
- Snapshot date logic
- Windows task/batch name
- Python export program
- Output naming convention
- Production Budget folder
- Email process
- Recipients
- QC and recovery procedures

Do not commit passwords, authentication tokens, private keys, or other credentials to GitHub.

The executable SQL, Python, and batch files should preferably be maintained as separate repository files, while this README explains how the production components work together.





