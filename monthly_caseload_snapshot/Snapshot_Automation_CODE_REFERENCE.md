# Snapshot Automation Code Reference

## Production objects

- `MHTEAM.MHA.SNAPSHOT_MONTHLY_DYNAMIC()`
- `MHTEAM.MHA.SNAPSHOT_MONTHLY_FIRST_TUESDAY()`
- `MHTEAM.MHA.SNAPSHOT_MONTHLY_TASK`
- `MHTEAM.MHA.SNAPSHOT_ELIGENR_HISTORY`
- Snowflake schedule: every Tuesday at **6:00 AM ET**
- Windows task: `Snapshot Monthly Export` — first Tuesday at **9:00 AM**
- Output: `Snapshot_eligenr_YYYYMMDDdisabfix_v1.xlsx`

## Source files

- [`Code/Snapshot/snapshot_monthly.sql`](Code/Snapshot/snapshot_monthly.sql)
- [`Code/Snapshot/export_snapshot_history.py`](Code/Snapshot/export_snapshot_history.py)
- [`Code/Snapshot/run_snapshot_export.bat`](Code/Snapshot/run_snapshot_export.bat)
- Shared notification: [`Code/Shared/monthly_email.py`](Code/Shared/monthly_email.py)

The Snapshot process creates the current monthly Snapshot, performs QC, and replaces that month in the cumulative history transactionally.
