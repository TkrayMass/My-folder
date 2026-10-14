param(
    [string]$ReportDate = "",
    [switch]$ForceSend,
    [switch]$ValidateOnly,
    [string]$ReceiptPath = "",
    [string]$PublishedFileOverride = ""
)

$ErrorActionPreference = "Stop"

function Get-ReportSHA256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Write-Step([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line
}

function Release-ComObject($obj) {
    if ($null -ne $obj) {
        try {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
        }
        catch {}
    }
}

# ============================================================
# REPORT DATE
# Default = most recent Wednesday.
# On the normal Friday schedule, this resolves to two days ago.
# ============================================================

if ([string]::IsNullOrWhiteSpace($ReportDate)) {
    $today = (Get-Date).Date
    $daysBack = (([int]$today.DayOfWeek - [int][DayOfWeek]::Wednesday) + 7) % 7
    $reportDay = $today.AddDays(-$daysBack)
    $ReportDate = $reportDay.ToString("yyyyMMdd")
}

if ($ReportDate -notmatch '^\d{8}$') {
    throw "ReportDate must be in YYYYMMDD format."
}

$d = [datetime]::ParseExact($ReportDate, "yyyyMMdd", $null)
$folderName = "Enrollment Report $($d.Month)-$($d.Day)-$($d.Year)"

# ============================================================
# PATHS
# ============================================================

$adHoc = Join-Path $env:USERPROFILE `
    "OneDrive - Commonwealth of Massachusetts\Ad Hoc"

$script:LogFile = Join-Path $adHoc `
    "ACO_Weekly_Friday_Distribution.log"

$sentMarker = Join-Path $adHoc `
    "ACO_Weekly_Email_Sent_$ReportDate.ok"

$publishFolder = Join-Path $env:USERPROFILE `
    "OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report"

$publishedFile = Join-Path $publishFolder `
    "ReportTestMonthly-${ReportDate}_REGXSA.xlsx"

if (-not $ReceiptPath) { $ReceiptPath = Join-Path $env:USERPROFILE 'ACO_Weekly_Rebuilt_Staging\LATEST_TRANSFER_RECEIPT.json' }
$release = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
if (-not $release.approved_source -or $release.transfer_route -ne 'LINUX_TO_ONEDRIVE') { throw 'A direct OneDrive publication receipt is required.' }
$regXlsx = $release.approved_source
if ($PublishedFileOverride) {
    if (-not $ValidateOnly) { throw 'Published file override is allowed only for validation.' }
    $publishedFile = $PublishedFileOverride
}
$runtimePython = Join-Path $env:USERPROFILE 'AppData/Local/Programs/Python/Python313/python.exe'
$promoter = Join-Path $PSScriptRoot 'promote_baseline_windows.py'


# ============================================================
# RECIPIENTS
# ============================================================

$Recipients = @(
    "Richard Blackman",
    "Nathan Dean",
    "Terence Finnigan",
    "Tatyana Kray",
    "Robert Roche",
    "Rouba Youssef",
    "Elizabeth Neal",
    "stacie.billard@mass.gov",
    "Staige.Davis@mass.gov"
)

$folderLink = "https://massgov-my.sharepoint.com/my?id=%2Fpersonal%2Ftatyana%5Fkray%5Fmass%5Fgov%2FDocuments%2FMonthly%5Fenrollment%5Freport"

# ============================================================
# FRIDAY DISTRIBUTION ONLY
#
# This script verifies publication, submits the existing Friday link notification, and archives the distributed baseline.
# It only verifies Wednesday's report and sends the
# distribution email once.
# QC policy: warnings/review are allowed; blocking FAIL stops distribution.
# ============================================================

try {

    Write-Step "============================================================"
    Write-Step "ACO Weekly FRIDAY distribution workflow started"
    Write-Step "Report date: $ReportDate"

    # --------------------------------------------------------
    # Duplicate-send protection
    # --------------------------------------------------------

    if ((Test-Path -LiteralPath $sentMarker) -and -not $ForceSend) {
        Write-Step "Email already recorded as sent for $ReportDate."
        if (-not $ValidateOnly) {
            & $runtimePython $promoter --receipt $ReceiptPath --marker $sentMarker
            if ($LASTEXITCODE -ne 0) { throw 'Previously sent notification; baseline update still pending.' }
        }
        Write-Step "No duplicate email sent."
        Write-Step "FINAL STATUS = SUCCESS - ALREADY SENT / NO ACTION"
        Write-Step "============================================================"
        exit 0
    }

    # --------------------------------------------------------
    # Verify Wednesday outputs exist and are non-zero
    # --------------------------------------------------------

    foreach ($f in @($regXlsx, $publishedFile, $ReceiptPath)) {

        if (-not (Test-Path -LiteralPath $f)) {
            throw "Required Friday distribution file is missing: $f"
        }

        if ((Get-Item -LiteralPath $f).Length -le 0) {
            throw "Required Friday distribution file is zero bytes: $f"
        }
    }

    Write-Step "Wednesday rebuilt report, release receipt, and published report are present."

    # --------------------------------------------------------
    # Record source and published REGXSA sizes
    #
    # Exact byte-size equality is NOT required.
    # The published workbook may legitimately change size after
    # Excel processing, formatting, compaction, and publication.
    #
    # The SASQA QC_Summary decision below remains the required
    # distribution gate, with warnings allowed.
    # --------------------------------------------------------

    $sourceItem = Get-Item -LiteralPath $regXlsx
    $publishedItem = Get-Item -LiteralPath $publishedFile

    $sourceSize = $sourceItem.Length
    $publishedSize = $publishedItem.Length

    Write-Step "Approved immutable source size: $sourceSize bytes"
    Write-Step "Published REGXSA size: $publishedSize bytes"

    if ($sourceSize -ne $publishedSize) {
        Write-Step "INFO: Published size differs from the immutable source; complete content comparison is required."
    }
    else {
        Write-Step "Published REGXSA size matches the immutable source."
    }

    Write-Step "Published REGXSA is present; content verification follows."

    # ========================================================
    # Read QC Distribution Decision again
    # ========================================================

    Write-Step "Checking rebuilt report release receipt and SHA256 before Friday email"
    if ($release.report_date -ne $ReportDate -or -not $release.run_id) { throw 'Release date/run identity differs.' }
    if ($release.qc_decision -notin @('PASS','REVIEW')) { throw 'Release QC blocks notification.' }
    if ((Get-ReportSHA256 $regXlsx) -ne $release.report_sha256) {
        throw 'Retained source differs from the immutable validated release.'
    }
    if (-not $ValidateOnly -and $release.published_file -ne $publishedFile) { throw 'Publication receipt path differs.' }
    $verificationPath = Join-Path $PSScriptRoot "Published_Verification_$ReportDate.json"
    & $runtimePython (Join-Path $PSScriptRoot 'verify_published_report.py') `
        --source $regXlsx --published $publishedFile --expected-sha256 $release.report_sha256 `
        --run-id $release.run_id --report-date $ReportDate --output $verificationPath
    if ($LASTEXITCODE -ne 0) { throw 'Published workbook contents differ from the validated release.' }
    $verifiedPublication = Get-Content -LiteralPath $verificationPath -Raw | ConvertFrom-Json
    if ($verifiedPublication.status -ne 'PASS' -or $verifiedPublication.differences -ne 0) { throw 'Published content verification did not pass.' }
    $verificationSHA = Get-ReportSHA256 $verificationPath
    $decision = if ($release.qc_decision -eq 'PASS') { 'READY TO DISTRIBUTE' } else { 'REVIEW BEFORE DISTRIBUTION' }
    if ($ValidateOnly) {
        Write-Step "VALIDATION PASS: release/run/date, immutable source SHA256, and published contents match. No email sent."
        exit 0
    }

    Write-Step "QC gate passed. Preparing Friday Outlook notification."
    if ((Get-ReportSHA256 $publishedFile) -ne $verifiedPublication.published_sha256) {
        throw 'Published report changed after verification; retry before sending.'
    }

    $outlook = $null
    $mail = $null

    try {

        $outlook = New-Object -ComObject Outlook.Application
        $mail = $outlook.CreateItem(0)

        foreach ($name in $Recipients) {
            $recip = $mail.Recipients.Add($name)
            $recip.Type = 1
        }

        if (-not $mail.Recipients.ResolveAll()) {

            $unresolved = @()

            foreach ($recip in $mail.Recipients) {
                if (-not $recip.Resolved) {
                    $unresolved += $recip.Name
                }
            }

            throw "One or more Enrollment recipients could not be resolved in Outlook: $($unresolved -join ', ')"
        }

        Write-Step "All Enrollment email recipients resolved successfully."

        # ----------------------------------------------------
        # Email subject
        # ----------------------------------------------------

        $mail.Subject = "Enrollment Report"

        $dateText = $d.ToString("MM/dd/yyyy")

        $mail.Body = @"
Hello all, please find the enrollment report (as of $dateText) shared. As always please let me know if you have any questions.

$folderLink

Thank you,
Tanya
"@

        if ((Get-ReportSHA256 $publishedFile) -ne $verifiedPublication.published_sha256) {
            throw 'Published report changed while preparing notification; no email submitted.'
        }
        $mail.Send()

        Write-Step "Outlook Enrollment email submitted successfully."
    }
    finally {

        Release-ComObject $mail
        Release-ComObject $outlook

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    # --------------------------------------------------------
    # Create sent marker only after Outlook submission succeeds
    # --------------------------------------------------------

    $markerText = @"
ReportDate=$ReportDate
SentAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
PublishedFile=$publishedFile
QCDecision=$decision
RunID=$($release.run_id)
ReleaseSHA256=$($release.report_sha256)
PublishedSHA256=$($verifiedPublication.published_sha256)
ContentVerificationReceipt=$verificationPath
ContentVerificationSHA256=$verificationSHA
"@

    Set-Content `
        -LiteralPath $sentMarker `
        -Value $markerText `
        -Encoding UTF8

    Write-Step "Sent marker created: $sentMarker"
    & $runtimePython $promoter --receipt $ReceiptPath --marker $sentMarker
    if ($LASTEXITCODE -ne 0) { throw 'Notification submitted; baseline update failed. Sent marker prevents duplicate notification.' }

    Write-Step "FINAL STATUS = SUCCESS - FRIDAY DISTRIBUTION SENT"
    Write-Step "============================================================"

    exit 0
}
catch {

    Write-Step "FINAL STATUS = FAILED"
    Write-Step "ERROR: $($_.Exception.Message)"
    Write-Step "Check the sent marker before retrying; Outlook may already have accepted the notification."
    Write-Step "============================================================"

    exit 1
}
