Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

function Get-PgNotifierUserDataRoot {
    [CmdletBinding()]
    param()

    return Join-Path -Path $env:LocalAppData -ChildPath "PgNotifier"
}

function Get-DefaultLogPath {
    [CmdletBinding()]
    param(
        [string]$FileName = "pgnotifier.log"
    )

    return Join-Path -Path (Get-PgNotifierUserDataRoot) -ChildPath ("logs\{0}" -f $FileName)
}

function Test-LogPathWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        $fileMode = [System.IO.FileMode]::Append
        $fileAccess = [System.IO.FileAccess]::Write
        $fileShare = [System.IO.FileShare]::ReadWrite
        $stream = [System.IO.File]::Open($Path, $fileMode, $fileAccess, $fileShare)
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-WritableLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CandidatePath,

        [string]$FallbackFileName = "pgnotifier.log"
    )

    if (-not [string]::IsNullOrWhiteSpace($CandidatePath) -and (Test-LogPathWritable -Path $CandidatePath)) {
        return [pscustomobject]@{
            Path          = $CandidatePath
            UsedFallback  = $false
            OriginalPath  = $CandidatePath
        }
    }

    $fallbackPath = Get-DefaultLogPath -FileName $FallbackFileName
    $null = Test-LogPathWritable -Path $fallbackPath

    return [pscustomobject]@{
        Path          = $fallbackPath
        UsedFallback  = $true
        OriginalPath  = $CandidatePath
    }
}

function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $resolvedLogPath = Resolve-WritableLogPath -CandidatePath $Path -FallbackFileName ([System.IO.Path]::GetFileName($Path))
    $directory = Split-Path -Path $resolvedLogPath.Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $resolvedLogPath.Path -Value $line -Encoding UTF8
}

function Write-AppLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    try {
        $resolvedLogPath = Resolve-WritableLogPath -CandidatePath $Context.Configuration.Logging.LogPath -FallbackFileName "pgnotifier.log"
        if ($resolvedLogPath.Path -ne $Context.Configuration.Logging.LogPath) {
            $Context.Configuration.Logging.LogPath = $resolvedLogPath.Path
        }

        Write-LogEntry -Path $Context.Configuration.Logging.LogPath -Message $Message -Level $Level
    }
    catch {
        try {
            Write-LogEntry -Path (Get-DefaultLogPath -FileName "pgnotifier-fallback.log") -Message ("Failed to write configured log entry: {0}" -f $_.Exception.Message) -Level "ERROR"
            Write-LogEntry -Path (Get-DefaultLogPath -FileName "pgnotifier-fallback.log") -Message $Message -Level $Level
        }
        catch {
        }
    }
}

function Set-NotifyTextSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.NotifyIcon]$NotifyIcon,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $safeText = $Text
    if ($safeText.Length -gt 63) {
        $safeText = $safeText.Substring(0, 63)
    }

    $NotifyIcon.Text = $safeText
}

function ConvertTo-ObjectArray {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    return @($InputObject)
}

function Get-HashtableValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Hashtable
    )

    $values = @()
    foreach ($entry in $Hashtable.GetEnumerator()) {
        $values += ,$entry.Value
    }

    return $values
}

function Get-SafeCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return 0
    }

    if ($InputObject -is [System.Collections.ICollection]) {
        return $InputObject.Count
    }

    if ($InputObject.PSObject.Properties.Name -contains "Count") {
        try {
            return [int]$InputObject.Count
        }
        catch {
        }
    }

    return @( $InputObject ).Count
}

function Resolve-ExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Candidate,

        [string[]]$BasePaths = @(),

        [string[]]$AdditionalCandidates = @()
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $probePaths = New-Object System.Collections.Generic.List[string]

    $addProbe = {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        if (-not $probePaths.Contains($Path)) {
            [void]$probePaths.Add($Path)
        }
    }

    & $addProbe $Candidate

    if (-not [System.IO.Path]::IsPathRooted($Candidate)) {
        foreach ($basePath in @($BasePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try {
                & $addProbe ([System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $Candidate)))
            }
            catch {
            }
        }
    }

    foreach ($extraCandidate in @($AdditionalCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        & $addProbe $extraCandidate
    }

    foreach ($probePath in $probePaths) {
        if (Test-Path -LiteralPath $probePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $probePath).Path
        }
    }

    $command = Get-Command -Name $Candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Resolve-ConfiguredPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Candidate,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $Candidate
    }

    $expandedCandidate = [System.Environment]::ExpandEnvironmentVariables($Candidate)

    if ([System.IO.Path]::IsPathRooted($expandedCandidate)) {
        return [System.IO.Path]::GetFullPath($expandedCandidate)
    }

    $configDirectory = Split-Path -Path $ConfigPath -Parent
    if ([string]::IsNullOrWhiteSpace($configDirectory)) {
        $configDirectory = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $configDirectory -ChildPath $expandedCandidate))
}

function Get-PostgreSqlBinDirectoryCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Configuration
    )

    $directories = New-Object System.Collections.Generic.List[string]

    $addDirectory = {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        if (-not $directories.Contains($Path) -and (Test-Path -LiteralPath $Path -PathType Container)) {
            [void]$directories.Add($Path)
        }
    }

    foreach ($instance in @($Configuration.Instances)) {
        if ([string]::IsNullOrWhiteSpace($instance.PostgresExe)) {
            continue
        }

        try {
            $resolvedPostgresExe = Resolve-ConfiguredPath -Candidate $instance.PostgresExe -ConfigPath $Configuration.ConfigPath
            if (Test-Path -LiteralPath $resolvedPostgresExe -PathType Leaf) {
                & $addDirectory (Split-Path -Path $resolvedPostgresExe -Parent)
            }
        }
        catch {
        }
    }

    $standardRoots = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "PostgreSQL"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "PostgreSQL")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $standardRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            & $addDirectory (Join-Path -Path $versionDirectory.FullName -ChildPath "bin")
        }
    }

    return @($directories)
}

