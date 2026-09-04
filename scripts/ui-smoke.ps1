[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [int]$TimeoutMilliseconds = 30000
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$resolvedAppPath = (Resolve-Path -LiteralPath $AppPath).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$dataPath = Join-Path $outputPath "data"
$resultPath = Join-Path $outputPath "result.json"
$summaryPath = Join-Path $outputPath "summary.json"

if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 120000) {
    throw "TimeoutMilliseconds must be between 1000 and 120000."
}

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
if (Test-Path -LiteralPath $dataPath) {
    Remove-Item -LiteralPath $dataPath -Recurse -Force
}
if (Test-Path -LiteralPath $resultPath) {
    Remove-Item -LiteralPath $resultPath -Force
}
if (Test-Path -LiteralPath $summaryPath) {
    Remove-Item -LiteralPath $summaryPath -Force
}
New-Item -ItemType Directory -Path $dataPath -Force | Out-Null

$arguments = @(
    "--ui-smoke",
    "--test-mode",
    "--notification-dry-run",
    "--data-dir", $dataPath,
    "--smoke-result", $resultPath,
    "--smoke-hold-ms", "2000"
)

Write-Host "> $resolvedAppPath $($arguments -join ' ')" -ForegroundColor Cyan
$first = Start-Process -FilePath $resolvedAppPath -ArgumentList $arguments -WorkingDirectory (Split-Path $resolvedAppPath) -PassThru -WindowStyle Hidden
$firstStarted = $false
for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $first.Refresh()
    if ($first.HasExited) {
        break
    }
    if (Test-Path -LiteralPath (Join-Path $dataPath "data.json")) {
        $firstStarted = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not $firstStarted) {
    if (-not $first.HasExited) {
        $first.Kill($true)
    }
    throw "The first-instance smoke process did not finish startup before the singleton check."
}

$second = Start-Process -FilePath $resolvedAppPath -ArgumentList @(
    "--ui-smoke",
    "--test-mode",
    "--notification-dry-run",
    "--data-dir", $dataPath,
    "--smoke-result", (Join-Path $outputPath "second-result.json")
) -WorkingDirectory (Split-Path $resolvedAppPath) -PassThru -WindowStyle Hidden
if (-not $second.WaitForExit(10000)) {
    $second.Kill($true)
    throw "The second-instance smoke process did not exit promptly."
}
if ($second.ExitCode -ne 0) {
    throw "The second-instance smoke process exited with code $($second.ExitCode)."
}

if (-not $first.WaitForExit($TimeoutMilliseconds)) {
    $first.Kill($true)
    throw "The Windows UI smoke process exceeded $TimeoutMilliseconds milliseconds."
}
if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "The Windows UI smoke process did not produce $resultPath."
}

$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if ($first.ExitCode -ne 0 -or $result.result -ne "passed" -or $result.exitCode -ne 0) {
    throw "The Windows UI smoke result was not passed: $($result | ConvertTo-Json -Compress)."
}

$summary = [ordered]@{
    result = "passed"
    firstProcessExitCode = $first.ExitCode
    secondProcessExitCode = $second.ExitCode
    smokeResult = $result
    appPath = $resolvedAppPath
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Host "UI smoke and single-instance checks passed." -ForegroundColor Green
Get-Content -LiteralPath $summaryPath
