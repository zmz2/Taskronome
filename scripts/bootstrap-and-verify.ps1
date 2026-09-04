[CmdletBinding()]
param(
    [switch]$Package,
    [string]$Configuration = "Release",
    [string]$Version = "1.0.0",
    [double]$MinimumLineCoverage = 85.0,
    [double]$MinimumBranchCoverage = 75.0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

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

function Find-Python {
    $commands = @(
        (Get-Command py -ErrorAction SilentlyContinue),
        (Get-Command python.exe -ErrorAction SilentlyContinue),
        (Get-Command python3.exe -ErrorAction SilentlyContinue)
    ) | Where-Object { $null -ne $_ }

    $localPython = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path -LiteralPath $localPython) {
        $commands += Get-ChildItem -LiteralPath $localPython -Filter python.exe -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
    }

    foreach ($command in $commands) {
        $executable = if ($command.PSObject.Properties.Name -contains "Source") { $command.Source } else { $command.FullName }
        if ([string]::IsNullOrWhiteSpace($executable)) {
            continue
        }

        try {
            $version = & $executable --version 2>&1 | Out-String
            if ($version -match "Python\s+\d+\.\d+") {
                return $executable
            }
        }
        catch {
            continue
        }
    }

    throw "Python 3 is required for scripts/assistant-source-audit.py. Install Python and rerun."
}

Push-Location $repoRoot
try {
    $dotnetVersion = (& dotnet --version).Trim()
    if ($dotnetVersion -notmatch '^10\.') {
        throw ".NET SDK 10 is required by global.json; detected $dotnetVersion."
    }

    $python = Find-Python
    $auditPath = Join-Path $repoRoot "artifacts\source-audit.json"
    New-Item -ItemType Directory -Path (Split-Path $auditPath) -Force | Out-Null
    Invoke-Checked $python scripts/assistant-source-audit.py --output $auditPath
    $verifyArguments = @(
        "-NoProfile",
        "-File",
        "scripts/verify.ps1",
        "-Configuration",
        $Configuration,
        "-MinimumLineCoverage",
        $MinimumLineCoverage,
        "-MinimumBranchCoverage",
        $MinimumBranchCoverage
    )
    Invoke-Checked -FilePath pwsh -Arguments $verifyArguments

    if ($Package) {
        $packageArguments = @(
            "-NoProfile",
            "-File",
            "scripts/package.ps1",
            "-Configuration",
            $Configuration,
            "-Version",
            $Version
        )
        Invoke-Checked -FilePath pwsh -Arguments $packageArguments
    }

    Write-Host "`nTaskronome bootstrap and verification completed." -ForegroundColor Green
}
finally {
    Pop-Location
}
