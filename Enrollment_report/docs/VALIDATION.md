# Validation evidence and limitations

The rebuilt October 14 run completed technical PASS and business REVIEW with no
failed or unrun required controls. The primary comparison workbook recorded 748
comparisons, no meaningful numerical warnings, and no failures. Historical
provenance and display-rounding limitations remain recorded in technical QC.
Generation, initial publication, direct-OneDrive rehearsal, and publication
content verification have been exercised. The scheduled Windows preparation task's
last result was 0 when inspected October 14. Friday's task last result was 1;
this snapshot does not claim a successful future Friday distribution.

The legacy Linux job is absent from cron and no Windows scheduled action calls
the old generation/transfer scripts. Thursday 13:00 task was Enabled/Ready with
next run October 15; Friday's next run is October 16 at 09:30. The first future
Thursday execution and complete Friday cycle remain to be observed.

Run the portable offline suite with `python tests/run_tests.py`. Tests cover report
reading, precision, tracking, business QC, distributed comparison/promotion,
transfer gates, direct copy/replacement, Wednesday selection, publication content,
adaptive policy, and QC mail duplicate/uncertain submission handling. One real-cache
rehearsal requires private deployment artifacts and is deliberately skipped.
Package validation on October 14: 32 tests passed, one private-cache rehearsal
skipped, and all packaged Python sources passed syntax parsing. The business-QC
fixture was updated to include the manifest/report bindings required by installed
code. The Thursday date-selection script was tested and installed after the suite
identified an older Windows copy that did not accept --latest-wednesday.
Test results are recorded in TEST_RESULTS.txt. They do not prove live Snowflake,
SMTP/Outlook delivery, or cloud synchronization.

The Graph uploader in src/research is an isolated candidate. Offline protocol tests
do not establish an approved unattended identity or live upload/readback. Current
production transfer and distribution depend on the Windows PC. Linux failure-alert
SMTP delivery has not been proven. No report/member data is shipped as evidence.
