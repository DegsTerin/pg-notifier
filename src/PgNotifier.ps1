[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "..\config\appsettings.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-PgNotifierConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputPath
    )

    if ([System.IO.Path]::IsPathRooted($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }

    $basePath = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($basePath)) {
        $basePath = Split-Path -Path $PSCommandPath -Parent
    }

    if ([string]::IsNullOrWhiteSpace($basePath)) {
        $basePath = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $InputPath))
}

$resolvedConfigPath = Resolve-PgNotifierConfigPath -InputPath $ConfigPath

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    $powershellExe = (Get-Process -Id $PID).Path
    $arguments = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-STA"
        "-File", ('"{0}"' -f $PSCommandPath)
        "-ConfigPath", ('"{0}"' -f $resolvedConfigPath)
    )

    Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    exit 0
}

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\PgNotifier\PgNotifier.psm1"
Import-Module $modulePath -Force

Start-PgNotifierApplication -ConfigPath $resolvedConfigPath
