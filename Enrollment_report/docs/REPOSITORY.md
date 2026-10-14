# Source inventory and maintenance

Target: TkrayMass/My-folder, Enrollment_report. Structure follows the Advocacy
technical package: README, architecture, methods, operations, deployment, validation,
source inventory, and offline tests. Active Linux files were freshly downloaded
from integrated_scheduled_v1; active Windows code was copied from the installed
runtime. src/research retains additional local experimental source without
representing it as installed. legacy/Code preserves the previous repository code.

SOURCE_MANIFEST.json lists SHA256 hashes, roles, and source provenance. Credential
include contents, authentication keys, tokens, member data, workbook outputs,
distributed archives, runtime logs, and machine-specific receipts are excluded.
Any sanitized historical credential assignment is recorded without its value in
SOURCE_REVIEW.json. Exact installed source is retained unless sanitation is needed.
The private SAS authentication include remains an external dependency.

Refresh by collecting live code, checking dependencies, rerunning offline tests,
reviewing secret findings, and updating methods/schedules to the resulting behavior.
Review git diff and stage only Enrollment_report. Publishing documentation/source
does not deploy or restart any operational task. Preserve legacy code under its
explicit historical label; do not restore old launchers to the active Code path.
No license grant is inferred by this package.

Source whitespace and line endings are preserved for snapshot identity. Bash files use LF. Inherited SAS trailing whitespace is retained; diff checking excludes blank-at-end-of-line/end-of-file findings.
Inherited mixed space/tab indentation is also preserved; source whitespace checks are disabled for this historical snapshot.
