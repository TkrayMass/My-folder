# Architecture and success contracts

`run_enrollment_scheduled_v1.sh` resolves CURRENT_DISTRIBUTED_BASELINE.txt, enables
owner QC mail/failure alerts, and invokes the integrated launcher under a lock.
The integrated launcher creates a unique UTC run ID and audit directory, captures
executed source, runs SAS with 32 GB memory, normalizes native XLSX formatting,
then binds report hashes and SAS results into RUN_MANIFEST.json.

The pipeline executes source controls, distributed-baseline comparison, workbook
checks, final business QC, technical QC rendering, and primary comparison QC
rendering/validation. The transfer gate requires matching run/date, all required
controls, complete QC, consistent PASS/REVIEW decisions, and report identity.
The release package binds the report and QC artifacts. Owner QC mail is submitted
before LATEST_RELEASE.json is atomically advanced. Failed/uncertain mail submission
blocks the handoff and is not blindly retried.

Thursday Windows transfer retrieves the eligible latest Wednesday package using
SSH/SCP with host-key checking, verifies artifact hashes and QC, stages immutable
approved source, and copies the main report directly to the local OneDrive folder.
Private QC stays separate. Existing same-date content is verified or backed up
before approved replacement. The transfer writes a receipt and invokes Friday's
ValidateOnly mode without sending the distribution email or promoting a baseline.

Friday verifies the receipt, approved source, and current publication, then uses
Outlook to submit the existing report-link message. It records a sent marker to
prevent duplicate submission and promotes the notified release as the next
distributed comparison baseline. Receipt identity follows the actual publication
hash when Excel has saved an equivalent workbook.

Local publication success does not prove cloud synchronization. Outlook submission
does not prove recipient delivery. Baseline promotion is a separate auditable step.
