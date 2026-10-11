# Core of vive-webxr-bridge: everything except the window. Dot-sourced by gui.ps1, and by the
# background runspaces the GUI uses for slow work (loading extensions, restarting SteamVR).
#
# Why each step exists is documented in docs/how-it-works.md. In short, while the bridge is on:
#   - the vrmonitor:// link is pointed at a logger, so VIVE's driver can't quit SteamVR;
#   - the bridge's Edge runs on VIVE's OpenXR runtime with VIVE's crashing OpenXR layers disabled;
#   - SteamVR's compositor is suspended while a browser VR session has the headset (else it flickers).

$Bridge = @{
    StateDir      = Join-Path $env:LOCALAPPDATA 'WebXRVive'
    HandlerKey    = 'HKCU:\Software\Classes\vrmonitor\Shell\Open\Command'
    EdgeExe       = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    ViveRuntime   = "${env:ProgramFiles(x86)}\VIVE\Updater\App\ViveVRRuntime\ViveVR_openxr\ViveOpenXR.json"
    ViveConsole   = "${env:ProgramFiles(x86)}\VIVE\Updater\App\ViveEyeSettings\ViveSettings.exe"
    ViveLogDir    = Join-Path $env:ProgramData 'HTC\ViveSoftware\ViveVRRuntime\logs'
    ExtensionsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'extensions'
    FixesDir      = Join-Path $PSScriptRoot 'webxr-fixes'   # the bridge's own WebXR fixes, always loaded
    DebugPort     = 9339
}
$Bridge.ProfileDir = Join-Path $Bridge.StateDir 'EdgeProfile'
$Bridge.HandlerBackup = Join-Path $Bridge.StateDir 'vrmonitor-handler.txt'
$Bridge.BlockLog = Join-Path $Bridge.StateDir 'blocked-links.log'
$Bridge.PausedFile = Join-Path $Bridge.StateDir 'paused-compositor.txt'
$Bridge.LogFile = Join-Path $Bridge.StateDir 'bridge.log'
New-Item -ItemType Directory -Force $Bridge.StateDir | Out-Null

