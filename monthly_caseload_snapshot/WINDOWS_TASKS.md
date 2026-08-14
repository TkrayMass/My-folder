# Windows Task Scheduler Configuration

## Snapshot Monthly Export

| Setting | Production value |
|---|---|
| Task name | `Snapshot Monthly Export` |
| Trigger | First Tuesday at 9:00 AM |
| Program/script | `C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\run_snapshot_export.bat` |
| Security | Run only when user is logged on |
| Run on demand | Enabled |
| Run after missed start | Enabled |
| Concurrent runs | Do not start a new instance |

## Monthly Caseload Export

| Setting | Production value |
|---|---|
| Task name | `Monthly Caseload Export` |
| Trigger | First Tuesday at 10:45 AM |
| Program/script | `C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\run_caseload_export.bat` |
| Security | Run only when user is logged on |
| Run on demand | Enabled |
| Retry | Every 2 hours, up to 3 attempts |
| Concurrent runs | Do not start a new instance |

## Monthly Reports Notification

| Setting | Production value |
|---|---|
| Task name | `Monthly Reports Notification` |
| Trigger | First Wednesday at 10:00 AM |
| Program | Python 3.13 executable |
| Script | `monthly_email.py` |
| Log | `Monthly_Report_Email.log` |
| Security | Run only when user is logged on |
| Concurrent runs | Do not start a new instance |

The Windows tasks require the workstation to be on, the user logged in, Commonwealth network/VPN access available, and Classic Outlook available for the notification step.

## Snowflake Schedules

Snapshot:

```sql
SCHEDULE = 'USING CRON 0 6 * * TUE America/New_York'
```

Caseload:

```sql
SCHEDULE = 'USING CRON 0 10 * * TUE America/New_York'
```

Both Snowflake tasks wake every Tuesday; their wrapper procedures enforce the first-Tuesday rule.
