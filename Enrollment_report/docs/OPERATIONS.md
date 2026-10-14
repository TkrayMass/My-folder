# Scheduling and operations

All times are America/New_York. Current weekly cycle: Wednesday 13:00 generation
and owner QC email; Thursday 13:00 transfer; Friday 09:30 distribution.

Linux cron:

```cron
CRON_TZ=America/New_York
0 13 * * 3 /bin/bash /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/integrated_scheduled_v1/run_enrollment_scheduled_v1.sh >> /sas_mass_health/shared/tkray/Enrollment/Reports/ACO_REBUILD_XLSX/Scheduled_Enrollment.log 2>&1
```

| Existing Windows task | Installed action | Schedule |
|---|---|---|
| ACO Weekly Enrollment Report | run_rebuilt_enrollment_thursday.bat | Thursday 13:00 |
| ACO Weekly Friday Distribution | run_rebuilt_enrollment_friday.bat | Friday 09:30 |

Windows runtime is `%USERPROFILE%/OneDrive - Commonwealth of Massachusetts/Ad Hoc/Enrollment_Rebuilt_Runtime`.
Staging is `%USERPROFILE%/ACO_Weekly_Rebuilt_Staging`; publication is
`%USERPROFILE%/OneDrive - Commonwealth of Massachusetts/Monthly_enrollment_report`.
The report is named ReportTestMonthly-YYYYMMDD_REGXSA.xlsx using Wednesday's date.
The Thursday launcher uses --latest-wednesday --not-before-local 13:00.

Keep the PC on and logged in with network access and OneDrive running. Close the
workbook before replacement. Outlook must be available for Friday distribution.
Tasks use InteractiveToken, StartWhenAvailable, and IgnoreNew; transfer task
retains three hourly failure restarts and battery restrictions.

Check Scheduled_Enrollment.log, per-run SAS/QC status, LATEST_RELEASE.json,
Wednesday/Thursday_Transfer.log, LATEST_TRANSFER_RECEIPT.json, Friday_Notification.log,
published verification receipt, sent marker, and promoted baseline archive.
Do not rerun failed legacy recovery launchers. For a changed or uncertain sent
state, inspect receipts and Outlook first; do not force a resend. Confirm cloud
publication separately from local receipt. Never delete the approved workbook to
make a copy operation pass.