function Resolve-PgIsReadyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Configuration
    )

    $configuredCandidate = $Configuration.PgIsReady.Path
    if ([string]::IsNullOrWhiteSpace($configuredCandidate)) {
        $configuredCandidate = "pg_isready.exe"
    }

    $configDirectory = Split-Path -Path $Configuration.ConfigPath -Parent
    $additionalCandidates = @()
    foreach ($binDirectory in (Get-PostgreSqlBinDirectoryCandidates -Configuration $Configuration)) {
        $additionalCandidates += (Join-Path -Path $binDirectory -ChildPath "pg_isready.exe")
        if (-not [System.IO.Path]::IsPathRooted($configuredCandidate)) {
            $additionalCandidates += (Join-Path -Path $binDirectory -ChildPath $configuredCandidate)
        }
    }

    return Resolve-ExecutablePath -Candidate $configuredCandidate -BasePaths @($configDirectory) -AdditionalCandidates $additionalCandidates
}

function Get-DefaultConfigPath {
    [CmdletBinding()]
    param()

    return Join-Path -Path $env:ProgramData -ChildPath "PgNotifier\appsettings.json"
}

function New-DefaultConfiguration {
    [CmdletBinding()]
    param()

    return @{
        application = @{
            displayName        = "PgNotifier"
            intervalSeconds    = 5
            restartBadgeSeconds = 10
            startMinimized     = $true
            autoDiscover       = $true
            silentMode         = $false
        }
        logging = @{
            logPath = "%LocalAppData%\\PgNotifier\\logs\\pgnotifier.log"
            level   = "INFO"
        }
        notifications = @{
            enabled                 = $true
            suppressStartupBalloon  = $false
            defaultBalloonTimeoutMs = 3000
        }
        pgIsReady = @{
            path             = "pg_isready.exe"
            timeoutSeconds   = 5
            retryCount       = 2
            retryDelayMs     = 1000
            extraArguments   = @()
        }
        instances = @()
    }
}

function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or
        $InputObject -is [char] -or
        $InputObject -is [bool] -or
        $InputObject -is [byte] -or
        $InputObject -is [int16] -or
        $InputObject -is [int32] -or
        $InputObject -is [int64] -or
        $InputObject -is [decimal] -or
        $InputObject -is [double] -or
        $InputObject -is [single] -or
        $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hashtable = @{}
        foreach ($key in $InputObject.Keys) {
            $hashtable[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }

        return $hashtable
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $collection = @()
        foreach ($item in $InputObject) {
            $collection += ,(ConvertTo-Hashtable -InputObject $item)
        }

        return $collection
    }

    $properties = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' })
    if ((Get-SafeCount -InputObject $properties) -gt 0) {
        $hashtable = @{}
        foreach ($property in $properties) {
            $hashtable[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
        }

        return $hashtable
    }

    return $InputObject
}

function Merge-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,

        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    foreach ($key in $Override.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $null = Merge-Hashtable -Base $Base[$key] -Override $Override[$key]
            continue
        }

        $Base[$key] = $Override[$key]
    }

    return $Base
}

function Get-JsonConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $defaultConfig = New-DefaultConfiguration
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        return ConvertTo-NormalizedConfiguration -Configuration $defaultConfig -ConfigPath $resolvedPath
    }

    $content = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    $parsed = if ([string]::IsNullOrWhiteSpace($content)) { @{} } else { ConvertTo-Hashtable -InputObject (ConvertFrom-Json -InputObject $content) }
    $merged = Merge-Hashtable -Base $defaultConfig -Override $parsed
    return ConvertTo-NormalizedConfiguration -Configuration $merged -ConfigPath $resolvedPath
}

function ConvertTo-NormalizedConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $getObjectPropertyValue = {
        param(
            $Object,
            [string]$Name,
            $DefaultValue = $null
        )

        if ($null -eq $Object) {
            return $DefaultValue
        }

        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $DefaultValue
        }

        return $property.Value
    }

    $instances = @()
    foreach ($instance in @($Configuration.instances)) {
        $instanceName = & $getObjectPropertyValue $instance "name" ""
        $serviceName = & $getObjectPropertyValue $instance "serviceName" ""
        $hostName = & $getObjectPropertyValue $instance "hostName" "localhost"
        $port = & $getObjectPropertyValue $instance "port" 5432
        $postgresExe = & $getObjectPropertyValue $instance "postgresExe" $null
        $enabled = & $getObjectPropertyValue $instance "enabled" $true
        $notificationsEnabled = & $getObjectPropertyValue $instance "notificationsEnabled" $true
        $restartAllowed = & $getObjectPropertyValue $instance "restartAllowed" $true

        $instances += [pscustomobject]@{
            Name                 = [string]$instanceName
            ServiceName          = [string]$serviceName
            HostName             = if ([string]::IsNullOrWhiteSpace([string]$hostName)) { "localhost" } else { [string]$hostName }
            Port                 = [int]$port
            PostgresExe          = if ([string]::IsNullOrWhiteSpace([string]$postgresExe)) { $null } else { Resolve-ConfiguredPath -Candidate ([string]$postgresExe) -ConfigPath $ConfigPath }
            Enabled              = [bool]$enabled
            NotificationsEnabled = [bool]$notificationsEnabled
            RestartAllowed       = [bool]$restartAllowed
        }
    }

    return [pscustomobject]@{
        ConfigPath     = $ConfigPath
        Application    = [pscustomobject]@{
            DisplayName         = [string]$Configuration.application.displayName
            IntervalSeconds     = [int]$Configuration.application.intervalSeconds
            RestartBadgeSeconds = [int]$Configuration.application.restartBadgeSeconds
            StartMinimized      = [bool]$Configuration.application.startMinimized
            AutoDiscover        = [bool]$Configuration.application.autoDiscover
            SilentMode          = [bool]$Configuration.application.silentMode
        }
        Logging        = [pscustomobject]@{
            LogPath = Resolve-ConfiguredPath -Candidate ([string]$Configuration.logging.logPath) -ConfigPath $ConfigPath
            Level   = [string]$Configuration.logging.level
        }
        Notifications  = [pscustomobject]@{
            Enabled                = [bool]$Configuration.notifications.enabled
            SuppressStartupBalloon = [bool]$Configuration.notifications.suppressStartupBalloon
            DefaultBalloonTimeoutMs = [int]$Configuration.notifications.defaultBalloonTimeoutMs
        }
        PgIsReady      = [pscustomobject]@{
            Path           = [string]$Configuration.pgIsReady.path
            TimeoutSeconds = [int]$Configuration.pgIsReady.timeoutSeconds
            RetryCount     = [int]$Configuration.pgIsReady.retryCount
            RetryDelayMs   = [int]$Configuration.pgIsReady.retryDelayMs
            ExtraArguments = @($Configuration.pgIsReady.extraArguments)
        }
        Instances      = $instances
    }
}

