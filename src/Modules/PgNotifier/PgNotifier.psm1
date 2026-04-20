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

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $Path -Value $line -Encoding UTF8
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
        Write-LogEntry -Path $Context.Configuration.Logging.LogPath -Message $Message -Level $Level
    }
    catch {
        Write-Warning ("Failed to write log entry: {0}" -f $_.Exception.Message)
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

function Resolve-ExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Candidate).Path
    }

    $command = Get-Command -Name $Candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
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
            displayName         = "PgNotifier"
            intervalSeconds     = 5
            restartBadgeSeconds = 10
            startMinimized      = $true
            autoDiscover        = $true
            silentMode          = $false
        }
        logging = @{
            logPath = (Join-Path -Path $env:ProgramData -ChildPath "PgNotifier\logs\pgnotifier.log")
            level   = "INFO"
        }
        notifications = @{
            enabled                 = $true
            suppressStartupBalloon  = $false
            defaultBalloonTimeoutMs = 3000
        }
        pgIsReady = @{
            path           = "pg_isready.exe"
            timeoutSeconds = 5
            retryCount     = 2
            retryDelayMs   = 1000
            extraArguments = @()
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

    if ($InputObject.PSObject.Properties.Count -gt 0) {
        $hashtable = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
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
            Merge-Hashtable -Base $Base[$key] -Override $Override[$key]
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

    $defaultConfig = New-DefaultConfiguration
    if (-not (Test-Path -LiteralPath $Path)) {
        return ConvertTo-NormalizedConfiguration -Configuration $defaultConfig -ConfigPath $Path
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = if ([string]::IsNullOrWhiteSpace($content)) { @{} } else { ConvertTo-Hashtable -InputObject (ConvertFrom-Json -InputObject $content -Depth 20) }
    $merged = Merge-Hashtable -Base $defaultConfig -Override $parsed
    return ConvertTo-NormalizedConfiguration -Configuration $merged -ConfigPath $Path
}

function ConvertTo-NormalizedConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $instances = @()
    foreach ($instance in @($Configuration.instances)) {
        $instances += [pscustomobject]@{
            Name                 = [string]$instance.name
            ServiceName          = [string]$instance.serviceName
            HostName             = if ($instance.hostName) { [string]$instance.hostName } else { "localhost" }
            Port                 = if ($instance.port) { [int]$instance.port } else { 5432 }
            PostgresExe          = [string]$instance.postgresExe
            Enabled              = if ($null -ne $instance.enabled) { [bool]$instance.enabled } else { $true }
            NotificationsEnabled = if ($null -ne $instance.notificationsEnabled) { [bool]$instance.notificationsEnabled } else { $true }
            RestartAllowed       = if ($null -ne $instance.restartAllowed) { [bool]$instance.restartAllowed } else { $true }
        }
    }

    return [pscustomobject]@{
        ConfigPath  = $ConfigPath
        Application = [pscustomobject]@{
            DisplayName         = [string]$Configuration.application.displayName
            IntervalSeconds     = [int]$Configuration.application.intervalSeconds
            RestartBadgeSeconds = [int]$Configuration.application.restartBadgeSeconds
            StartMinimized      = [bool]$Configuration.application.startMinimized
            AutoDiscover        = [bool]$Configuration.application.autoDiscover
            SilentMode          = [bool]$Configuration.application.silentMode
        }
        Logging     = [pscustomobject]@{
            LogPath = [string]$Configuration.logging.logPath
            Level   = [string]$Configuration.logging.level
        }
        Notifications = [pscustomobject]@{
            Enabled                 = [bool]$Configuration.notifications.enabled
            SuppressStartupBalloon  = [bool]$Configuration.notifications.suppressStartupBalloon
            DefaultBalloonTimeoutMs = [int]$Configuration.notifications.defaultBalloonTimeoutMs
        }
        PgIsReady = [pscustomobject]@{
            Path           = [string]$Configuration.pgIsReady.path
            TimeoutSeconds = [int]$Configuration.pgIsReady.timeoutSeconds
            RetryCount     = [int]$Configuration.pgIsReady.retryCount
            RetryDelayMs   = [int]$Configuration.pgIsReady.retryDelayMs
            ExtraArguments = @($Configuration.pgIsReady.extraArguments)
        }
        Instances = $instances
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

    $resolved = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($instance in @($Configuration.Instances | Where-Object { $_.Enabled })) {
        $key = $instance.ServiceName
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $seen.ContainsKey($key)) {
            $resolved.Add($instance)
            $seen[$key] = $true
        }
    }

    if ($Configuration.Application.AutoDiscover) {
        foreach ($service in Get-PostgreSqlWindowsServices) {
            if ($seen.ContainsKey($service.Name)) {
                continue
            }

            $resolved.Add([pscustomobject]@{
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

    return @($resolved)
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
        Name        = $service.Name
        State       = $service.State
        Status      = $service.Status
        ProcessId   = [int]$service.ProcessId
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
                TimedOut = $true
                ExitCode = -1
                StdOut   = $process.StandardOutput.ReadToEnd()
                StdErr   = $process.StandardError.ReadToEnd()
            }
        }

        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StdOut   = $process.StandardOutput.ReadToEnd()
            StdErr   = $process.StandardError.ReadToEnd()
        }
    }
    finally {
        $process.Dispose()
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
                IsReady  = $true
                TimedOut = $false
                ExitCode = $result.ExitCode
                Message  = ($result.StdOut.Trim())
                Attempt  = $attempt
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
        Name                 = $Instance.Name
        ServiceName          = $Instance.ServiceName
        HostName             = $Instance.HostName
        Port                 = $Instance.Port
        RestartAllowed       = $Instance.RestartAllowed
        NotificationsEnabled = $Instance.NotificationsEnabled
        LastStateKey         = $null
        LastPid              = $null
        YellowUntil          = (Get-Date).AddSeconds(-1)
        LastMessage          = "Waiting for first check."
        CurrentStateKey      = "UNKNOWN"
    }
}

function Get-InstanceMenuCaption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    return "{0} [{1}] {2}:{3}" -f $State.Name, $State.CurrentStateKey, $State.HostName, $State.Port
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
    $states = @($Context.InstanceStates.Values)

    if ($states.Count -eq 0) {
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

        if ($state.CurrentStateKey -ne "UP") {
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

    $upCount = @($states | Where-Object { $_.CurrentStateKey -eq "UP" }).Count
    Set-NotifyTextSafe -NotifyIcon $Context.NotifyIcon -Text ("{0}: {1}/{2} healthy" -f $Context.Configuration.Application.DisplayName, $upCount, $states.Count)
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
        }
    }

    $Context.MenuItems.SilentMode.Checked = [bool]$Context.Configuration.Application.SilentMode
}

