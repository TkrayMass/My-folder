param(
    [string]$ReportDate = "",
    [switch]$ForceSend
)

$ErrorActionPreference = "Stop"

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

$destinationFolder = Join-Path `
    "Z:\Analytics\Rouba\Enrollment and switcher report" `
    $folderName

$regXlsx = Join-Path $destinationFolder `
    "ReportTestMonthly-$($ReportDate)_REGXSA.xlsx"

$qcXlsx = Join-Path $destinationFolder `
    "ReportTestMonthly-$($ReportDate)_SASQA.xlsx"

$publishFolder = Join-Path $env:USERPROFILE `
    "OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report"

$publishedFile = Join-Path $publishFolder `
    ([System.IO.Path]::GetFileName($regXlsx))

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
    "alejandro.e.garciadavalos@mass.gov",
    "Elizabeth Neal"
)

$folderLink = "https://massgov-my.sharepoint.com/my?id=%2Fpersonal%2Ftatyana%5Fkray%5Fmass%5Fgov%2FDocuments%2FMonthly%5Fenrollment%5Freport"

# ============================================================
# FRIDAY DISTRIBUTION ONLY
#
# This script does NOT transfer, format, publish, or clean up.
# It only verifies Wednesday's approved report and sends the
# distribution email once.
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
        Write-Step "No duplicate email sent."
        Write-Step "FINAL STATUS = SUCCESS - ALREADY SENT / NO ACTION"
        Write-Step "============================================================"
        exit 0
    }

    # --------------------------------------------------------
    # Verify Wednesday outputs exist
    # --------------------------------------------------------

    foreach ($f in @($regXlsx, $qcXlsx, $publishedFile)) {

        if (-not (Test-Path -LiteralPath $f)) {
            throw "Required Friday distribution file is missing: $f"
        }

        if ((Get-Item -LiteralPath $f).Length -le 0) {
            throw "Required Friday distribution file is zero bytes: $f"
        }
    }

    Write-Step "Wednesday REGXSA, SASQA, and published report are present."

    # --------------------------------------------------------
    # Verify published report matches approved shared-drive file
    # --------------------------------------------------------

    $sourceSize = (Get-Item -LiteralPath $regXlsx).Length
    $publishedSize = (Get-Item -LiteralPath $publishedFile).Length

    if ($sourceSize -ne $publishedSize) {
        throw "Published report size mismatch. Source=$sourceSize Published=$publishedSize"
    }

    Write-Step "Published REGXSA size verified: $publishedSize bytes"

    # ========================================================
    # Read QC Distribution Decision again
    # ========================================================

    Write-Step "Reading QC Distribution Decision before Friday email"

    $excel = $null
    $wb = $null
    $ws = $null
    $decision = $null

    try {

        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $wb = $excel.Workbooks.Open($qcXlsx)
        $ws = $wb.Worksheets.Item("QC_Summary")
        $used = $ws.UsedRange

        for (
            $r = 1;
            $r -le $used.Rows.Count -and -not $decision;
            $r++
        ) {

            for (
                $c = 1;
                $c -le $used.Columns.Count -and -not $decision;
                $c++
            ) {

                $v = [string]$used.Cells.Item($r, $c).Text
                $u = $v.Trim().ToUpperInvariant()

                if (
                    $u -in @(
                        "READY TO DISTRIBUTE",
                        "REVIEW BEFORE DISTRIBUTION",
                        "DO NOT DISTRIBUTE"
                    )
                ) {
                    $decision = $u
                }
            }
        }
    }
    finally {

        if ($null -ne $wb) {
            try {
                $wb.Close($false) | Out-Null
            }
            catch {}
        }

        if ($null -ne $excel) {
            try {
                $excel.Quit()
            }
            catch {}
        }

        Release-ComObject $ws
        Release-ComObject $wb
        Release-ComObject $excel

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    if ([string]::IsNullOrWhiteSpace($decision)) {
        throw "QC Distribution Decision was not found in QC_Summary."
    }

    Write-Step "QC Distribution Decision: $decision"

    if ($decision -ne "READY TO DISTRIBUTE") {
        throw "Friday distribution blocked by QC. Decision=$decision"
    }

    # ========================================================
    # Send Outlook notification
    # ========================================================

    Write-Step "QC approved. Preparing Friday Outlook notification."

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

        $mail.Subject = "Enrollment"
        $dateText = $d.ToString("MM/dd/yyyy")

        $mail.Body = @"
Hello all, please find the enrollment report (as of $dateText) shared. As always please let me know if you have any questions.

$folderLink

Thank you,
Tanya
"@

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
"@

    Set-Content -LiteralPath $sentMarker -Value $markerText -Encoding UTF8

    Write-Step "Sent marker created: $sentMarker"
    Write-Step "FINAL STATUS = SUCCESS - FRIDAY DISTRIBUTION SENT"
    Write-Step "============================================================"

    exit 0
}
catch {

    Write-Step "FINAL STATUS = FAILED"
    Write-Step "ERROR: $($_.Exception.Message)"
    Write-Step "NO FRIDAY DISTRIBUTION EMAIL WAS SENT BY THIS RUN."
    Write-Step "============================================================"

    exit 1
}
