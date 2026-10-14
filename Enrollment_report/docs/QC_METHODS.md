# Report calculation and QC methods

The integrated SAS program is the executable specification for report extraction,
joins, category mappings, reporting periods, counts, percentages, and eleven report
worksheets. It preserves the established report calculations while producing native
XLSX. Inspect ACO_Weekly_Enrollment_Integrated.sas for exact SQL and PROC REPORT logic;
Validate_Integrated_Run_Sources.sas provides independent source controls. Snowflake
authentication is supplied by the external private SAS include.

## Required controls

| Control | Purpose |
|---|---|
| technical_completion | SAS completion, no blocking errors, output/run identity |
| baseline_comparison_identity | Comparison tied to the recorded distributed baseline |
| workbook_structure | Expected worksheet structure and readable report |
| upstream_totals | Report totals reconciled with independent source evidence |
| row_preservation | Required source/report rows retained |
| percentage_denominators | Rates use the intended source counts/denominators |
| detail_reconciliation | Detail agrees with report summaries within explicit display tolerances |
| cross_sheet_reconciliation | Related sheets reconcile, including precision policy |
| baseline_business_policy | Prior distributed values compared under documented business rules |

PASS and REVIEW may proceed when every control ran, none failed, technical status
is PASS, and evidence/run/report hashes agree. FAIL, NOT_RUN, missing/duplicate
controls, contradictory decisions, changed artifacts, or mismatched dates block.
REVIEW records limitations; it is not a manual approval requirement.

Baseline comparisons use archived distributed data rather than whichever output
was generated most recently. Historical periods and current month-to-date are
tracked separately. Adaptive thresholds retain existing business floors; after
eight archived comparison pairs, warning/failure thresholds are the greater of
their floors and mean + 2/3 sample standard deviations. Bound history rejects
duplicate pairs and invalid values. See adaptive_qc_policy.py and workbook validators
for exact thresholds and grouping.

Formatting uses direct XLSX XML operations; receipts establish preservation of
non-style data. Publication verification first checks immutable source SHA256.
If Excel rewrote publication bytes, all meaningful cells, formulas, sheet order/
visibility, merged ranges, frozen panes, date system, and non-print defined names
must still match. Blank-space trimming and numeric storage noise are allowed only
within absolute 1e-15 at magnitude <= 1 and 1e-9 otherwise. This does not grant
historical display-rounding tolerances to published content. Byte stability is
checked during verification and the publication checksum is checked before mail.