function Get-PostgreSqlWindowsServices {
    [CmdletBinding()]
    param()

    $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
        Where-Object {
            $_.Name -match '^postgresql' -or
            $_.DisplayName -match 'PostgreSQL'
        }

    foreach ($service in $services) {
        $port = Get-PostgreSqlServicePort -ServiceName $service.Name

        [pscustomobject]@{
            Name        = $service.Name
            DisplayName = $service.DisplayName
            Port        = $port
            HostName    = "localhost"
            State       = $service.State
            ProcessId   = [int]$service.ProcessId
            PathName    = $service.PathName
        }
    }
}

function Get-PostgreSqlServicePort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    $registryCandidates = @(
        "HKLM:\SOFTWARE\PostgreSQL\Services\$ServiceName",
        "HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Services\$ServiceName"
    )

    foreach ($path in $registryCandidates) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if ($properties.PSObject.Properties.Name -contains "Port") {
                return [int]$properties.Port
            }
        }
        catch {
        }
    }

    return 5432
}

function Resolve-ConfiguredInstances {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Configuration
    )

    $resolved = @()
    $seen = @{}

    foreach ($instance in @($Configuration.Instances)) {
        if (-not $instance.Enabled) {
            continue
        }

        $key = $instance.ServiceName
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $seen.ContainsKey($key)) {
            $resolved += ,$instance
            $seen[$key] = $true
        }
    }

    if ($Configuration.Application.AutoDiscover) {
        foreach ($service in (Get-PostgreSqlWindowsServices)) {
            if ($seen.ContainsKey($service.Name)) {
                continue
            }

            $resolved += ,([pscustomobject]@{
                Name                 = $service.DisplayName
                ServiceName          = $service.Name
                HostName             = $service.HostName
                Port                 = $service.Port
                PostgresExe          = $null
                Enabled              = $true
                NotificationsEnabled = $true
                RestartAllowed       = $true
            })
            $seen[$service.Name] = $true
        }
    }

    return $resolved
}

function Get-ServiceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    $safeName = $ServiceName.Replace("'", "''")
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$safeName'" -ErrorAction Stop
    if ($null -eq $service) {
        return $null
    }

    return [pscustomobject]@{
        Name       = $service.Name
        State      = $service.State
        Status     = $service.Status
        ProcessId  = [int]$service.ProcessId
        DisplayName = $service.DisplayName
    }
}

function Invoke-ProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = [string]::Join(' ', ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }))
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    try {
        [void]$process.Start()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
            }
            catch {
            }

            return [pscustomobject]@{
                TimedOut  = $true
                ExitCode  = -1
                StdOut    = $process.StandardOutput.ReadToEnd()
                StdErr    = $process.StandardError.ReadToEnd()
            }
        }

        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StdOut   = $process.StandardOutput.ReadToEnd()
            StdErr   = $process.StandardError.ReadToEnd()
        }
    }
    catch {
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = -1
            StdOut   = ""
            StdErr   = $_.Exception.Message
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-TcpPortConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $addresses = @()
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($HostName))
    }
    catch {
    }

    if ((Get-SafeCount -InputObject $addresses) -eq 0) {
        $addresses = @($HostName)
    }

    $lastMessage = "TCP connection failed."
    $timedOut = $false

    foreach ($address in $addresses) {
        $client = $null
        $waitHandle = $null

        try {
            if ($address -is [System.Net.IPAddress]) {
                $client = New-Object System.Net.Sockets.TcpClient($address.AddressFamily)
                $asyncResult = $client.BeginConnect($address, $Port, $null, $null)
            }
            else {
                $client = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $client.BeginConnect([string]$address, $Port, $null, $null)
            }

            $waitHandle = $asyncResult.AsyncWaitHandle
            if (-not $waitHandle.WaitOne($TimeoutSeconds * 1000, $false)) {
                $timedOut = $true
                $lastMessage = "TCP connection timed out."
                continue
            }

            $client.EndConnect($asyncResult)
            return [pscustomobject]@{
                IsReady  = $true
                TimedOut = $false
                Message  = "TCP connection established."
                Method   = "tcp"
            }
        }
        catch {
            $lastMessage = $_.Exception.Message
        }
        finally {
            if ($waitHandle) {
                $waitHandle.Dispose()
            }

            if ($client) {
                $client.Dispose()
            }
        }
    }

    return [pscustomobject]@{
        IsReady  = $false
        TimedOut = $timedOut
        Message  = $lastMessage
        Method   = "tcp"
    }
}

