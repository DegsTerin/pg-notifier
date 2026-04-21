[CmdletBinding()]
param(
    [string]$Version = "1.0.10",
    [switch]$SkipInstaller,
    [switch]$InstallerOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($SkipInstaller -and $InstallerOnly) {
    throw "SkipInstaller and InstallerOnly cannot be used together."
}

$root = Split-Path -Path $PSScriptRoot -Parent
$srcDir = Join-Path -Path $root -ChildPath "src"
$configDir = Join-Path -Path $root -ChildPath "config"
$distDir = Join-Path -Path $root -ChildPath "dist"
$packagesDir = Join-Path -Path $distDir -ChildPath "packages"
$installersDir = Join-Path -Path $distDir -ChildPath "installers"
$packageDir = Join-Path -Path $packagesDir -ChildPath ("PgNotifier-{0}" -f $Version)
$exePath = Join-Path -Path $packageDir -ChildPath "PgNotifier.exe"
$scriptPath = Join-Path -Path $srcDir -ChildPath "PgNotifier.ps1"
$modulePath = Join-Path -Path $srcDir -ChildPath "Modules\PgNotifier\PgNotifier.psm1"
$configTargetDir = Join-Path -Path $packageDir -ChildPath "config"
$readmePath = Join-Path -Path $root -ChildPath "README.md"
$bundleScriptPath = Join-Path -Path $distDir -ChildPath "PgNotifier.bundle.ps1"

if (Test-Path -LiteralPath $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}

New-Item -Path $installersDir -ItemType Directory -Force | Out-Null
if (-not $InstallerOnly) {
    New-Item -Path $packagesDir -ItemType Directory -Force | Out-Null
    New-Item -Path $packageDir -ItemType Directory -Force | Out-Null
    New-Item -Path $configTargetDir -ItemType Directory -Force | Out-Null

    $moduleContent = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    $moduleContent = $moduleContent -replace '(?ms)^\s*if\s*\(\$ExecutionContext\.SessionState\.Module\)\s*\{\s*Export-ModuleMember\s+-Function\s+Start-PgNotifierApplication\s*\}\s*$', ''
    $bundleScript = @"
[CmdletBinding()]
param(
    [string]`$ConfigPath = (Join-Path -Path `$env:ProgramData -ChildPath "PgNotifier\appsettings.json")
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Resolve-PgNotifierConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]`$InputPath
    )

    if ([System.IO.Path]::IsPathRooted(`$InputPath)) {
        return [System.IO.Path]::GetFullPath(`$InputPath)
    }

    `$basePath = Split-Path -Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent
    if ([string]::IsNullOrWhiteSpace(`$basePath)) {
        `$basePath = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path `$basePath -ChildPath `$InputPath))
}

$moduleContent

`$resolvedConfigPath = Resolve-PgNotifierConfigPath -InputPath `$ConfigPath
Start-PgNotifierApplication -ConfigPath `$resolvedConfigPath
"@

if (Test-Path -LiteralPath $bundleScriptPath) {
    Remove-Item -LiteralPath $bundleScriptPath -Force
}

    Set-Content -LiteralPath $bundleScriptPath -Value $bundleScript -Encoding UTF8

    $ps2exe = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $ps2exe) {
        throw "The ps2exe module is required. Install it with: Install-Module ps2exe -Scope CurrentUser"
    }

    Import-Module $ps2exe -Force

    Invoke-PS2EXE `
        -InputFile $bundleScriptPath `
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

    if (Test-Path -LiteralPath $bundleScriptPath) {
        Remove-Item -LiteralPath $bundleScriptPath -Force
    }
}

$isccPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

if (-not $SkipInstaller) {
    if (-not (Test-Path $isccPath)) {
        Write-Warning "Inno Setup não encontrado em: $isccPath"
        if ($InstallerOnly) {
            throw "InstallerOnly foi solicitado, mas Inno Setup não está instalado."
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $packageDir)) {
            throw "Package directory not found. Generate the package first."
        }

        & $isccPath "/DAppVersion=$Version" "/DSourceDir=$packageDir" "/DOutputDir=$installersDir" (Join-Path -Path $root -ChildPath "packaging\inno\PgNotifier.iss")

        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup falhou com exit code $LASTEXITCODE."
        }
    }
}

if (Test-Path -LiteralPath $packageDir) {
    Write-Host ("Package build completed successfully: {0}" -f $packageDir)
}

if (Test-Path -LiteralPath (Join-Path -Path $installersDir -ChildPath ("PgNotifier-Setup-{0}.exe" -f $Version))) {
    Write-Host ("Installer build completed successfully: {0}" -f (Join-Path -Path $installersDir -ChildPath ("PgNotifier-Setup-{0}.exe" -f $Version)))
}
