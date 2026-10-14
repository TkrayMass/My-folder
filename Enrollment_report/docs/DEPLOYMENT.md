# Deployment, configuration, and rollback

This snapshot documents the installed replacement; copying or pushing it does not
perform a deployment. Preserve a source/hash snapshot and task XML/crontab backup
before installing a revised version. Run offline tests and review the source diff.

Install src/linux files together in the server's integrated_scheduled_v1 directory.
Keep Python import dependencies beside launchers. Provision SAS 9.4, Snowflake
ODBC/library paths, authorized refresh access, the private snowflake_credentials.sas
include, state SMTP relay access, writable run/output/release directories, flock,
and the distributed baseline manifest/archive. Do not commit the credential file.
Review all hard-coded institutional paths and contacts before deploying elsewhere.

Install src/windows files together in Enrollment_Rebuilt_Runtime. Provision Python
3.13, Windows PowerShell, OpenSSH/SCP, authorized SSH key and known_hosts entry,
OneDrive folder, and Outlook profile. Key path and HostKeyAlias are in
transfer_rebuilt_windows.py; never disable host-key verification. Friday launcher
uses process-only RemoteSigned without changing machine/user execution policy.

Modify the existing two Windows tasks rather than creating duplicate jobs. Keep
their user principal and interactive settings; use Thursday 13:00 and Friday 09:30.
Keep Linux Wednesday 13:00 cron and preserve unrelated Advocacy jobs.
Validate a completed QC-bound package and Friday ValidateOnly before observing
a normal transfer/email cycle. Owner QC email and failure alerts need delivery
verification; do not equate SMTP submission with inbox arrival.

Rollback requires the matching source backup, crontab, Windows task XML, and
baseline pointer. Review intervening changes before restoring. The workspace's
Cutover_Backup_20261014 includes legacy and pre-Thursday task evidence; these
machine-specific receipts are deliberately excluded here. Restoring legacy jobs
requires an explicit operational decision and must not leave replacement jobs
running in parallel.