function Test-AndUpdateInstanceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

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
        if ($isRunning) {
            $pgReady = Test-PgInstanceReady -Context $Context -Instance $State
        }

        if ($isRunning -and $State.LastPid -and $snapshot.ProcessId -and $State.LastPid -ne $snapshot.ProcessId) {
            $State.YellowUntil = (Get-Date).AddSeconds($Context.Configuration.Application.RestartBadgeSeconds)
            $State.LastMessage = "PostgreSQL restarted. PID changed from $($State.LastPid) to $($snapshot.ProcessId)."
            Show-StateNotification -Context $Context -Title "PostgreSQL restarted" -Message ("{0}: PID {1} -> {2}" -f $State.Name, $State.LastPid, $snapshot.ProcessId) -InstanceNotificationsEnabled $State.NotificationsEnabled
            Write-AppLog -Context $Context -Message ("Restart detected for {0}. PID {1} -> {2}" -f $State.ServiceName, $State.LastPid, $snapshot.ProcessId) -Level "WARN"
        }

        if (-not $isRunning) {
            $newStateKey = "STOPPED"
            $message = "Service is stopped."
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

        [Parameter(Mandatory)]
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
        Configuration  = $Configuration
        PgIsReadyPath  = $PgIsReadyPath
        NotifyIcon     = $notifyIcon
        ContextMenu    = $contextMenu
        Timer          = $timer
        Icons          = @{
            Green  = $greenIcon
            Red    = $redIcon
            Yellow = $yellowIcon
        }
        MenuItems      = $menuItems
        MenuMap        = @{}
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

    $Context.MenuItems.Instances.DropDownItems.Clear()
    $Context.MenuMap.Clear()

    foreach ($state in $Context.InstanceStates.Values) {
        $capturedState = $state
        $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem((Get-InstanceMenuCaption -State $state))
        $statusItem.Enabled = $false

        $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem("Restart service")
        $restartItem.Enabled = [bool]$state.RestartAllowed
        $restartItem.Add_Click({
            Restart-TrackedService -Context $Context -State $capturedState
        })

        $instanceMenu = New-Object System.Windows.Forms.ToolStripMenuItem($state.Name)
        [void]$instanceMenu.DropDownItems.Add($statusItem)
        [void]$instanceMenu.DropDownItems.Add($restartItem)

        [void]$Context.MenuItems.Instances.DropDownItems.Add($instanceMenu)
        $Context.MenuMap[$state.ServiceName] = @{
            RootItem    = $instanceMenu
            StatusItem  = $statusItem
            RestartItem = $restartItem
        }
    }

    if ($Context.InstanceStates.Count -eq 0) {
        [void]$Context.MenuItems.Instances.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripMenuItem("No PostgreSQL instances found")))
    }
}

