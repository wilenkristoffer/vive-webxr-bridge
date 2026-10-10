# vive-webxr-bridge: WebXR in the browser for VIVE Console headsets (developed on a VIVE Pro 2).
#
# Browsers can't show WebXR through SteamVR's OpenXR runtime on these setups (frames stay stuck on
# SteamVR's "Waiting..." screen). VIVE's own OpenXR runtime does show them, but as soon as a browser
# takes the headset, VIVE's driver opens vrmonitor://quit to shut SteamVR down, which then takes
# VIVE's runtime down too. This launcher, for the lifetime of one Edge window:
#   1. points the vrmonitor:// link at a harmless logger, so the quit goes nowhere;
#   2. starts Edge (own profile) on VIVE's runtime, with VIVE's crashing OpenXR layers disabled;
#   3. pauses SteamVR's compositor while a browser VR session has the headset (otherwise its frames
#      fight Edge's and the picture flickers), and resumes it when the session ends;
#   4. restores everything when Edge closes, and offers a clean SteamVR restart, because VIVE
#      doesn't hand the display back to SteamVR on its own.
param([string]$Url = 'https://immersive-web.github.io/webxr-samples/')

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'WebXRVive'
$profileDir = Join-Path $stateDir 'EdgeProfile'
$handlerBackup = Join-Path $stateDir 'vrmonitor-handler.txt'
$blockLog = Join-Path $stateDir 'blocked-links.log'
$handlerKey = 'HKCU:\Software\Classes\vrmonitor\Shell\Open\Command'
$edgeExe = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
$viveRuntime = "${env:ProgramFiles(x86)}\VIVE\Updater\App\ViveVRRuntime\ViveVR_openxr\ViveOpenXR.json"
$viveLogDir = Join-Path $env:ProgramData 'HTC\ViveSoftware\ViveVRRuntime\logs'
New-Item -ItemType Directory -Force $stateDir | Out-Null

foreach ($required in @(@('Microsoft Edge', $edgeExe), @("VIVE's OpenXR runtime (VIVE Console)", $viveRuntime), @("VIVE's runtime logs", $viveLogDir))) {
    if (-not (Test-Path $required[1])) {
        Write-Host "Can't find $($required[0]) at $($required[1])." -ForegroundColor Red
        Write-Host 'This tool needs Microsoft Edge and a headset that runs through VIVE Console.'
        exit 1
    }
}

Add-Type -Name Proc -Namespace WebXRVive -MemberDefinition @'
[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
'@

function Say($msg, $color = 'Gray') { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor $color }

function Restore-Handler {
    if (Test-Path $handlerBackup) {
        $orig = Get-Content $handlerBackup -Raw
        if ($orig -and (Get-Item $handlerKey).GetValue('') -ne $orig.Trim()) {
            Set-ItemProperty $handlerKey -Name '(default)' -Value $orig.Trim()
            Say 'SteamVR quit link restored.'
        }
        Remove-Item $handlerBackup
    }
}

function Wait-For($what, [scriptblock]$test, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $test) { return $true }; Start-Sleep 1 }
    Say "Timed out waiting for $what." 'Yellow'
    return $false
}

