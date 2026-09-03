[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [double]$MinimumLineCoverage = 85.0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $repoRoot "artifacts"
$results = Join-Path $artifacts "test-results"
$publish = Join-Path $artifacts "publish\win-x64"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    Write-Host "`n> $FilePath $($Arguments -join ' ')" -ForegroundColor Cyan
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $FilePath $($Arguments -join ' ')"
    }
}

function Get-TestCounters {
    param([Parameter(Mandatory = $true)][string]$TrxPath)

    [xml]$trx = Get-Content -LiteralPath $TrxPath -Raw
    $counters = $trx.SelectSingleNode("//*[local-name()='Counters']")
    if ($null -eq $counters) {
        throw "Unable to locate test counters in $TrxPath"
    }

    return [ordered]@{
        Total = [int]$counters.total
        Executed = [int]$counters.executed
        Passed = [int]$counters.passed
        Failed = [int]$counters.failed
        Skipped = [int]$counters.notExecuted
    }
}

Push-Location $repoRoot
try {
    Remove-Item -LiteralPath $results -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $publish -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $results -Force | Out-Null
    New-Item -ItemType Directory -Path $publish -Force | Out-Null

    Write-Host "Taskronome verification" -ForegroundColor Green
    Invoke-Checked dotnet --info
    Invoke-Checked dotnet restore Taskronome.sln --force-evaluate
    Invoke-Checked dotnet format Taskronome.sln --verify-no-changes --no-restore --severity warn
    Invoke-Checked dotnet build Taskronome.sln --configuration $Configuration --no-restore

    Invoke-Checked dotnet test tests/Taskronome.Core.Tests/Taskronome.Core.Tests.csproj `
        --configuration $Configuration `
        --no-build `
        --settings coverlet.runsettings `
        --collect "XPlat Code Coverage" `
        --logger "trx;LogFileName=Taskronome.Core.Tests.trx" `
        --results-directory $results

    $trxPath = Join-Path $results "Taskronome.Core.Tests.trx"
    if (-not (Test-Path -LiteralPath $trxPath)) {
        throw "Expected TRX result was not produced: $trxPath"
    }

    $testCounters = Get-TestCounters -TrxPath $trxPath
    if ($testCounters.Failed -ne 0 -or $testCounters.Skipped -ne 0) {
        throw "Tests must have zero failures and zero skipped tests. Counters: $($testCounters | ConvertTo-Json -Compress)"
    }

    $coverageFile = Get-ChildItem -Path $results -Filter "coverage.cobertura.xml" -Recurse |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $coverageFile) {
        throw "Coverlet did not produce coverage.cobertura.xml"
    }

    [xml]$coverageXml = Get-Content -LiteralPath $coverageFile.FullName -Raw
    $lineRateText = [string]$coverageXml.coverage.'line-rate'
    $lineRate = [double]::Parse($lineRateText, [System.Globalization.CultureInfo]::InvariantCulture)
    $lineCoverage = [Math]::Round($lineRate * 100.0, 2)
    if ($lineCoverage -lt $MinimumLineCoverage) {
        throw "Core line coverage $lineCoverage% is below the required $MinimumLineCoverage%."
    }

    Invoke-Checked dotnet run `
        --project tests/Taskronome.ScenarioRunner/Taskronome.ScenarioRunner.csproj `
        --configuration $Configuration `
        --no-build

    $forbidden = Get-ChildItem -Path src, tests, scripts, installer -Recurse -File |
        Where-Object {
            $_.FullName -ne $PSCommandPath -and
            $_.Extension -in ".cs", ".xaml", ".ps1", ".yml", ".yaml", ".iss"
        } |
        Select-String -Pattern "\bTODO\b|NotImplementedException|PLACEHOLDER" -CaseSensitive
    if ($forbidden) {
        $forbidden | ForEach-Object { Write-Host $_.ToString() -ForegroundColor Red }
        throw "Unfinished implementation markers were found."
    }

    Invoke-Checked dotnet restore src/Taskronome.App/Taskronome.App.csproj `
        --runtime win-x64 `
        --force-evaluate

    Invoke-Checked dotnet publish src/Taskronome.App/Taskronome.App.csproj `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        --no-restore `
        --output $publish

    $appPath = Join-Path $publish "Taskronome.exe"
    if (-not (Test-Path -LiteralPath $appPath)) {
        throw "Publish completed without Taskronome.exe"
    }

    Write-Host "`n> $appPath --smoke-test" -ForegroundColor Cyan
    $process = Start-Process -FilePath $appPath -ArgumentList "--smoke-test" -PassThru
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        throw "The Windows UI smoke test exceeded 30 seconds."
    }

    if ($process.ExitCode -ne 0) {
        throw "The Windows UI smoke test failed with exit code $($process.ExitCode)."
    }

    $summary = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Configuration = $Configuration
        Tests = $testCounters
        CoreLineCoveragePercent = $lineCoverage
        Scenario = "passed"
        UiSmoke = "passed"
        PublishDirectory = $publish
    }
    $summaryPath = Join-Path $artifacts "verification-summary.json"
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

    Write-Host "`nVerification passed." -ForegroundColor Green
    Write-Host "Tests: $($testCounters.Passed)/$($testCounters.Total) passed, 0 skipped"
    Write-Host "Core line coverage: $lineCoverage%"
    Write-Host "Summary: $summaryPath"
}
finally {
    Pop-Location
}