if (-not ('WebXRVive.Proc' -as [type])) {
    Add-Type -Name Proc -Namespace WebXRVive -MemberDefinition @'
[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
'@
}

# The GUI sets $BridgeLog to a ConcurrentQueue so background runspaces can log to its Log tab.
function Write-BridgeLog($msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    if ($BridgeLog) { $BridgeLog.Enqueue($line) } else { Write-Host $line }
}

function Test-BridgePrerequisites {
    foreach ($req in @(@('Microsoft Edge', $Bridge.EdgeExe), @("VIVE's OpenXR runtime (VIVE Console)", $Bridge.ViveRuntime), @("VIVE's runtime logs", $Bridge.ViveLogDir))) {
        if (-not (Test-Path $req[1])) { return "Can't find $($req[0]) at $($req[1])." }
    }
    return $null
}

function Test-SteamVrUp { [bool](Get-Process vrcompositor -ErrorAction SilentlyContinue) }
function Test-ViveUp { [bool](Get-Process ViveVRServer -ErrorAction SilentlyContinue) }

# The backup holds the original handler command, or one of two markers when there was none to keep:
#   <created> <key>  the bridge created <key> (SteamVR registered the link machine-wide, or not at all),
#                    so restoring deletes it again;
#   <empty>          the key existed with no command, so restoring removes the bridge's command.
function Block-QuitLink {
    try {
        if (Test-Path $Bridge.HandlerKey) {
            $orig = (Get-Item $Bridge.HandlerKey).GetValue('')
            $backup = if ($orig) { $orig } else { '<empty>' }
        } else {
            $created = $Bridge.HandlerKey
            while (-not (Test-Path (Split-Path $created -Parent))) { $created = Split-Path $created -Parent }
            New-Item $Bridge.HandlerKey -Force -ErrorAction Stop | Out-Null
            $backup = "<created> $created"
        }
        Set-Content $Bridge.HandlerBackup $backup -Encoding UTF8 -ErrorAction Stop
        Set-ItemProperty $Bridge.HandlerKey -Name '(default)' -Value "`"C:\Windows\System32\cmd.exe`" /c echo %DATE% %TIME% blocked: %1 >> `"$($Bridge.BlockLog)`"" -ErrorAction Stop
        Write-BridgeLog 'SteamVR quit link blocked.'
    } catch {
        Write-BridgeLog "Couldn't block SteamVR's quit link, so VIVE may close SteamVR when VR starts: $($_.Exception.Message)"
    }
}

# Also called on start, in case a crash or closed window last time left the link redirected.
function Restore-QuitLink {
    if (-not (Test-Path $Bridge.HandlerBackup)) { return }
    $orig = (Get-Content $Bridge.HandlerBackup -Raw -Encoding UTF8).Trim()
    try {
        if ($orig -like '<created> *') {
            $created = $orig.Substring(10)
            if (Test-Path $created) { Remove-Item $created -Recurse -ErrorAction Stop; Write-BridgeLog 'SteamVR quit link restored.' }
        } elseif ($orig -eq '<empty>') {
            if ((Test-Path $Bridge.HandlerKey) -and (Get-Item $Bridge.HandlerKey).GetValue('')) {
                # Remove-ItemProperty can't remove a key's default value.
                $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(($Bridge.HandlerKey -replace '^HKCU:\\'), $true)
                $key.DeleteValue('', $false)
                $key.Close()
                Write-BridgeLog 'SteamVR quit link restored.'
            }
        } elseif ($orig) {
            if (-not (Test-Path $Bridge.HandlerKey) -or (Get-Item $Bridge.HandlerKey).GetValue('') -ne $orig) {
                if (-not (Test-Path $Bridge.HandlerKey)) { New-Item $Bridge.HandlerKey -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty $Bridge.HandlerKey -Name '(default)' -Value $orig -ErrorAction Stop
                Write-BridgeLog 'SteamVR quit link restored.'
            }
        }
        Remove-Item $Bridge.HandlerBackup
    } catch {
        # Keep the backup so the next start tries again.
        Write-BridgeLog "Couldn't restore SteamVR's quit link: $($_.Exception.Message)"
    }
}

function Get-BridgeEdgeProcesses {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$($Bridge.ProfileDir)*" }
}

function Start-BridgeEdge([string]$Url) {
    # Edge only picks up these variables in a fresh process for this profile; they're inherited from
    # the bridge's own process and affect nothing else.
    $env:XR_RUNTIME_JSON = $Bridge.ViveRuntime
    $env:DISABLE_XR_APILAYER_VIVE_HAND_TRACKING_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_FACIAL_TRACKING_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_SRWORKS_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_XRTRACKER_1 = '1'
    $edgeArgs = @("--user-data-dir=`"$($Bridge.ProfileDir)`"", '--no-first-run', '--no-default-browser-check',
        "--remote-debugging-port=$($Bridge.DebugPort)", '--enable-unsafe-extension-debugging')
    if ($Url) { $edgeArgs += $Url }
    Start-Process $Bridge.EdgeExe -ArgumentList $edgeArgs | Out-Null
    Write-BridgeLog 'Bridge Edge window started.'
}

# Opens a page in the bridge's Edge (an already running Edge with this profile takes it over).
function Open-InBridgeEdge([string]$Url) {
    Start-Process $Bridge.EdgeExe -ArgumentList "--user-data-dir=`"$($Bridge.ProfileDir)`"", $Url | Out-Null
}

function Stop-BridgeEdge {
    Get-BridgeEdgeProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Edge ignores --load-extension, so extensions go in through the DevTools Extensions.loadUnpacked command.
function Install-BridgeExtensions {
    $folders = @(Get-Item $Bridge.FixesDir -ErrorAction SilentlyContinue) + @(Get-ChildItem $Bridge.ExtensionsDir -Directory -ErrorAction SilentlyContinue) |
        Where-Object { $_ -and (Test-Path (Join-Path $_.FullName 'manifest.json')) }
    if (-not $folders) { return }
    $version = $null
    for ($i = 0; $i -lt 30 -and -not $version; $i++) {
        try { $version = Invoke-RestMethod "http://127.0.0.1:$($Bridge.DebugPort)/json/version" -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $version) { Write-BridgeLog "Couldn't reach the bridge Edge to load extensions."; return }
    foreach ($folder in $folders) {
        try {
            $ws = New-Object System.Net.WebSockets.ClientWebSocket
            $ws.ConnectAsync([Uri]$version.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
            $msg = @{ id = 1; method = 'Extensions.loadUnpacked'; params = @{ path = $folder.FullName } } | ConvertTo-Json -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
            $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
            $buf = New-Object byte[] 4096
            $res = $ws.ReceiveAsync([ArraySegment[byte]]$buf, [Threading.CancellationToken]::None).Result
            $reply = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
            $ws.Dispose()
            if ($reply -match '"result"') { Write-BridgeLog "Extension loaded: $($folder.Name)" }
            else { Write-BridgeLog "Couldn't load extension $($folder.Name): $reply" }
        } catch { Write-BridgeLog "Couldn't load extension $($folder.Name): $($_.Exception.Message)" }
    }
}

# The paused process is also written to a file, so that if the bridge or the PC dies mid-session,
# the next start can resume it (Resume-LeftoverCompositor) instead of leaving SteamVR frozen.
function Suspend-SteamVrCompositor {
    $comp = Get-Process vrcompositor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($comp) {
        Set-Content $Bridge.PausedFile ('{0} {1:o}' -f $comp.Id, $comp.StartTime)
        [void][WebXRVive.Proc]::NtSuspendProcess($comp.Handle)
    }
    return $comp
}

function Resume-SteamVrCompositor($comp) {
    if ($comp) { [void][WebXRVive.Proc]::NtResumeProcess($comp.Handle) }
    Remove-Item $Bridge.PausedFile -ErrorAction SilentlyContinue
}

function Resume-LeftoverCompositor {
    if (-not (Test-Path $Bridge.PausedFile)) { return }
    $id, $started = (Get-Content $Bridge.PausedFile -Raw).Trim() -split ' ', 2
    $comp = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
    # The start time check makes sure the ID hasn't been reused by another process since.
    if ($comp -and $comp.Name -eq 'vrcompositor' -and ('{0:o}' -f $comp.StartTime) -eq $started) {
        [void][WebXRVive.Proc]::NtResumeProcess($comp.Handle)
        Write-BridgeLog 'SteamVR display resumed (it was left paused when the bridge last stopped unexpectedly).'
    }
    Remove-Item $Bridge.PausedFile -ErrorAction SilentlyContinue
}

# VIVE's server log records which process has the headset. VIVE starts a new file each day.
function Get-ViveLogFile { Join-Path $Bridge.ViveLogDir ('vrserver_{0:yyyyMMdd}.txt' -f (Get-Date)) }

# Opens a VIVE log (UTF-16) for following; at its end unless -FromStart.
function Open-ViveLogReader([string]$file, [switch]$FromStart) {
    if (-not (Test-Path $file)) { return $null }
    $stream = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    if (-not $FromStart) { [void]$stream.Seek(0, 'End') }
    return New-Object IO.StreamReader($stream, [Text.Encoding]::Unicode)
}

function Wait-BridgeCondition($what, [scriptblock]$test, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $test) { return $true }; Start-Sleep 1 }
    Write-BridgeLog "Timed out waiting for $what."
    return $false
}

# Same order that works by hand: quit SteamVR, close VIVE Console, wait for VIVE's runtime to stop
# (else its driver fails with HVR_ERR_Init_ShuttingDown), start VIVE Console, which starts SteamVR.
function Restart-SteamVrAndVive {
    Write-BridgeLog 'Restarting SteamVR and VIVE Console...'
    Start-Process explorer.exe 'vrmonitor://quit'
    Wait-BridgeCondition 'SteamVR to close' { -not (Get-Process vrserver, vrcompositor -ErrorAction SilentlyContinue) } 30 | Out-Null
    Get-Process vrserver, vrcompositor, vrmonitor, vrdashboard, steamtours, WaveConsole -ErrorAction SilentlyContinue | Stop-Process -Force
    Wait-BridgeCondition "VIVE's runtime to stop" { -not (Get-Process ViveVRServer, ViveVRCompositor, WaveConsole -ErrorAction SilentlyContinue) } 30 | Out-Null
    Start-Sleep 5
    Start-SteamVrAndVive | Out-Null
}

# VIVE Console first (it normally starts SteamVR itself); SteamVR directly if it doesn't.
# Returns $true when both are up.
function Start-SteamVrAndVive {
    if ((Test-SteamVrUp) -and (Test-ViveUp)) { return $true }
    Write-BridgeLog 'Starting VIVE Console and SteamVR...'
    if (-not (Get-Process WaveConsole -ErrorAction SilentlyContinue)) { Start-Process $Bridge.ViveConsole '/launch_console' }
    if (-not (Wait-BridgeCondition 'VIVE Console to start SteamVR' { (Test-SteamVrUp) -and (Test-ViveUp) } 30)) {
        if (-not (Test-SteamVrUp)) { Start-Process 'steam://rungameid/250820' }
        if (-not (Wait-BridgeCondition 'SteamVR' { (Test-SteamVrUp) -and (Test-ViveUp) } 90)) { return $false }
    }
    # The headset needs a few more seconds after the processes appear before an app can take it.
    Start-Sleep 5
    Write-BridgeLog 'SteamVR and VIVE Console are running.'
    return $true
}

function Get-BridgeSettings {
    $defaults = @{ AutoStartSteamVr = $true; RestartOnStop = $false }
    $file = Join-Path $Bridge.StateDir 'settings.json'
    if (Test-Path $file) {
        try { (Get-Content $file -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $defaults[$_.Name] = $_.Value } } catch {}
    }
    return $defaults
}

function Save-BridgeSettings($settings) {
    $settings | ConvertTo-Json | Set-Content (Join-Path $Bridge.StateDir 'settings.json')
}
