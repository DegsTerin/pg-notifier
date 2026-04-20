[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "..\config\appsettings.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedConfigPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath $ConfigPath))

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

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Modules\PgNotifier\PgNotifier.psm1") -Force

Start-PgNotifierApplication -ConfigPath $resolvedConfigPath
