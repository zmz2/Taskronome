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
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version such as 1.0.0."
}

Push-Location $repoRoot
try {
    Remove-Item -LiteralPath $publish -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $publish, $dist -Force | Out-Null

    Invoke-Checked dotnet restore src/Taskronome.App/Taskronome.App.csproj `
        --runtime win-x64 `
        --force-evaluate
    Invoke-Checked dotnet publish src/Taskronome.App/Taskronome.App.csproj `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        --no-restore `
        -p:Version=$Version `
        --output $publish

    foreach ($file in @("README.md", "LICENSE", "THIRD-PARTY-NOTICES.md", "PRIVACY.md")) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $publish -Force
    }

    $portableName = "Taskronome-$Version-win-x64-portable.zip"
    $portablePath = Join-Path $dist $portableName
    Compress-Archive -Path (Join-Path $publish "*") -DestinationPath $portablePath -CompressionLevel Optimal

    $iscc = Find-Iscc
    if ($null -eq $iscc) {
        $choco = Get-Command choco -ErrorAction SilentlyContinue
        if ($null -eq $choco) {
            throw "Inno Setup was not found and Chocolatey is unavailable. Install Inno Setup 7 and rerun."
        }

        Invoke-Checked choco install innosetup -y --no-progress
        $iscc = Find-Iscc
    }

    if ($null -eq $iscc) {
        throw "Inno Setup installation completed, but ISCC.exe was not found."
    }

    Invoke-Checked $iscc `
        "/DMyAppVersion=$Version" `
        "/DSourceDir=$publish" `
        "/DOutputDir=$dist" `
        $installerScript

    $installerPath = Get-ChildItem -LiteralPath $dist -Filter "Taskronome-Setup-*-win-x64.exe" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $installerPath) {
        throw "Inno Setup did not produce the expected installer."
    }

    $packageFiles = @(
        Get-Item -LiteralPath $portablePath,
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
    Get-Content -LiteralPath $checksumPath
}
finally {
    Pop-Location
}