function Test-PgInstanceReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [pscustomobject]$Instance
    )

if (-not $Context.PgIsReadyPath) {
    return [pscustomobject]@{
        IsReady  = $false
        TimedOut = $false
        ExitCode = -1
        Message  = "pg_isready not available"
        Attempt  = 0
    }
}

    $arguments = @(
        "-h", $Instance.HostName,
        "-p", [string]$Instance.Port,
        "-t", [string]$Context.Configuration.PgIsReady.TimeoutSeconds
    ) + @($Context.Configuration.PgIsReady.ExtraArguments)

    $attempt = 0
    $result = $null
    do {
        $attempt++
        $result = Invoke-ProcessWithTimeout -FilePath $Context.PgIsReadyPath -Arguments $arguments -TimeoutSeconds $Context.Configuration.PgIsReady.TimeoutSeconds
        if (-not $result.TimedOut -and $result.ExitCode -eq 0) {
            return [pscustomobject]@{
                IsReady   = $true
                TimedOut  = $false
                ExitCode  = $result.ExitCode
                Message   = ($result.StdOut.Trim())
                Attempt   = $attempt
            }
        }

        if ($attempt -le $Context.Configuration.PgIsReady.RetryCount) {
            Start-Sleep -Milliseconds $Context.Configuration.PgIsReady.RetryDelayMs
        }
    } while ($attempt -le $Context.Configuration.PgIsReady.RetryCount)

    return [pscustomobject]@{
        IsReady  = $false
        TimedOut = $result.TimedOut
        ExitCode = $result.ExitCode
        Message  = (($result.StdErr, $result.StdOut) -join ' ').Trim()
        Attempt  = $attempt
    }
}

function New-BaseIcon {
    [CmdletBinding()]
    param()

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $backgroundBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(42, 58, 84))
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

        $graphics.FillEllipse($backgroundBrush, 1, 1, 30, 30)
        $graphics.DrawString("PG", $font, $textBrush, 4, 9)

        $backgroundBrush.Dispose()
        $textBrush.Dispose()
        $font.Dispose()
    }
    finally {
        $graphics.Dispose()
    }

    $handle = $bitmap.GetHicon()
    try {
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        return $icon.Clone()
    }
    finally {
        [NativeMethods]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }
}

function New-BadgedIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Drawing.Icon]$BaseIcon,

        [Parameter(Mandatory)]
        [System.Drawing.Color]$BadgeColor
    )

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.DrawIcon($BaseIcon, 0, 0)

        $badgeBrush = New-Object System.Drawing.SolidBrush($BadgeColor)
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)

        $graphics.FillEllipse($badgeBrush, 20, 20, 10, 10)
        $graphics.DrawEllipse($borderPen, 20, 20, 10, 10)

        $badgeBrush.Dispose()
        $borderPen.Dispose()
    }
    finally {
        $graphics.Dispose()
    }

    $handle = $bitmap.GetHicon()
    try {
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        return $icon.Clone()
    }
    finally {
        [NativeMethods]::DestroyIcon($handle) | Out-Null
        $bitmap.Dispose()
    }
}

function Test-IsHealthyStateKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StateKey
    )

    return $StateKey -in @("UP", "UP_TCP_ONLY")
}

function Show-StateNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [bool]$InstanceNotificationsEnabled
    )

    if (-not $Context.Configuration.Notifications.Enabled -or $Context.Configuration.Application.SilentMode -or -not $InstanceNotificationsEnabled) {
        return
    }

    $Context.NotifyIcon.BalloonTipTitle = $Title
    $Context.NotifyIcon.BalloonTipText = $Message
    $Context.NotifyIcon.ShowBalloonTip($Context.Configuration.Notifications.DefaultBalloonTimeoutMs)
}

function New-InstanceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Instance
    )

    return [pscustomobject]@{
        Name           = $Instance.Name
        ServiceName    = $Instance.ServiceName
        HostName       = $Instance.HostName
        Port           = $Instance.Port
        RestartAllowed = $Instance.RestartAllowed
        NotificationsEnabled = $Instance.NotificationsEnabled
        LastStateKey   = $null
        LastPid        = $null
        YellowUntil    = (Get-Date).AddSeconds(-1)
        LastMessage    = "Waiting for first check."
        CurrentStateKey = "UNKNOWN"
    }
}

function Get-StateDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StateKey
    )

    switch ($StateKey) {
        "UP" { return "Online" }
        "UP_TCP_ONLY" { return "Online (basic check)" }
        "STOPPED" { return "Stopped" }
        "RUNNING_NO_CONN" { return "Running, no connection" }
        "TIMEOUT" { return "Timeout" }
        "MISSING" { return "Service missing" }
        "ERROR" { return "Error" }
        default { return "Checking" }
    }
}

function Get-StateSeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StateKey
    )

    switch ($StateKey) {
        "UP" { return 0 }
        "UP_TCP_ONLY" { return 1 }
        "STOPPED" { return 2 }
        "RUNNING_NO_CONN" { return 2 }
        "TIMEOUT" { return 2 }
        "MISSING" { return 2 }
        "ERROR" { return 2 }
        default { return 1 }
    }
}

function Get-StateSummaryText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    return "{0}: {1}" -f (Get-StateDisplayName -StateKey $State.CurrentStateKey), $State.LastMessage
}

function Get-InstanceMenuCaption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    return "{0} - {1}" -f $State.Name, (Get-StateDisplayName -StateKey $State.CurrentStateKey)
}

