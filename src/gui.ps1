# vive-webxr-bridge window: a Start/Stop switch, status, site links and a live log.
# The bridge logic is in core.ps1; slow work (extensions, SteamVR restart) runs in background
# runspaces so the window stays responsive.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# The window belongs to powershell.exe, so without its own app ID the taskbar groups it under
# PowerShell and shows PowerShell's icon instead of ours. Must be set before any window exists.
Add-Type -Name Shell -Namespace WebXRVive -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
[void][WebXRVive.Shell]::SetCurrentProcessExplicitAppUserModelID('wilenkristoffer.ViveWebXRBridge')

$coreFile = Join-Path $PSScriptRoot 'core.ps1'
$BridgeLog = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
. $coreFile
$settings = Get-BridgeSettings

$state = @{
    On          = $false
    Busy        = $null     # text shown while SteamVR is being started/restarted in the background
    StartedAt   = [datetime]::MinValue
    Reader      = $null
    Paused      = $null     # suspended vrcompositor process while a browser session has the headset
    SessionPid  = $null
    HadSession  = $false
    Jobs        = New-Object System.Collections.ArrayList
    LastCheck   = [datetime]::MinValue
}

$sites = [ordered]@{
    'WebXR samples'           = 'https://immersive-web.github.io/webxr-samples/'
    'three.js WebXR examples' = 'https://threejs.org/examples/?q=webxr'
    'A-Frame examples'        = 'https://aframe.io/examples/'
    'Moon Rider (game)'       = 'https://moonrider.xyz'
    'YouTube (360° videos)'   = 'https://www.youtube.com/results?search_query=360+vr'
}

# --- background work -------------------------------------------------------------------------

function Start-BackgroundWork([string]$call, [scriptblock]$onDone) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript("param(`$q) `$BridgeLog = `$q; . '$coreFile'; $call").AddArgument($BridgeLog)
    [void]$state.Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $onDone })
}

function Complete-BackgroundWork {
    foreach ($job in @($state.Jobs)) {
        if ($job.Handle.IsCompleted) {
            try { [void]$job.PS.EndInvoke($job.Handle) } catch { Write-BridgeLog "Background task failed: $($_.Exception.Message)" }
            $job.PS.Dispose()
            $state.Jobs.Remove($job)
            if ($job.OnDone) { & $job.OnDone }
        }
    }
}

# --- bridge on/off ---------------------------------------------------------------------------

function Start-Bridge {
    $problem = Test-BridgePrerequisites
    if ($problem) {
        [System.Windows.Forms.MessageBox]::Show("$problem`n`nThis tool needs Microsoft Edge and a headset that runs through VIVE Console.", 'vive-webxr-bridge', 'OK', 'Error') | Out-Null
        return
    }
    if (-not ((Test-SteamVrUp) -and (Test-ViveUp))) {
        if (-not $settings.AutoStartSteamVr) {
            [System.Windows.Forms.MessageBox]::Show("Start VIVE Console and SteamVR first, and wait until the headset shows SteamVR.", 'vive-webxr-bridge', 'OK', 'Information') | Out-Null
            return
        }
        Invoke-SteamVrWork 'Start-SteamVrAndVive' 'Starting SteamVR...' {
            if ((Test-SteamVrUp) -and (Test-ViveUp)) { Enable-Bridge } else { Write-BridgeLog "SteamVR didn't start; the bridge stays off." }
        }
        return
    }
    Enable-Bridge
}

function Enable-Bridge {
    Restore-QuitLink
    if (Get-BridgeEdgeProcesses) { Write-BridgeLog 'Closing a bridge Edge window left over from before.'; Stop-BridgeEdge; Start-Sleep 2 }

    Block-QuitLink
    $state.Reader = Open-ViveLogReader
    if (-not $state.Reader) { Write-BridgeLog "VIVE's log for today wasn't found; VR sessions won't be detected." }
    Start-BridgeEdge
    Start-BackgroundWork 'Install-BridgeExtensions' $null
    $state.On = $true
    $state.StartedAt = Get-Date
    $state.HadSession = $false
    Write-BridgeLog 'Bridge is ON. Open a WebXR site in the bridge Edge window and press Enter VR.'
    Update-View
}

