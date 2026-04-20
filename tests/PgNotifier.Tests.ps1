Set-StrictMode -Version Latest

Describe "PgNotifier project" {
    It "loads the module manifest" {
        $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\src\Modules\PgNotifier\PgNotifier.psd1"
        $manifest = Test-ModuleManifest -Path $manifestPath
        $manifest.Name | Should -Be "PgNotifier"
    }

    It "contains a valid sample configuration" {
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\examples\appsettings.sample.json"
        { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}