function Initialize-InstanceStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $Context.InstanceStates.Clear()
    foreach ($instance in Resolve-ConfiguredInstances -Configuration $Context.Configuration) {
        $Context.InstanceStates[$instance.ServiceName] = New-InstanceState -Instance $instance
    }

    Rebuild-InstanceMenu -Context $Context
}

function Reload-ApplicationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    try {
        $configuration = Get-JsonConfiguration -Path $Context.Configuration.ConfigPath
        $Context.Configuration = $configuration
        $Context.PgIsReadyPath = Resolve-ExecutablePath -Candidate $configuration.PgIsReady.Path
        if (-not $Context.PgIsReadyPath) {
            throw "pg_isready was not found."
        }

        $Context.Timer.Interval = [Math]::Max(1000, ($configuration.Application.IntervalSeconds * 1000))
        Initialize-InstanceStates -Context $Context
        Update-MenuCaptions -Context $Context
        Update-NotifyIconFromStates -Context $Context
        Write-AppLog -Context $Context -Message "Configuration reloaded."
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

    foreach ($state in @($Context.InstanceStates.Values)) {
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

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $configuration = Get-JsonConfiguration -Path $ConfigPath
    $pgIsReadyPath = Resolve-ExecutablePath -Candidate $configuration.PgIsReady.Path
    if (-not $pgIsReadyPath) {
        [System.Windows.Forms.MessageBox]::Show(
            "pg_isready.exe was not found. Update the configuration and try again.",
            "PgNotifier - Startup error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $context = New-ApplicationContext -Configuration $configuration -PgIsReadyPath $pgIsReadyPath
    Initialize-InstanceStates -Context $context

    $context.MenuItems.OpenLog.Add_Click({
        Open-LogFile -Context $context
    })

    $context.MenuItems.OpenConfig.Add_Click({
        Open-ConfigurationFile -Context $context
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

    $context.Timer.Add_Tick({
        Invoke-HealthCheckCycle -Context $context
    })

    Write-AppLog -Context $context -Message ("Application starting with config '{0}'." -f $ConfigPath)
    Invoke-HealthCheckCycle -Context $context

    if (-not $context.Configuration.Notifications.SuppressStartupBalloon -and -not $context.Configuration.Application.SilentMode) {
        Show-StateNotification -Context $context -Title $context.Configuration.Application.DisplayName -Message ("Monitoring {0} PostgreSQL instance(s)." -f $context.InstanceStates.Count) -InstanceNotificationsEnabled $true
    }

    $context.Timer.Start()

    try {
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Stop-PgNotifierApplication -Context $context
    }
}

Export-ModuleMember -Function Start-PgNotifierApplication