function Stop-Bridge([bool]$offerRestart = $true) {
    if (-not $state.On) { return }
    $state.On = $false
    if ($state.Paused) { Resume-SteamVrCompositor $state.Paused; $state.Paused = $null; Write-BridgeLog 'SteamVR display resumed.' }
    Stop-BridgeEdge
    Restore-QuitLink
    if ($state.Reader) { $state.Reader.Close(); $state.Reader = $null }
    Write-BridgeLog 'Bridge is OFF.'
    Update-View
    if ($offerRestart -and $settings.RestartOnStop) {
        Invoke-SteamVrWork 'Restart-SteamVrAndVive' 'Restarting SteamVR...' $null
    } elseif ($state.HadSession) {
        Write-BridgeLog "VIVE doesn't hand the headset back to SteamVR by itself. If the headset shows an empty space, use 'Restart SteamVR + VIVE Console'."
    }
}

# Runs a slow SteamVR start/restart in the background, with the buttons disabled meanwhile.
function Invoke-SteamVrWork([string]$call, [string]$busyText, [scriptblock]$then) {
    $state.Busy = $busyText
    $steamVrButton.Enabled = $false
    $toggle.Enabled = $false
    Update-View
    $done = { $state.Busy = $null; $steamVrButton.Enabled = $true; $toggle.Enabled = $true; Update-View }
    if ($then) { $done = [scriptblock]::Create($done.ToString() + "`n" + $then.ToString()) }
    Start-BackgroundWork $call $done
}

# Called on a timer: follows VIVE's log to pause/resume SteamVR around browser VR sessions.
function Update-Session {
    if (-not $state.Reader) { return }
    while (($line = $state.Reader.ReadLine()) -ne $null) {
        if ($line -match 'Scene focus change to (\d+)') {
            $p = Get-Process -Id ([int]$matches[1]) -ErrorAction SilentlyContinue
            if ($p -and $p.Name -eq 'msedge' -and -not $state.Paused) {
                $state.Paused = Suspend-SteamVrCompositor
                $state.SessionPid = $p.Id
                $state.HadSession = $true
                Write-BridgeLog 'VR session started: Edge has the headset (SteamVR display paused).'
            }
        } elseif ($line -match 'Scene session \((\d+)\) disconnect' -and $state.Paused -and [int]$matches[1] -eq $state.SessionPid) {
            Resume-SteamVrCompositor $state.Paused
            $state.Paused = $null
            Write-BridgeLog 'VR session ended (SteamVR display resumed). You can enter VR again.'
        }
    }
}

# --- window ----------------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'vive-webxr-bridge'
$form.Size = New-Object System.Drawing.Size(480, 500)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
try { $form.Icon = New-Object System.Drawing.Icon (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\icon.ico') } catch {}

$toggle = New-Object System.Windows.Forms.Button
$toggle.Location = New-Object System.Drawing.Point(16, 14)
$toggle.Size = New-Object System.Drawing.Size(130, 48)
$toggle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$toggle.FlatStyle = 'Flat'
$toggle.ForeColor = 'White'
$toggle.Add_Click({ if ($state.On) { Stop-Bridge } else { Start-Bridge } })
$form.Controls.Add($toggle)

$headline = New-Object System.Windows.Forms.Label
$headline.Location = New-Object System.Drawing.Point(160, 14)
$headline.Size = New-Object System.Drawing.Size(290, 48)
$headline.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$headline.TextAlign = 'MiddleLeft'
$form.Controls.Add($headline)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(16, 74)
$tabs.Size = New-Object System.Drawing.Size(434, 375)
$form.Controls.Add($tabs)

$statusTab = New-Object System.Windows.Forms.TabPage
$statusTab.Text = 'Status'
$tabs.TabPages.Add($statusTab)
$logTab = New-Object System.Windows.Forms.TabPage
$logTab.Text = 'Log'
$tabs.TabPages.Add($logTab)

function New-StatusRow($y, $caption) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(12, $y); $l.Size = New-Object System.Drawing.Size(150, 22); $l.Text = $caption
    $statusTab.Controls.Add($l)
    $v = New-Object System.Windows.Forms.Label
    $v.Location = New-Object System.Drawing.Point(165, $y); $v.Size = New-Object System.Drawing.Size(250, 22)
    $statusTab.Controls.Add($v)
    return $v
}
$steamVrValue = New-StatusRow 12 'SteamVR'
$viveValue = New-StatusRow 36 "VIVE runtime"
$sessionValue = New-StatusRow 60 'Browser VR session'

$linksTitle = New-Object System.Windows.Forms.Label
$linksTitle.Location = New-Object System.Drawing.Point(12, 96); $linksTitle.Size = New-Object System.Drawing.Size(400, 22)
$linksTitle.Text = 'Open in the bridge Edge window:'
$statusTab.Controls.Add($linksTitle)

$links = @()
$y = 120
foreach ($name in $sites.Keys) {
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Location = New-Object System.Drawing.Point(24, $y); $link.Size = New-Object System.Drawing.Size(380, 22)
    $link.Text = $name
    $link.Tag = $sites[$name]
    $link.Add_LinkClicked({ param($s) Open-InBridgeEdge $s.Tag; Write-BridgeLog "Opened $($s.Tag)" })
    $statusTab.Controls.Add($link)
    $links += $link
    $y += 24
}

$steamVrButton = New-Object System.Windows.Forms.Button
$steamVrButton.Location = New-Object System.Drawing.Point(12, 252); $steamVrButton.Size = New-Object System.Drawing.Size(260, 32)
$steamVrButton.Add_Click({
    if ((Test-SteamVrUp) -and (Test-ViveUp)) { Invoke-SteamVrWork 'Restart-SteamVrAndVive' 'Restarting SteamVR...' $null }
    else { Invoke-SteamVrWork 'Start-SteamVrAndVive' 'Starting SteamVR...' $null }
})
$statusTab.Controls.Add($steamVrButton)

function New-SettingBox($y, $text, $key) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Location = New-Object System.Drawing.Point(12, $y); $c.Size = New-Object System.Drawing.Size(410, 24)
    $c.Text = $text
    $c.Checked = [bool]$settings[$key]
    $c.Tag = $key
    $c.Add_CheckedChanged({ param($s) $settings[$s.Tag] = $s.Checked; Save-BridgeSettings $settings })
    $statusTab.Controls.Add($c)
}
New-SettingBox 296 'Start VIVE Console and SteamVR when I press Start' 'AutoStartSteamVr'
New-SettingBox 320 'Restart SteamVR and VIVE Console when I press Stop' 'RestartOnStop'

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Dock = 'Fill'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = 'White'
$logTab.Controls.Add($logBox)

