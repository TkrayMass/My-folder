param(
    [string]$ReportDate = "",
    [int]$WaitMinutes = 90,
    [int]$RetrySeconds = 60
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

function Remove-SafeFile([string]$PathToRemove) {
    if (Test-Path -LiteralPath $PathToRemove) {
        Remove-Item -LiteralPath $PathToRemove -Force
        Write-Step "Cleanup removed: $PathToRemove"
    }
}

if ([string]::IsNullOrWhiteSpace($ReportDate)) {
    $ReportDate = Get-Date -Format "yyyyMMdd"
}

if ($ReportDate -notmatch '^\d{8}$') {
    throw "ReportDate must be in YYYYMMDD format."
}

$d = [datetime]::ParseExact($ReportDate, "yyyyMMdd", $null)
$folderName = "Enrollment Report $($d.Month)-$($d.Day)-$($d.Year)"

$adHoc = Join-Path $env:USERPROFILE "OneDrive - Commonwealth of Massachusetts\Ad Hoc"
$script:LogFile = Join-Path $adHoc "ACO_Weekly_Full_Process.log"
$transferBat = Join-Path $adHoc "run_enrollment_weekly.bat"
$formatBat = Join-Path $adHoc "format_enrollment_workbook.bat"

$destinationFolder = Join-Path "Z:\Analytics\Rouba\Enrollment and switcher report" $folderName

$regXls = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_REGXSA.xls"
$qcXls = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_SASQA.xls"
$regXlsx = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_REGXSA.xlsx"
$qcXlsx = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_SASQA.xlsx"
$regBackupXls = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_REGXSA_BEFORE_FORMAT.xls"
$qcBackupXls = Join-Path $destinationFolder "ReportTestMonthly-$($ReportDate)_SASQA_BEFORE_FORMAT.xls"

$publishFolder = Join-Path $env:USERPROFILE "OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report"
$publishedFile = Join-Path $publishFolder ([System.IO.Path]::GetFileName($regXlsx))

try {
    Write-Step "============================================================"
    Write-Step "ACO Weekly WEDNESDAY preparation workflow started"
    Write-Step "Report date: $ReportDate"

    foreach ($required in @($transferBat, $formatBat)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Missing required file: $required"
        }
    }

    if (-not (Test-Path -LiteralPath $publishFolder)) {
        throw "Missing OneDrive publication folder: $publishFolder"
    }

    Write-Step "STEP 1: Transfer REGXSA and SASQA from Linux"

    & $transferBat `
        --report-date $ReportDate `
        --wait-minutes $WaitMinutes `
        --retry-seconds $RetrySeconds

    if ($LASTEXITCODE -ne 0) {
        throw "Transfer failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $regXls)) {
        throw "REGXSA missing after transfer: $regXls"
    }

    if (-not (Test-Path -LiteralPath $qcXls)) {
        throw "SASQA missing after transfer: $qcXls"
    }

    Write-Step "STEP 2: Format/compact REGXSA to XLSX"

    & $formatBat $regXls

    if ($LASTEXITCODE -ne 0) {
        throw "REGXSA formatting failed with exit code $LASTEXITCODE"
    }

    Write-Step "STEP 3: Convert SASQA to XLSX"

    & $formatBat $qcXls

    if ($LASTEXITCODE -ne 0) {
        throw "SASQA conversion failed with exit code $LASTEXITCODE"
    }

    foreach ($f in @($regXlsx, $qcXlsx)) {
        if (-not (Test-Path -LiteralPath $f)) {
            throw "Expected XLSX missing: $f"
        }

        if ((Get-Item -LiteralPath $f).Length -le 0) {
            throw "Expected XLSX is zero bytes: $f"
        }
    }

    Write-Step "STEP 4: Read QC Distribution Decision"

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

        for ($r = 1; $r -le $used.Rows.Count -and -not $decision; $r++) {
            for ($c = 1; $c -le $used.Columns.Count -and -not $decision; $c++) {
                $v = [string]$used.Cells.Item($r, $c).Text
                $u = $v.Trim().ToUpperInvariant()

                if ($u -in @(
                    "READY TO DISTRIBUTE",
                    "REVIEW BEFORE DISTRIBUTION",
                    "DO NOT DISTRIBUTE"
                )) {
                    $decision = $u
                }
            }
        }
    }
    finally {
        if ($null -ne $wb) {
            try { $wb.Close($false) | Out-Null } catch {}
        }

        if ($null -ne $excel) {
            try { $excel.Quit() } catch {}
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
        throw "QC gate stopped publication. Decision=$decision"
    }

    Write-Step "STEP 5: Publish approved REGXSA to OneDrive"

    Copy-Item `
        -LiteralPath $regXlsx `
        -Destination $publishedFile `
        -Force

    $sourceSize = (Get-Item -LiteralPath $regXlsx).Length
    $publishedSize = (Get-Item -LiteralPath $publishedFile).Length

    if ($sourceSize -ne $publishedSize) {
        throw "Published file size mismatch. Source=$sourceSize Published=$publishedSize"
    }

    Write-Step "Published file verified: $publishedFile"

    Write-Step "STEP 6: Allow OneDrive sync time"
    Start-Sleep -Seconds 60

    Write-Step "STEP 7: Cleanup temporary/original XLS files"

    foreach ($cleanupFile in @(
        $regXls,
        $regBackupXls,
        $qcXls,
        $qcBackupXls
    )) {
        Remove-SafeFile $cleanupFile
    }

    Write-Step "Cleanup completed. Final XLSX files retained."
    Write-Step "FINAL STATUS = SUCCESS - WEDNESDAY PREPARATION COMPLETE / NO EMAIL SENT"
    Write-Step "============================================================"

    exit 0
}
catch {
    Write-Step "FINAL STATUS = FAILED"
    Write-Step "ERROR: $($_.Exception.Message)"
    Write-Step "Temporary/original files were retained because the workflow did not complete successfully."
    Write-Step "NO DISTRIBUTION EMAIL WAS SENT."
    Write-Step "============================================================"

    exit 1
}