[CmdletBinding()]
param(
    [string]$Version = "1.0.0",
    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Path $PSScriptRoot -Parent
$srcDir = Join-Path -Path $root -ChildPath "src"
$configDir = Join-Path -Path $root -ChildPath "config"
$distDir = Join-Path -Path $root -ChildPath "dist"
$packageDir = Join-Path -Path $distDir -ChildPath ("PgNotifier-{0}" -f $Version)
$exePath = Join-Path -Path $packageDir -ChildPath "PgNotifier.exe"
$scriptPath = Join-Path -Path $srcDir -ChildPath "PgNotifier.ps1"
$configTargetDir = Join-Path -Path $packageDir -ChildPath "config"
$readmePath = Join-Path -Path $root -ChildPath "README.md"

if (Test-Path -LiteralPath $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}

New-Item -Path $packageDir -ItemType Directory -Force | Out-Null
New-Item -Path $configTargetDir -ItemType Directory -Force | Out-Null

$ps2exe = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $ps2exe) {
    throw "The ps2exe module is required. Install it with: Install-Module ps2exe -Scope CurrentUser"
}

Import-Module $ps2exe -Force

Invoke-PS2EXE `
    -InputFile $scriptPath `
    -OutputFile $exePath `
    -NoConsole `
    -STA `
    -Title "PgNotifier" `
    -Description "Professional PostgreSQL tray monitor for Windows" `
    -Product "PgNotifier" `
    -Company "Open Source" `
    -Version $Version `
    -RequireAdmin:$false

Copy-Item -Path (Join-Path -Path $configDir -ChildPath "appsettings.json") -Destination (Join-Path -Path $configTargetDir -ChildPath "appsettings.json") -Force
Copy-Item -Path $readmePath -Destination (Join-Path -Path $packageDir -ChildPath "README.md") -Force

if (-not $SkipInstaller) {
    $iscc = Get-Command -Name "ISCC.exe" -ErrorAction SilentlyContinue
    if (-not $iscc) {
        throw "Inno Setup compiler (ISCC.exe) was not found in PATH."
    }

    & $iscc.Source "/DAppVersion=$Version" "/DSourceDir=$packageDir" (Join-Path -Path $root -ChildPath "installer\PgNotifier.iss")
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
}

Write-Host ("Build completed successfully: {0}" -f $packageDir)
