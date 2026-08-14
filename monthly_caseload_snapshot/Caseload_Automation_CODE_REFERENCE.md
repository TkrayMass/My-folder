# Caseload Automation Code Reference

## Production objects

- `MHTEAM.MHA.CASELOAD_MONTHLY_DB3()`
- `MHTEAM.MHA.CASELOAD_MONTHLY_SCHEDULED_RUN()`
- `MHTEAM.MHA.CASELOAD_MONTHLY_REFRESH_TASK`
- `MHTEAM.MHA.CASELOAD_MEMBER_DAYS_TEMP`
- `MHTEAM.MHA.CASELOAD_MEMBER_DAYS`
- Snowflake schedule: every Tuesday at **10:00 AM ET**
- Windows task: `Monthly Caseload Export` — first Tuesday at **10:45 AM**
- Output: `Caseload_Member_Days_YYYYMM.xlsx`

## Source files

- [`Code/Caseload/caseload_monthly.sql`](Code/Caseload/caseload_monthly.sql)
- [`Code/Caseload/caseload_monthly_export.py`](Code/Caseload/caseload_monthly_export.py)
- [`Code/Caseload/run_caseload_export.bat`](Code/Caseload/run_caseload_export.bat)
- Shared notification: [`Code/Shared/monthly_email.py`](Code/Shared/monthly_email.py)

## Corrected filename convention

The controlled production filename is `Caseload_Member_Days_YYYYMM.xlsx`. Any earlier draft using a day-level Caseload filename is superseded.