function Get-ApplicationStatusSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $states = Get-HashtableValues -Hashtable $Context.InstanceStates
    $total = Get-SafeCount -InputObject $states
    if ($total -eq 0) {
        return [pscustomobject]@{
            Tooltip = "{0}: no PostgreSQL instances" -f $Context.Configuration.Application.DisplayName
            Header  = "No PostgreSQL instances detected"
        }
    }

    $online = 0
    $attention = 0
    foreach ($state in $states) {
        if (Test-IsHealthyStateKey -StateKey $state.CurrentStateKey) {
            $online++
        }
        else {
            $attention++
        }
    }

    return [pscustomobject]@{
        Tooltip = "{0}: {1} online, {2} attention" -f $Context.Configuration.Application.DisplayName, $online, $attention
        Header  = "{0} online, {1} need attention" -f $online, $attention
    }
}

function Invoke-ManualRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    try {
        Invoke-HealthCheckCycle -Context $Context
        Write-AppLog -Context $Context -Message "Manual refresh completed."
    }
    catch {
        Write-AppLog -Context $Context -Message ("Manual refresh failed: {0}" -f $_.Exception.Message) -Level "ERROR"
        Show-StateNotification -Context $Context -Title "PgNotifier error" -Message "Manual refresh failed. Check the log for details." -InstanceNotificationsEnabled $true
    }
}

function Open-WindowsServicesConsole {
    [CmdletBinding()]
    param()

    Start-Process -FilePath "services.msc" | Out-Null
}

function Restart-TrackedService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    try {
        Restart-Service -Name $State.ServiceName -Force -ErrorAction Stop
        Write-AppLog -Context $Context -Message ("Manual restart requested for service {0}" -f $State.ServiceName)
        Show-StateNotification -Context $Context -Title "PgNotifier" -Message ("Restart requested for {0}" -f $State.Name) -InstanceNotificationsEnabled $State.NotificationsEnabled
    }
    catch {
        Write-AppLog -Context $Context -Message ("Failed to restart service {0}: {1}" -f $State.ServiceName, $_.Exception.Message) -Level "ERROR"
        Show-StateNotification -Context $Context -Title "PgNotifier error" -Message ("Failed to restart {0}. See log for details." -f $State.Name) -InstanceNotificationsEnabled $true
    }
}

function Open-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $path = $Context.Configuration.Logging.LogPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-AppLog -Context $Context -Message "Log file did not exist. Creating it before opening."
        New-Item -Path $path -ItemType File -Force | Out-Null
    }

    Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $path) | Out-Null
}

function Open-ConfigurationFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $path = $Context.Configuration.ConfigPath
    $directory = Split-Path -Path $path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $path)) {
        $template = New-DefaultConfiguration | ConvertTo-Json -Depth 10
        Set-Content -Path $path -Value $template -Encoding UTF8
    }

    Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $path) | Out-Null
}

function Update-NotifyIconFromStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $now = Get-Date
    $states = Get-HashtableValues -Hashtable $Context.InstanceStates

    if ((Get-SafeCount -InputObject $states) -eq 0) {
        $Context.NotifyIcon.Icon = $Context.Icons.Red
        Set-NotifyTextSafe -NotifyIcon $Context.NotifyIcon -Text ("{0}: no PostgreSQL instances found" -f $Context.Configuration.Application.DisplayName)
        return
    }

    $hasYellow = $false
    $hasRed = $false
    foreach ($state in $states) {
        if ($now -lt $state.YellowUntil) {
            $hasYellow = $true
            break
        }

        if (-not (Test-IsHealthyStateKey -StateKey $state.CurrentStateKey)) {
            $hasRed = $true
        }
    }

    if ($hasYellow) {
        $Context.NotifyIcon.Icon = $Context.Icons.Yellow
    }
    elseif ($hasRed) {
        $Context.NotifyIcon.Icon = $Context.Icons.Red
    }
    else {
        $Context.NotifyIcon.Icon = $Context.Icons.Green
    }

    $summary = Get-ApplicationStatusSummary -Context $Context
    Set-NotifyTextSafe -NotifyIcon $Context.NotifyIcon -Text $summary.Tooltip
}

function Update-MenuCaptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    foreach ($serviceName in $Context.InstanceStates.Keys) {
        $state = $Context.InstanceStates[$serviceName]
        if ($Context.MenuMap.ContainsKey($serviceName)) {
            $Context.MenuMap[$serviceName].StatusItem.Text = Get-InstanceMenuCaption -State $state
            $Context.MenuMap[$serviceName].DetailsItem.Text = Get-StateSummaryText -State $state
        }
    }

    $Context.MenuItems.SilentMode.Checked = [bool]$Context.Configuration.Application.SilentMode
    $Context.MenuItems.Header.Text = (Get-ApplicationStatusSummary -Context $Context).Header
}

