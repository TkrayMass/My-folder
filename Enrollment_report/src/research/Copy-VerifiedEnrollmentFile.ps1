param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256
)
$ErrorActionPreference = 'Stop'
$sourceItem = Get-Item -LiteralPath $Source
if ($sourceItem.PSIsContainer -or $sourceItem.Length -le 0) { throw 'Source must be a nonempty file.' }
$sourceHash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
if ($sourceHash -ne $ExpectedSHA256) { throw 'Source checksum differs from the approved artifact.' }
$target = [IO.Path]::GetFullPath($Destination)
if ($sourceItem.FullName -eq $target) { throw 'Source and destination must differ.' }
if (Test-Path -LiteralPath $target) {
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $ExpectedSHA256) {
        throw 'A different destination file exists; preserve it and choose another destination.'
    }
    [pscustomobject]@{ Status='ALREADY_VERIFIED'; Path=$target; SHA256=$sourceHash; Bytes=$sourceItem.Length }
    return
}
$parent = [IO.Path]::GetDirectoryName($target)
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination folder must already exist.' }
$partial = $target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
try {
    Copy-Item -LiteralPath $sourceItem.FullName -Destination $partial
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'Copied checksum differs.' }
    # File.Move refuses to overwrite an existing destination, including a racing writer.
    [IO.File]::Move($partial, $target)
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'Final checksum differs.' }
    [pscustomobject]@{ Status='COPIED_VERIFIED'; Path=$target; SHA256=$sourceHash; Bytes=$sourceItem.Length }
}
finally {
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
}
