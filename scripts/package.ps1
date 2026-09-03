[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $repoRoot "artifacts"
$publish = Join-Path $artifacts "publish\win-x64"
$dist = Join-Path $artifacts "dist"
$installerScript = Join-Path $repoRoot "installer\Taskronome.iss"

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

function Find-Iscc {
    $candidates = @(
        (Get-Command iscc.exe -ErrorAction SilentlyContinue),
        (Join-Path $env:ProgramFiles "Inno Setup 7\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 7\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 7\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    )

    foreach ($candidate in $candidates) {
        $path = if ($candidate -is [System.Management.Automation.CommandInfo]) { $candidate.Source } else { [string]$candidate }
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

function Assert-PortableZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $devUsersPath = "C:" + "/Users/"
        $taskronomeDevPath = "D:" + "/VibeCodingTools"
        foreach ($entry in $archive.Entries) {
            $normalized = $entry.FullName.Replace("\", "/")
            if ($normalized -match "(^|/)(src|tests|artifacts|bin|obj)(/|$)" -or
                $normalized -match "(^|/)(data\.json|data\.json\.bak|logs)(/|$)" -or
                $normalized -match "[A-Za-z]:/" -or
                $normalized.Contains($taskronomeDevPath) -or
                $normalized.Contains($devUsersPath)) {
                throw "Portable package contains a development or user-data path: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version such as 1.0.0."
}

Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    foreach ($directory in @($publish, $dist)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Invoke-Checked dotnet restore Taskronome.sln --locked-mode
    Invoke-Checked dotnet publish src/Taskronome.App/Taskronome.App.csproj `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        --no-restore `
        "-p:Version=$Version" `
        --output $publish

    foreach ($file in @("README.md", "LICENSE", "THIRD-PARTY-NOTICES.md", "PRIVACY.md")) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $publish -Force
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs\MANUAL_TEST_CHECKLIST.md") -Destination $publish -Force

    $portableName = "Taskronome-$Version-win-x64-portable.zip"
    $portablePath = Join-Path $dist $portableName
    Compress-Archive -Path (Join-Path $publish "*") -DestinationPath $portablePath -CompressionLevel Optimal
    Assert-PortableZip -ZipPath $portablePath

    $iscc = Find-Iscc
    if ($null -eq $iscc) {
        $choco = Get-Command choco.exe -ErrorAction SilentlyContinue
        if ($null -ne $choco) {
            Invoke-Checked $choco.Source install innosetup -y --no-progress
            $iscc = Find-Iscc
        }
    }
    if ($null -eq $iscc) {
        throw "Inno Setup was not found. Install Inno Setup 6 or 7, then rerun package.ps1."
    }

    Invoke-Checked $iscc `
        "/DMyAppVersion=$Version" `
        "/DSourceDir=$publish" `
        "/DOutputDir=$dist" `
        $installerScript

    $installerPath = Get-Item -LiteralPath (Join-Path $dist "Taskronome-$Version-win-x64-setup.exe") -ErrorAction SilentlyContinue
    if ($null -eq $installerPath) {
        throw "Inno Setup did not produce Taskronome-$Version-win-x64-setup.exe."
    }

    $packageFiles = @(
        (Get-Item -LiteralPath $portablePath),
        $installerPath
    )
    $checksumPath = Join-Path $dist "SHA256SUMS.txt"
    $checksumLines = foreach ($file in $packageFiles) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
    }
    $checksumLines | Set-Content -LiteralPath $checksumPath -Encoding ascii

    $manifest = [ordered]@{
        Version = $Version
        GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Packages = foreach ($file in $packageFiles) {
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            [ordered]@{
                Name = $file.Name
                Bytes = $file.Length
                Sha256 = $hash.Hash.ToLowerInvariant()
            }
        }
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dist "package-manifest.json") -Encoding utf8

    Write-Host "`nPackaging passed." -ForegroundColor Green
    Get-ChildItem -LiteralPath $dist -File | Select-Object Name,Length | Format-Table -AutoSize
    Get-Content -LiteralPath $checksumPath
}
finally {
    Pop-Location
}