function Set-Value($label, $text, $ok) {
    $label.Text = $text
    $label.ForeColor = if ($ok) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DimGray }
}

function Update-View {
    $steam = Test-SteamVrUp
    $vive = Test-ViveUp
    Set-Value $steamVrValue $(if ($steam) { 'Running' } else { 'Not running' }) $steam
    Set-Value $viveValue $(if ($vive) { 'Running' } else { 'Not running' }) $vive
    if ($state.Paused) { Set-Value $sessionValue 'Active: Edge has the headset' $true }
    elseif ($state.On) { Set-Value $sessionValue 'Waiting for Enter VR' $false }
    else { Set-Value $sessionValue 'Bridge is off' $false }

    $steamVrButton.Text = if ($steam -and $vive) { 'Restart SteamVR + VIVE Console' } else { 'Start SteamVR + VIVE Console' }

    if ($state.Busy) {
        $headline.Text = $state.Busy
        $headline.ForeColor = [System.Drawing.Color]::DarkOrange
    } elseif ($state.On) {
        $toggle.Text = 'Stop'; $toggle.BackColor = [System.Drawing.Color]::Firebrick
        $headline.Text = if ($state.Paused) { 'In VR' } else { 'ON: browser VR ready' }
        $headline.ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $toggle.Text = 'Start'; $toggle.BackColor = [System.Drawing.Color]::SeaGreen
        $headline.Text = 'OFF'
        $headline.ForeColor = [System.Drawing.Color]::DimGray
    }
    foreach ($l in $links) { $l.Enabled = $state.On }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($BridgeLog.TryDequeue([ref]$line)) { $logBox.AppendText($line + [Environment]::NewLine) }
    Complete-BackgroundWork
    if ($state.On) { Update-Session }
    if (((Get-Date) - $state.LastCheck).TotalSeconds -ge 2) {
        $state.LastCheck = Get-Date
        # Closing the bridge Edge window counts as pressing Stop.
        if ($state.On -and ((Get-Date) - $state.StartedAt).TotalSeconds -gt 8 -and -not (Get-BridgeEdgeProcesses)) {
            Write-BridgeLog 'The bridge Edge window was closed.'
            Stop-Bridge
        }
        Update-View
    }
})

$form.Add_Shown({ Restore-QuitLink; Update-View; Write-BridgeLog 'Ready. Start VIVE Console and SteamVR, then press Start.'; $timer.Start() })
$form.Add_FormClosing({ $timer.Stop(); Stop-Bridge $false })

[void]$form.ShowDialog()