# Loads the video2webxr extension (adds a VR button to YouTube) into the launcher's Edge. Edge
# ignores --load-extension, so this uses the DevTools Extensions.loadUnpacked command instead.
function Load-Extension($port, $path) {
    if (-not (Test-Path (Join-Path $path 'manifest.json'))) { return }
    try {
        $version = $null
        for ($i = 0; $i -lt 20 -and -not $version; $i++) {
            try { $version = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 500 }
        }
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([Uri]$version.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
        $msg = @{ id = 1; method = 'Extensions.loadUnpacked'; params = @{ path = $path } } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
        $buf = New-Object byte[] 4096
        $res = $ws.ReceiveAsync([ArraySegment[byte]]$buf, [Threading.CancellationToken]::None).Result
        $reply = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
        $ws.Dispose()
        if ($reply -match '"result"') { Say 'YouTube VR extension loaded.' } else { Say "Couldn't load the YouTube VR extension: $reply" 'Yellow' }
    } catch { Say "Couldn't load the YouTube VR extension: $($_.Exception.Message)" 'Yellow' }
}

function Test-VrUp { (Get-Process vrcompositor -ErrorAction SilentlyContinue) -and (Get-Process ViveVRServer -ErrorAction SilentlyContinue) }

# Same order that works by hand: quit SteamVR, close VIVE Console, start VIVE Console, then SteamVR.
function Restart-SteamVR {
    Say 'Restarting SteamVR and VIVE Console...'
    Start-Process explorer.exe 'vrmonitor://quit'
    Wait-For 'SteamVR to close' { -not (Get-Process vrserver, vrcompositor -ErrorAction SilentlyContinue) } 30 | Out-Null
    Get-Process vrserver, vrcompositor, vrmonitor, vrdashboard, steamtours, WaveConsole -ErrorAction SilentlyContinue | Stop-Process -Force
    # VIVE's runtime must be fully gone, or its driver fails to load ("HVR_ERR_Init_ShuttingDown").
    Wait-For "VIVE's runtime to stop" { -not (Get-Process ViveVRServer, ViveVRCompositor, WaveConsole -ErrorAction SilentlyContinue) } 30 | Out-Null
    Start-Sleep 5
    Start-Process "${env:ProgramFiles(x86)}\VIVE\Updater\App\ViveEyeSettings\ViveSettings.exe" '/launch_console'
    # VIVE Console usually starts SteamVR itself; start it ourselves if it doesn't.
    if (-not (Wait-For 'VIVE Console to start SteamVR' { Test-VrUp } 30)) {
        Start-Process 'steam://rungameid/250820'
        if (-not (Wait-For 'SteamVR' { Test-VrUp } 90)) { return }
    }
    Say 'SteamVR is back.' 'Green'
}

# A crash or closed window last time can leave the quit link redirected; put it back first.
Restore-Handler

if (-not (Test-VrUp)) {
    Say 'SteamVR (with the VIVE runtime) is not running. Start VIVE Console and SteamVR, then press Enter.' 'Yellow'
    Read-Host | Out-Null
}

# Edge only picks up our environment if no Edge is already running with this profile.
$running = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$profileDir*" }
if ($running) { Say 'Closing the previous WebXR Edge window...'; $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep 2 }

$paused = $null
try {
    (Get-Item $handlerKey).GetValue('') | Set-Content $handlerBackup
    Set-ItemProperty $handlerKey -Name '(default)' -Value "`"C:\Windows\System32\cmd.exe`" /c echo %DATE% %TIME% blocked: %1 >> `"$blockLog`""

    $env:XR_RUNTIME_JSON = $viveRuntime
    $env:DISABLE_XR_APILAYER_VIVE_HAND_TRACKING_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_FACIAL_TRACKING_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_SRWORKS_1 = '1'
    $env:DISABLE_XR_APILAYER_VIVE_XRTRACKER_1 = '1'
    $debugPort = 9339
    $edge = Start-Process $edgeExe -ArgumentList "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check',
        "--remote-debugging-port=$debugPort", '--enable-unsafe-extension-debugging', $Url -PassThru
    # Every folder in extensions\ with a manifest.json is loaded (e.g. video2webxr for YouTube).
    Get-ChildItem (Join-Path $PSScriptRoot 'extensions') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Load-Extension $debugPort $_.FullName }
    Say "Edge started. Open a WebXR site and press 'Enter VR'. Close Edge when you're done." 'Green'
    Say 'Keep this window open.'

    # Follow VIVE's server log: it records which process has the headset.
    $logFile = Join-Path $viveLogDir ('vrserver_{0:yyyyMMdd}.txt' -f (Get-Date))
    $stream = [IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
    [void]$stream.Seek(0, 'End')
    # VIVE writes its logs in UTF-16; read as UTF-8 nothing ever matched.
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::Unicode)
    $edgeSessionPid = $null

    while ($true) {
        $edgeAlive = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$profileDir*" }
        if (-not $edgeAlive) { break }

        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line -match 'Scene focus change to (\d+)') {
                $focusPid = [int]$matches[1]
                $p = Get-Process -Id $focusPid -ErrorAction SilentlyContinue
                if ($p -and $p.Name -eq 'msedge' -and -not $paused) {
                    $comp = Get-Process vrcompositor -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($comp) {
                        [void][WebXRVive.Proc]::NtSuspendProcess($comp.Handle)
                        $paused = $comp
                        $edgeSessionPid = $focusPid
                        Say 'VR session started: Edge has the headset (SteamVR display paused).' 'Cyan'
                    }
                }
            } elseif ($line -match 'Scene session \((\d+)\) disconnect' -and $paused -and [int]$matches[1] -eq $edgeSessionPid) {
                [void][WebXRVive.Proc]::NtResumeProcess($paused.Handle)
                $paused = $null
                Say 'VR session ended (SteamVR display resumed). You can enter VR again, or close Edge.' 'Cyan'
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $reader.Close()
    Say 'Edge closed.'
} finally {
    if ($paused) { [void][WebXRVive.Proc]::NtResumeProcess($paused.Handle); Say 'SteamVR display resumed.' }
    Restore-Handler
}

$answer = Read-Host 'Restart SteamVR now so the headset is back to normal? [Y/n]'
if ($answer -notmatch '^[nN]') { Restart-SteamVR }
Say 'Done. You can close this window.' 'Green'
