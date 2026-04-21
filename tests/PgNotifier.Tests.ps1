Set-StrictMode -Version Latest

Describe "PgNotifier project" {
    It "loads the module manifest" {
        $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\Modules\PgNotifier\PgNotifier.psd1"
        $manifest = Test-ModuleManifest -Path $manifestPath
        $manifest.Name | Should Be "PgNotifier"
    }

    It "contains a valid sample configuration" {
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\examples\appsettings.sample.json"
        { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } | Should Not Throw
    }

    It "loads JSON configuration with array values without recursion errors" {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\Modules\PgNotifier\PgNotifier.psm1"
        Import-Module $modulePath -Force

        $tempConfigPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("pgnotifier-test-{0}.json" -f [guid]::NewGuid())
        @'
{
  "logging": {
    "logPath": "logs\\test.log"
  },
  "pgIsReady": {
    "path": "pg_isready.exe",
    "extraArguments": []
  },
  "instances": [
    {
      "name": "PostgreSQL 18",
      "serviceName": "postgresql-x64-18",
      "hostName": "localhost",
      "port": 5432,
      "postgresExe": "C:\\Program Files\\PostgreSQL\\18\\bin\\postgres.exe"
    }
  ]
}
'@ | Set-Content -LiteralPath $tempConfigPath -Encoding UTF8

        try {
            $module = Get-Module PgNotifier
            $configuration = & $module { param($Path) Get-JsonConfiguration -Path $Path } $tempConfigPath
            $configuration.Logging.LogPath | Should Match "logs\\test\.log$"
            $configuration.Instances.Count | Should Be 1
        }
        finally {
            Remove-Item -LiteralPath $tempConfigPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "resolves pg_isready from a standard PostgreSQL installation even when it is not on PATH" {
        $expectedPath = "C:\Program Files\PostgreSQL\18\bin\pg_isready.exe"
        if (-not (Test-Path -LiteralPath $expectedPath)) {
            return
        }

        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\Modules\PgNotifier\PgNotifier.psm1"
        Import-Module $modulePath -Force

        $configuration = [pscustomobject]@{
            ConfigPath = "C:\ProgramData\PgNotifier\appsettings.json"
            PgIsReady  = [pscustomobject]@{
                Path = "pg_isready.exe"
            }
            Instances  = @(
                [pscustomobject]@{
                    PostgresExe = "C:\Program Files\PostgreSQL\18\bin\postgres.exe"
                }
            )
        }

        $module = Get-Module PgNotifier
        $resolvedPath = & $module { param($Config) Resolve-PgIsReadyPath -Configuration $Config } $configuration
        $resolvedPath | Should Be $expectedPath
    }

    It "expands LocalAppData variables in configured log paths" {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\Modules\PgNotifier\PgNotifier.psm1"
        Import-Module $modulePath -Force

        $module = Get-Module PgNotifier
        $resolvedPath = & $module { Resolve-ConfiguredPath -Candidate "%LocalAppData%\PgNotifier\logs\pgnotifier.log" -ConfigPath "C:\ProgramData\PgNotifier\appsettings.json" }
        $resolvedPath | Should Match "PgNotifier\\logs\\pgnotifier\.log$"
    }
}
