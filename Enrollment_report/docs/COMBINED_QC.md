# One owner QC attachment

The owner QC email now uses one workbook, ACO_Weekly_Enrollment_QC_YYYYMMDD.xlsx.
It follows the prior report's familiar summary, matrix, and detail structure.

- QC_Summary: current/prior report dates, comparison PASS/REVIEW/FAIL counts,
  overall decision, all required control statuses, and technical review reasons.
- QC_Matrix: months across columns; prior members, current members, difference,
  percentage change, and QC flag for each Summary category.
- QC_Detail: every prior/current comparison with threshold, status, and reason.
- Technical_Detail: full rounding/provenance diagnostics, kept separate from
  numerical comparison warnings within the same file.

PASS is green, REVIEW yellow, FAIL red. Comparison counts are separate from the
number of technical diagnostic lines. The October 14 example compares with the
October 7 archived baseline: all 748 comparison rows PASS. Overall REVIEW records
6,200 percentage-rounding lines, 1,282 subtotal-rounding lines, and one baseline
provenance note. The new layout does not change the numerical thresholds or gate.

prepare_combined_qc.py checks source identity/hashes and prepares CSV, a full
input receipt, and SAS rendering code. SAS renders with native numeric values
and Excel display formats; validate_combined_qc.py checks every exported cell,
worksheet order, colors, panes, filters, and source identity. The release package
binds the combined workbook, validation receipt, and input receipt. Owner mail
rechecks those hashes and attaches only the combined workbook. Uncertain-mail
and duplicate-submission protections remain in effect. Thursday transfer retains
the combined workbook in the private QC folder when the release includes it.

Earlier technical and primary QC files remain internal gate evidence. Existing
already-sent emails are not resent; the one-attachment change applies to future
scheduled runs. No source refresh, distribution email, baseline promotion, or
schedule change is needed to generate a combined view of completed evidence.