function Test-AndUpdateInstanceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $restartDetected = $false
    $snapshot = $null

    try {
        $snapshot = Get-ServiceSnapshot -ServiceName $State.ServiceName
    }
    catch {
        $snapshot = $null
        Write-AppLog -Context $Context -Message ("Service lookup failed for {0}: {1}" -f $State.ServiceName, $_.Exception.Message) -Level "WARN"
    }

    if ($null -eq $snapshot) {
        $newStateKey = "MISSING"
        $message = "Service not found."
    }
    else {
        $isRunning = $snapshot.State -eq "Running"
        $pgReady = $null
        $tcpCheck = $null
        if ($isRunning) {
            if ($Context.PgIsReadyPath) {
                $pgReady = Test-PgInstanceReady -Context $Context -Instance $State
            }
            else {
                $tcpCheck = Test-TcpPortConnectivity -HostName $State.HostName -Port $State.Port -TimeoutSeconds $Context.Configuration.PgIsReady.TimeoutSeconds
            }
        }

        if ($isRunning -and $State.LastPid -and $snapshot.ProcessId -and $State.LastPid -ne $snapshot.ProcessId) {
            $restartDetected = $true
            $State.YellowUntil = (Get-Date).AddSeconds($Context.Configuration.Application.RestartBadgeSeconds)
            $State.LastMessage = "PostgreSQL restarted. PID changed from $($State.LastPid) to $($snapshot.ProcessId)."
            Show-StateNotification -Context $Context -Title "PostgreSQL restarted" -Message ("{0}: PID {1} -> {2}" -f $State.Name, $State.LastPid, $snapshot.ProcessId) -InstanceNotificationsEnabled $State.NotificationsEnabled
            Write-AppLog -Context $Context -Message ("Restart detected for {0}. PID {1} -> {2}" -f $State.ServiceName, $State.LastPid, $snapshot.ProcessId) -Level "WARN"
        }

        if (-not $isRunning) {
            $newStateKey = "STOPPED"
            $message = "Service is stopped."
        }
        elseif (-not $Context.PgIsReadyPath) {
            if ($tcpCheck.IsReady) {
                $newStateKey = "UP_TCP_ONLY"
                $message = "TCP connectivity confirmed on $($State.HostName):$($State.Port) without pg_isready."
            }
            elseif ($tcpCheck.TimedOut) {
                $newStateKey = "TIMEOUT"
                $message = "TCP connectivity test timed out after $($Context.Configuration.PgIsReady.TimeoutSeconds)s."
            }
            else {
                $newStateKey = "RUNNING_NO_CONN"
                $message = if ($tcpCheck.Message) { $tcpCheck.Message } else { "Service is running but TCP connectivity failed." }
            }
        }
        elseif ($pgReady.IsReady) {
            $newStateKey = "UP"
            $message = "Accepting connections on $($State.HostName):$($State.Port)."
        }
        elseif ($pgReady.TimedOut) {
            $newStateKey = "TIMEOUT"
            $message = "pg_isready timed out after $($Context.Configuration.PgIsReady.TimeoutSeconds)s."
        }
        else {
            $newStateKey = "RUNNING_NO_CONN"
            $message = if ($pgReady.Message) { $pgReady.Message } else { "Service is running but not accepting connections." }
        }

        if ($snapshot.ProcessId -gt 0) {
            $State.LastPid = $snapshot.ProcessId
        }
    }

    $State.CurrentStateKey = $newStateKey
    $State.LastMessage = $message

    if ($State.LastStateKey -ne $newStateKey) {
        $title = switch ($newStateKey) {
            "UP" { "PostgreSQL online" }
            "UP_TCP_ONLY" { "PostgreSQL online (degraded)" }
            "STOPPED" { "PostgreSQL stopped" }
            "RUNNING_NO_CONN" { "PostgreSQL no connection" }
            "TIMEOUT" { "PostgreSQL timeout" }
            "MISSING" { "PostgreSQL service missing" }
            default { "PostgreSQL state changed" }
        }

        Show-StateNotification -Context $Context -Title $title -Message ("{0}: {1}" -f $State.Name, $message) -InstanceNotificationsEnabled $State.NotificationsEnabled
        Write-AppLog -Context $Context -Message ("State change for {0}: {1} - {2}" -f $State.ServiceName, $newStateKey, $message)
        $State.LastStateKey = $newStateKey
    }
}

function New-ApplicationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Configuration,

        [AllowNull()]
        [string]$PgIsReadyPath
    )

    $baseIcon = New-BaseIcon
    $greenIcon = New-BadgedIcon -BaseIcon $baseIcon -BadgeColor ([System.Drawing.Color]::LimeGreen)
    $redIcon = New-BadgedIcon -BaseIcon $baseIcon -BadgeColor ([System.Drawing.Color]::Crimson)
    $yellowIcon = New-BadgedIcon -BaseIcon $baseIcon -BadgeColor ([System.Drawing.Color]::Gold)
    $baseIcon.Dispose()

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Visible = $true
    $notifyIcon.Icon = $redIcon
    Set-NotifyTextSafe -NotifyIcon $notifyIcon -Text $Configuration.Application.DisplayName

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $menuItems = [ordered]@{
        Header     = New-Object System.Windows.Forms.ToolStripMenuItem($Configuration.Application.DisplayName)
        Instances  = New-Object System.Windows.Forms.ToolStripMenuItem("Instances")
        Separator1 = New-Object System.Windows.Forms.ToolStripSeparator
        Refresh    = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh now")
        Services   = New-Object System.Windows.Forms.ToolStripMenuItem("Open Services console")
        SilentMode = New-Object System.Windows.Forms.ToolStripMenuItem("Silent mode")
        OpenLog    = New-Object System.Windows.Forms.ToolStripMenuItem("Open log")
        OpenConfig = New-Object System.Windows.Forms.ToolStripMenuItem("Open config")
        Reload     = New-Object System.Windows.Forms.ToolStripMenuItem("Reload configuration")
        Separator2 = New-Object System.Windows.Forms.ToolStripSeparator
        Exit       = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    }

    $menuItems.Header.Enabled = $false
    $menuItems.SilentMode.CheckOnClick = $true
    $menuItems.SilentMode.Checked = [bool]$Configuration.Application.SilentMode

    foreach ($item in $menuItems.Values) {
        [void]$contextMenu.Items.Add($item)
    }

    $notifyIcon.ContextMenuStrip = $contextMenu

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(1000, ($Configuration.Application.IntervalSeconds * 1000))

    return @{
        Configuration = $Configuration
        PgIsReadyPath = $PgIsReadyPath
        NotifyIcon    = $notifyIcon
        ContextMenu   = $contextMenu
        Timer         = $timer
        Icons         = @{
            Green  = $greenIcon
            Red    = $redIcon
            Yellow = $yellowIcon
        }
        MenuItems     = $menuItems
        MenuMap       = @{}
        InstanceStates = @{}
        IsShuttingDown = $false
    }
}

