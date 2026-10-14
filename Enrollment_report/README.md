# ACO weekly Enrollment reporting automation

Installed source snapshot collected October 14, 2026. The current process refreshes
Snowflake reporting data, generates native XLSX with SAS, formats and validates it,
publishes the approved report directly to the local OneDrive folder on Thursday,
and submits the distribution link on Friday. OneDrive performs cloud synchronization.

## Weekly schedule

All times are America/New_York, including daylight saving changes.

| Stage | Day | Time | Required result |
|---|---|---|---|
| Generation, business/technical QC, owner QC email | Wednesday | 13:00 | Same-run completed PASS/REVIEW controls |
| Transfer and publication | Thursday | 13:00 | Latest Wednesday run started at or after Wednesday 13:00; verified package |
| Distribution link email and baseline promotion | Friday | 09:30 | Exact published report verified; duplicate-send marker checked |

The old Wednesday 09:00 SAS retry job and old Windows generation/transfer actions
are no longer scheduled. Windows task names are retained, with replacement actions.
The Thursday schedule starts October 15, 2026. No Z-drive transfer is required.

## Illustrated process guide

[Download the process guide (PDF)](docs/ACO_Weekly_Enrollment_Process_Guide.pdf) - 10 pages with code-labeled workflow diagrams, the weekly timeline, QC rules, and six actual QC screenshot excerpts.

## Reading order

1. [Architecture](docs/ARCHITECTURE.md)
2. [Report and QC methods](docs/QC_METHODS.md)
3. [Schedules and operations](docs/OPERATIONS.md)
4. [Deployment and rollback](docs/DEPLOYMENT.md)
5. [Validation and known limitations](docs/VALIDATION.md)
6. [Source inventory and repository maintenance](docs/REPOSITORY.md)
7. [Combined owner QC workbook](docs/COMBINED_QC.md)

## Source layout

- `src/linux`: freshly collected installed SAS, Bash, and Python pipeline.
- `src/windows`: installed transfer, publication verification, Friday mail, and launchers.
- `src/research`: supporting experimental code and earlier render/transfer approaches.
- `legacy/Code`: previous GitHub code preserved for historical reference, not deployment.
- `tests`: offline regression tests and runner; private-cache rehearsal is skipped.
- `SOURCE_MANIFEST.json`: SHA256 and provenance of selected source and documentation.
- `SOURCE_REVIEW.json`: credential-pattern review without credential values.

Run `python tests/run_tests.py` from this folder. Python 3.13 is the verified Windows
runtime; installed Linux Python is 3.6. SAS 9.4, Snowflake access, SSH/SCP, OneDrive,
PowerShell, and Outlook are operational dependencies. Repository cloning registers
no jobs. Executing production entry points can refresh tables, publish files, or send
mail. See deployment instructions before running them.

Credentials, private baseline archives, report workbooks, member data, runtime logs,
and receipts are not included. The private SAS credential include is an external
dependency; provision it securely on the server. Internal paths and contacts are
retained for organizational operations; review configuration before reuse.

