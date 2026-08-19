param(
    [Parameter(Mandatory = $true)]
    [string]$WorkbookPath
)

$ErrorActionPreference = "Stop"

function Write-Log([string]$Message) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
}

function Get-WorksheetSafe {
    param($Workbook, [string]$SheetName)
    foreach ($sheet in $Workbook.Worksheets) {
        if ($sheet.Name -eq $SheetName -or $sheet.Name.Trim() -eq $SheetName.Trim()) {
            return $sheet
        }
    }
    Write-Log "WARNING: Worksheet not found and skipped: $SheetName"
    return $null
}

function AutoFit-Rows {
    param($Worksheet, [string]$RangeAddress)
    if ($null -eq $Worksheet) { return }
    Write-Log "Auto-fitting rows $RangeAddress on [$($Worksheet.Name)]"
    $Worksheet.Range($RangeAddress).EntireRow.AutoFit() | Out-Null
}

function Set-FreezeRows {
    param($Excel, $Worksheet, [int]$RowsToFreeze)
    if ($null -eq $Worksheet) { return }
    Write-Log "Freezing $RowsToFreeze row(s) on [$($Worksheet.Name)]"
    $Worksheet.Activate() | Out-Null
    $window = $Excel.ActiveWindow
    $window.FreezePanes = $false
    $window.SplitColumn = 0
    $window.SplitRow = $RowsToFreeze
    $window.FreezePanes = $true
}

function Clear-FreezePanes {
    param($Excel, $Worksheet)
    if ($null -eq $Worksheet) { return }
    Write-Log "Clearing freeze panes on [$($Worksheet.Name)]"
    $Worksheet.Activate() | Out-Null
    $window = $Excel.ActiveWindow
    $window.FreezePanes = $false
    $window.SplitColumn = 0
    $window.SplitRow = 0
}

$resolvedPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
$dir = [System.IO.Path]::GetDirectoryName($resolvedPath)
$base = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
$xlsxPath = Join-Path $dir ($base + ".xlsx")
$isQC = $base -match "_SASQA$"

Write-Log "Workbook: $resolvedPath"
Write-Log "Output XLSX: $xlsxPath"

if (-not $isQC) {
    $backupPath = Join-Path $dir ($base + "_BEFORE_FORMAT" + [System.IO.Path]::GetExtension($resolvedPath))
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $resolvedPath -Destination $backupPath
        Write-Log "Backup created: $backupPath"
    } else {
        Write-Log "Backup already exists; not overwritten: $backupPath"
    }
}

$excel = $null
$workbook = $null

try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $excel.EnableEvents = $false

    Write-Log "Opening workbook in Excel"
    $workbook = $excel.Workbooks.Open($resolvedPath)

    if (-not $isQC) {
        $firstSheet = $workbook.Worksheets.Item(1)

        AutoFit-Rows $firstSheet "1:4"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary") "1:8"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-Enroll-Region") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-Caseload-Reg x SA") "1:7"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-Caseload-Reg x SA") "8:8"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-Enroll-Reg X SA") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-Enroll-Reg X RC") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Summary-DisEnroll-Reg X SA") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Caseload") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Caseload-Reg X SA") "1:2"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Enrollment") "1:7"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Enrollment") "8:8"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Enrollment-Reg X SA") "2:8"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Disenrollment") "1:7"
        AutoFit-Rows (Get-WorksheetSafe $workbook "Disenrollment_Reg X SA") "1:7"

        Set-FreezeRows $excel $firstSheet 6
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Disenrollment") 6
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Enrollment-Reg X SA") 1
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Enrollment") 7
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Caseload") 1
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Summary-DisEnroll-Reg X SA") 1
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Summary-Enroll-Reg X RC") 1
        Clear-FreezePanes $excel (Get-WorksheetSafe $workbook "Summary-Enroll-Reg X SA")
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Summary-Caseload-Reg x SA") 6
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Summary-Enroll-Region") 1
        Set-FreezeRows $excel (Get-WorksheetSafe $workbook "Summary") 7

        $summary = Get-WorksheetSafe $workbook "Summary"
        if ($null -ne $summary) {
            $summary.Activate() | Out-Null
            Write-Log "Summary worksheet activated"
        }
    }

    if (Test-Path -LiteralPath $xlsxPath) {
        Remove-Item -LiteralPath $xlsxPath -Force
    }

    Write-Log "Saving workbook as compact XLSX"
    $workbook.SaveAs($xlsxPath, 51)
    Write-Log "XLSX save completed"

    $workbook.Close($false)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
    $workbook = $null

    if (-not (Test-Path -LiteralPath $xlsxPath)) {
        throw "XLSX output was not created: $xlsxPath"
    }

    $sizeMB = [math]::Round((Get-Item -LiteralPath $xlsxPath).Length / 1MB, 2)
    Write-Log "Final XLSX size: $sizeMB MB"

    if (-not $isQC) {
        $oldSize = (Get-Item -LiteralPath $resolvedPath).Length
        $newSize = (Get-Item -LiteralPath $xlsxPath).Length
        if ($oldSize -gt 0) {
            $reduction = [math]::Round((1 - ($newSize / $oldSize)) * 100, 1)
            Write-Log "Size reduction: $reduction%"
        }
        Write-Log "Workbook formatting and compaction completed successfully"
    } else {
        Write-Log "SASQA XLSX conversion completed successfully"
    }
}
finally {
    if ($null -ne $workbook) {
        try { $workbook.Close($false) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null } catch {}
    }
    if ($null -ne $excel) {
        try { $excel.Quit() } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch {}
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