function Rebuild-InstanceMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    try {
        $Context.MenuItems.Instances.DropDownItems.Clear()
        $Context.MenuMap.Clear()
    }
    catch {
        throw ("Rebuild-InstanceMenu failed while clearing menu state: {0}" -f $_.Exception.Message)
    }

    try {
        $states = Get-HashtableValues -Hashtable $Context.InstanceStates
    }
    catch {
        throw ("Rebuild-InstanceMenu failed while reading instance states: {0}" -f $_.Exception.Message)
    }

    foreach ($state in $states) {
        try {
            $capturedState = $state
            $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem((Get-InstanceMenuCaption -State $state))
            $statusItem.Enabled = $false
            $detailsItem = New-Object System.Windows.Forms.ToolStripMenuItem((Get-StateSummaryText -State $state))
            $detailsItem.Enabled = $false

            $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem("Restart service")
            $restartItem.Enabled = [bool]$state.RestartAllowed
            $restartItem.Add_Click({
                Restart-TrackedService -Context $Context -State $capturedState
            })

            $instanceMenu = New-Object System.Windows.Forms.ToolStripMenuItem($state.Name)
            [void]$instanceMenu.DropDownItems.Add($statusItem)
            [void]$instanceMenu.DropDownItems.Add($detailsItem)
            [void]$instanceMenu.DropDownItems.Add($restartItem)

            [void]$Context.MenuItems.Instances.DropDownItems.Add($instanceMenu)
            $Context.MenuMap[$state.ServiceName] = @{
                RootItem   = $instanceMenu
                StatusItem = $statusItem
                DetailsItem = $detailsItem
                RestartItem = $restartItem
            }
        }
        catch {
            throw ("Rebuild-InstanceMenu failed for service '{0}': {1}" -f $state.ServiceName, $_.Exception.Message)
        }
    }

    if ((Get-SafeCount -InputObject $Context.InstanceStates) -eq 0) {
        [void]$Context.MenuItems.Instances.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripMenuItem("No PostgreSQL instances found")))
    }
}

function Initialize-InstanceStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    try {
        $Context.InstanceStates.Clear()
    }
    catch {
        throw ("Initialize-InstanceStates failed while clearing previous state: {0}" -f $_.Exception.Message)
    }

    try {
        $resolvedInstances = @(Resolve-ConfiguredInstances -Configuration $Context.Configuration)
    }
    catch {
        throw ("Initialize-InstanceStates failed while resolving configured instances: {0}" -f $_.Exception.Message)
    }

    foreach ($instance in $resolvedInstances) {
        try {
            $Context.InstanceStates[$instance.ServiceName] = New-InstanceState -Instance $instance
        }
        catch {
            throw ("Initialize-InstanceStates failed for service '{0}': {1}" -f $instance.ServiceName, $_.Exception.Message)
        }
    }

    try {
        Rebuild-InstanceMenu -Context $Context
    }
    catch {
        throw ("Initialize-InstanceStates failed while rebuilding menu: {0}" -f $_.Exception.Message)
    }
}

function Reload-ApplicationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    try {
        $configuration = Get-JsonConfiguration -Path $Context.Configuration.ConfigPath
        $logPathResolution = Resolve-WritableLogPath -CandidatePath $configuration.Logging.LogPath -FallbackFileName "pgnotifier.log"
        $configuration.Logging.LogPath = $logPathResolution.Path
        $Context.Configuration = $configuration
        $Context.PgIsReadyPath = Resolve-PgIsReadyPath -Configuration $configuration

        $Context.Timer.Interval = [Math]::Max(1000, ($configuration.Application.IntervalSeconds * 1000))
        Initialize-InstanceStates -Context $Context
        Update-MenuCaptions -Context $Context
        Update-NotifyIconFromStates -Context $Context
        if ($Context.PgIsReadyPath) {
            Write-AppLog -Context $Context -Message ("Configuration reloaded. pg_isready resolved to '{0}'." -f $Context.PgIsReadyPath)
        }
        else {
            Write-AppLog -Context $Context -Message "Configuration reloaded. pg_isready was not found; TCP fallback remains active." -Level "WARN"
        }
        if ($logPathResolution.UsedFallback) {
            Write-AppLog -Context $Context -Message ("Configured log path '{0}' is not writable. Using '{1}'." -f $logPathResolution.OriginalPath, $logPathResolution.Path) -Level "WARN"
        }
        Show-StateNotification -Context $Context -Title "PgNotifier" -Message "Configuration reloaded successfully." -InstanceNotificationsEnabled $true
    }
    catch {
        Write-AppLog -Context $Context -Message ("Failed to reload configuration: {0}" -f $_.Exception.Message) -Level "ERROR"
        Show-StateNotification -Context $Context -Title "PgNotifier error" -Message "Configuration reload failed. Check the log for details." -InstanceNotificationsEnabled $true
    }
}

function Invoke-HealthCheckCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    foreach ($state in (Get-HashtableValues -Hashtable $Context.InstanceStates)) {
        try {
            Test-AndUpdateInstanceState -Context $Context -State $state
        }
        catch {
            $state.CurrentStateKey = "ERROR"
            $state.LastMessage = $_.Exception.Message
            Write-AppLog -Context $Context -Message ("Unhandled error for {0}: {1}" -f $state.ServiceName, $_.Exception.Message) -Level "ERROR"
        }
    }

    Update-MenuCaptions -Context $Context
    Update-NotifyIconFromStates -Context $Context
}

