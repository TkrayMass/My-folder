param(
    [Parameter(Mandatory=$true)][string]$Python,
    [Parameter(Mandatory=$true)][string]$RunManifest,
    [Parameter(Mandatory=$true)][string]$FinalQC,
    [Parameter(Mandatory=$true)][string]$Report,
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$Receipt,
    [string]$FormatReceipt,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Receipt) { throw 'Preserve prior transfer receipts; choose a new receipt path.' }
$gateArgs = @((Join-Path $PSScriptRoot 'check_transfer_gate.py'), '--run-manifest', $RunManifest,
    '--final-qc', $FinalQC, '--report', $Report)
if ($FormatReceipt) { $gateArgs += @('--format-receipt', $FormatReceipt) }
$gateText = & $Python @gateArgs
if ($LASTEXITCODE -ne 0) { throw 'Report/QC transfer checks failed; nothing copied.' }
$gate = ($gateText -join "`n") | ConvertFrom-Json
if (-not $gate.staging_allowed) { throw 'Transfer staging blocked.' }
if ($Publish -and -not $gate.publication_allowed) { throw 'Run is not released for publication.' }
if (-not $Publish) {
    # Candidate staging must never target the production report library.
    $fullTarget = [IO.Path]::GetFullPath($Destination)
    $production = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'OneDrive - Commonwealth of Massachusetts/Monthly_enrollment_report'))
    if ($fullTarget.StartsWith($production + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production report folder requires released publication mode.'
    }
}
$copied = & (Join-Path $PSScriptRoot 'Copy-VerifiedEnrollmentFile.ps1') -Source $Report -Destination $Destination -ExpectedSHA256 $gate.report_sha256
$result = [ordered]@{
    run_id=$gate.run_id; report_date=$gate.report_date; qc_decision=$gate.qc_decision
    mode=$(if ($Publish) { 'PUBLICATION' } else { 'CANDIDATE_STAGING' })
    copy_status=$copied.Status; destination=$copied.Path; bytes=$copied.Bytes
    report_sha256=$copied.SHA256; cloud_sync_verified=$false
    recorded_at_utc=[DateTime]::UtcNow.ToString('o')
}
$receiptText = $result | ConvertTo-Json
$receiptStream = [IO.File]::Open([IO.Path]::GetFullPath($Receipt), [IO.FileMode]::CreateNew)
try { $data = [Text.UTF8Encoding]::new($false).GetBytes($receiptText); $receiptStream.Write($data, 0, $data.Length) }
finally { $receiptStream.Dispose() }
$receiptText
