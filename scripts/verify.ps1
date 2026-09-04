[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [double]$MinimumLineCoverage = 85.0,
    [double]$MinimumBranchCoverage = 75.0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $repoRoot "artifacts"
$results = Join-Path $artifacts "test-results"
$publish = Join-Path $artifacts "publish\win-x64"
$scenario = Join-Path $artifacts "scenario"
$uiSmoke = Join-Path $artifacts "ui-smoke"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    Write-Host "`n> $FilePath $($Arguments -join ' ')" -ForegroundColor Cyan
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
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

function Get-CoveragePercent {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$CoverageFile,
        [Parameter(Mandatory = $true)][string]$AttributeName
    )

    [xml]$coverageXml = Get-Content -LiteralPath $CoverageFile.FullName -Raw
    $value = [string]$coverageXml.coverage.$AttributeName
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Coverage file does not contain coverage.${AttributeName}: $($CoverageFile.FullName)"
    }

    $rate = [double]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture)
    return [Math]::Round($rate * 100.0, 2)
}

function Assert-SourceHygiene {
    $files = Get-ChildItem -LiteralPath (Join-Path $repoRoot "src") -Recurse -File |
        Where-Object { $_.Extension -in ".cs", ".xaml", ".ps1", ".yml", ".yaml", ".iss" }
    $issues = $files | Select-String -Pattern "\bTODO\b|\bFIXME\b|NotImplementedException|\bPLACEHOLDER\b" -CaseSensitive
    if ($issues) {
        $issues | ForEach-Object { Write-Host $_.ToString() -ForegroundColor Red }
        throw "Unfinished implementation markers were found in production source."
    }

    $absolutePathIssues = $files | Select-String -Pattern "[A-Za-z]:[\\/]Users[\\/]|D:[\\/]VibeCodingTools" -CaseSensitive
    if ($absolutePathIssues) {
        $absolutePathIssues | ForEach-Object { Write-Host $_.ToString() -ForegroundColor Red }
        throw "A developer-machine absolute path was found in production source."
    }
}

Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    foreach ($directory in @($results, $publish, $scenario, $uiSmoke)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Write-Host "Taskronome verification" -ForegroundColor Green
    Invoke-Checked dotnet --info
    Invoke-Checked dotnet restore Taskronome.sln --locked-mode
    Invoke-Checked dotnet format Taskronome.sln --verify-no-changes --no-restore --severity warn
    Invoke-Checked dotnet build Taskronome.sln --configuration $Configuration --no-restore

    Invoke-Checked dotnet test tests/Taskronome.Core.Tests/Taskronome.Core.Tests.csproj `
        --configuration $Configuration `
        --no-build `
        --settings coverlet.runsettings `
        --collect "XPlat Code Coverage" `
        --logger "trx;LogFileName=final-tests.trx" `
        --results-directory $results

    $trxPath = Get-ChildItem -LiteralPath $results -Filter "final-tests.trx" -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $trxPath) {
        throw "Expected TRX result was not produced below $results"
    }

    $testCounters = Get-TestCounters -TrxPath $trxPath.FullName
    if ($testCounters.Total -lt 50) {
        throw "At least 50 deterministic tests are required; TRX reported $($testCounters.Total)."
    }
    if ($testCounters.Failed -ne 0 -or $testCounters.Skipped -ne 0) {
        throw "Tests must have zero failures and zero skipped tests. Counters: $($testCounters | ConvertTo-Json -Compress)"
    }

    $coverageFile = Get-ChildItem -LiteralPath $results -Filter "coverage.cobertura.xml" -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $coverageFile) {
        throw "Coverlet did not produce coverage.cobertura.xml"
    }

    $lineCoverage = Get-CoveragePercent -CoverageFile $coverageFile -AttributeName "line-rate"
    $branchCoverage = Get-CoveragePercent -CoverageFile $coverageFile -AttributeName "branch-rate"
    if ($lineCoverage -lt $MinimumLineCoverage) {
        throw "Core line coverage $lineCoverage% is below the required $MinimumLineCoverage%."
    }
    if ($branchCoverage -lt $MinimumBranchCoverage) {
        throw "Core branch coverage $branchCoverage% is below the required $MinimumBranchCoverage%."
    }

    $scenarioResult = Join-Path $scenario "scenario-result.json"
    $scenarioLog = Join-Path $scenario "scenario-log.txt"
    Invoke-Checked dotnet run `
        --project tests/Taskronome.ScenarioRunner/Taskronome.ScenarioRunner.csproj `
        --configuration $Configuration `
        --no-build `
        -- `
        --result $scenarioResult `
        --log $scenarioLog
    $scenarioSummary = Get-Content -LiteralPath $scenarioResult -Raw | ConvertFrom-Json
    if ($scenarioSummary.result -ne "passed") {
        throw "The real short-duration scenario did not report passed."
    }

    Assert-SourceHygiene

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
    $notificationResource = Join-Path $publish "Microsoft.WindowsAppRuntime.Insights.Resource.dll"
    if (-not (Test-Path -LiteralPath $notificationResource -PathType Leaf)) {
        throw "Publish output is missing Microsoft.WindowsAppRuntime.Insights.Resource.dll required by unpackaged notifications."
    }

    $uiSmokeArguments = @(
        "-NoProfile",
        "-File",
        "scripts/ui-smoke.ps1",
        "-AppPath",
        $appPath,
        "-OutputDirectory",
        $uiSmoke
    )
    Invoke-Checked -FilePath pwsh -Arguments $uiSmokeArguments
    $uiSummaryPath = Join-Path $uiSmoke "summary.json"
    $uiSummary = Get-Content -LiteralPath $uiSummaryPath -Raw | ConvertFrom-Json

    $summary = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Configuration = $Configuration
        Tests = $testCounters
        Coverage = [ordered]@{
            LinePercent = $lineCoverage
            BranchPercent = $branchCoverage
            File = $coverageFile.FullName
        }
        Scenario = $scenarioSummary
        UiSmoke = $uiSummary
        PublishDirectory = $publish
        EvidenceDirectories = @($results, $scenario, $uiSmoke)
    }
    $summaryPath = Join-Path $artifacts "verification-summary.json"
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8

    Write-Host "`nVerification passed." -ForegroundColor Green
    Write-Host "Tests: $($testCounters.Passed)/$($testCounters.Total) passed, 0 skipped"
    Write-Host "Core coverage: line $lineCoverage%, branch $branchCoverage%"
    Write-Host "Summary: $summaryPath"
}
finally {
    Pop-Location
}