function Stop-PgNotifierApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ($Context.IsShuttingDown) {
        return
    }

    $Context.IsShuttingDown = $true

    try {
        $Context.Timer.Stop()
        $Context.Timer.Dispose()
    }
    catch {
    }

    try {
        $Context.NotifyIcon.Visible = $false
        $Context.NotifyIcon.Dispose()
    }
    catch {
    }

    foreach ($icon in $Context.Icons.Values) {
        try {
            $icon.Dispose()
        }
        catch {
        }
    }

    try {
        $Context.ContextMenu.Dispose()
    }
    catch {
    }
}

function Start-PgNotifierApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    try {
        if (-not [Console]::IsOutputRedirected) {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        }
    }
    catch {
    }

    $context = $null
    $startupLog = Get-DefaultLogPath -FileName "startup-errors.log"
    try {
        try {
            Write-LogEntry -Path $startupLog -Message "Startup step: loading configuration." -Level "DEBUG"
            $configuration = Get-JsonConfiguration -Path $ConfigPath
            $logPathResolution = Resolve-WritableLogPath -CandidatePath $configuration.Logging.LogPath -FallbackFileName "pgnotifier.log"
            $configuration.Logging.LogPath = $logPathResolution.Path
            if ($logPathResolution.UsedFallback) {
                Write-LogEntry -Path $startupLog -Message ("Configured log path '{0}' is not writable. Using '{1}'." -f $logPathResolution.OriginalPath, $logPathResolution.Path) -Level "WARN"
            }
            Write-LogEntry -Path $startupLog -Message "Startup step: resolving pg_isready path." -Level "DEBUG"
            Write-LogEntry -Path $startupLog -Message ("Startup context: cwd='{0}', config='{1}', configured pg_isready='{2}'." -f (Get-Location).Path, $ConfigPath, $configuration.PgIsReady.Path) -Level "DEBUG"
            $pgIsReadyPath = Resolve-PgIsReadyPath -Configuration $configuration
            if (-not $pgIsReadyPath) {
                Write-LogEntry -Path $startupLog -Message "pg_isready not found. Running in degraded TCP mode." -Level "WARN"
            }
            else {
                Write-LogEntry -Path $startupLog -Message ("Resolved pg_isready to '{0}'." -f $pgIsReadyPath) -Level "DEBUG"
            }

            Write-LogEntry -Path $startupLog -Message "Startup step: creating application context." -Level "DEBUG"
            $context = New-ApplicationContext -Configuration $configuration -PgIsReadyPath $pgIsReadyPath
            Write-LogEntry -Path $startupLog -Message "Startup step: initializing instance states." -Level "DEBUG"
            Initialize-InstanceStates -Context $context

            Write-LogEntry -Path $startupLog -Message "Startup step: wiring UI events." -Level "DEBUG"
            $context.MenuItems.OpenLog.Add_Click({
                Open-LogFile -Context $context
            })

            $context.MenuItems.OpenConfig.Add_Click({
                Open-ConfigurationFile -Context $context
            })

            $context.MenuItems.Refresh.Add_Click({
                Invoke-ManualRefresh -Context $context
            })

            $context.MenuItems.Services.Add_Click({
                Open-WindowsServicesConsole
            })

            $context.MenuItems.Reload.Add_Click({
                Reload-ApplicationConfiguration -Context $context
            })

            $context.MenuItems.SilentMode.Add_Click({
                $context.Configuration.Application.SilentMode = $context.MenuItems.SilentMode.Checked
                Write-AppLog -Context $context -Message ("Silent mode set to {0}" -f $context.Configuration.Application.SilentMode)
            })

            $context.MenuItems.Exit.Add_Click({
                Write-AppLog -Context $context -Message "Exit requested by user."
                Stop-PgNotifierApplication -Context $context
                [System.Windows.Forms.Application]::Exit()
            })

            $context.NotifyIcon.Add_DoubleClick({
                Invoke-ManualRefresh -Context $context
            })

            $context.Timer.Add_Tick({
                Invoke-HealthCheckCycle -Context $context
            })

            Write-LogEntry -Path $startupLog -Message "Startup step: first health-check cycle." -Level "DEBUG"
            Write-AppLog -Context $context -Message ("Application starting with config '{0}'." -f $ConfigPath)
            Invoke-HealthCheckCycle -Context $context

            if (-not $context.Configuration.Notifications.SuppressStartupBalloon -and -not $context.Configuration.Application.SilentMode) {
                Write-LogEntry -Path $startupLog -Message "Startup step: showing startup notification." -Level "DEBUG"
                $instanceCount = Get-SafeCount -InputObject $context.InstanceStates
                Show-StateNotification -Context $context -Title $context.Configuration.Application.DisplayName -Message ("Monitoring {0} PostgreSQL instance(s)." -f $instanceCount) -InstanceNotificationsEnabled $true
            }

            Write-LogEntry -Path $startupLog -Message "Startup step: starting timer and message loop." -Level "DEBUG"
            $context.Timer.Start()
            [System.Windows.Forms.Application]::Run()
        }
        finally {
            if ($context) {
                Stop-PgNotifierApplication -Context $context
            }
        }
    }
    catch {
        try {
            Write-LogEntry -Path $startupLog -Message $_.Exception.ToString() -Level "ERROR"
        }
        catch {
        }

        [System.Windows.Forms.MessageBox]::Show(
            ("Startup failed: {0}" -f $_.Exception.Message),
            "PgNotifier - Fatal error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Start-PgNotifierApplication
}
