<#
revtunnel for Windows, run on the TARGET (the computer you want to reach): keeps a reverse SSH tunnel from
this computer to a RELAY (a machine with a fixed address, e.g. a VPS), so you can reach this computer through
the relay even though nothing can connect to it directly (dynamic IP, NAT, firewall, ...).

  Double-click revtunnel-target-windows.cmd (in the same folder), or:
  powershell -ExecutionPolicy Bypass -File revtunnel-target-windows.ps1 [options]

It guides you through every step; re-run it any time to see the tunnel's status or change something.
See README.md for the whole workflow, including the relay step.

Options (all optional; anything not given is asked, or its default used with -Yes):
  -Name NAME            tunnel name (default "main"); several tunnels can run side by side
  -TargetPort N         port on this computer the tunnel leads to (default 22 = SSH, which also sets up this
                        computer's SSH server; e.g. 3389 for Remote Desktop)
  -Relay HOST           the relay's IP or host name
  -RelaySshPort N       the relay's SSH port (default 22)
  -RelayUser USER       user on the relay that holds the tunnel (default "tunnel")
  -TunnelPort N         port on the relay that leads to this computer (default 2222; one per target)
                        (older names still work: -LocalPort, -Server, -ServerPort, -ServerUser, -RemotePort)
  -Retries N            reconnect attempts in a row before giving up (default 0 = never give up)
  -LoginKey KEY[,KEY]   public SSH keys allowed to log in to this computer (port 22 only)
  -KeepAwake            never sleep on mains power
  -NoVpn                turn off VPN connections and VPN/TUN adapters, so the tunnel goes direct
  -Python VERSION       install Python (e.g. 3.13) with the Python install manager
  -PythonPackages P,P   pip packages for that Python (ready-made wheels only)
  -Yes                  ask nothing: use the options and defaults (for scripts)
  -Status               only show the status of this computer's tunnels
  -Pause                pause the tunnel given by -Name: stop it, also after a restart; keep its setup
  -Resume               resume it: start it now and from startup again (exit code 0 once it's up, 1 if not yet)
  -Remove               remove the tunnel given by -Name

Files: C:\ProgramData\revtunnel\NAME (settings, the tunnel's key, tunnel.log; "paused" while paused),
C:\ProgramData\revtunnel\setup.log (installer output). The tunnel runs as the scheduled task "revtunnel NAME"
(as SYSTEM, from startup; the task is disabled while paused).
Keep this file ASCII-only: Windows PowerShell 5.1 reads files without a BOM as ANSI.
#>
[CmdletBinding()]
param(
    [string]$Name,
    [Alias('LocalPort')][int]$TargetPort,
    [Alias('Server')][string]$Relay,
    [Alias('ServerPort')][int]$RelaySshPort,
    [Alias('ServerUser')][string]$RelayUser,
    [Alias('RemotePort')][int]$TunnelPort,
    [int]$Retries = -1,
    [string[]]$LoginKey,
    [switch]$KeepAwake,
    [switch]$NoVpn,
    [string]$Python,
    [string[]]$PythonPackages,
    [switch]$Yes,
    [switch]$Status,
    [switch]$Pause,
    [switch]$Resume,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---- Administrator rights -------------------------------------------------------------------------------

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Re-run as administrator with the same options; an encoded command avoids every quoting problem
    $parts = @("& '$($PSCommandPath -replace "'", "''")'")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $parts += "-$k" } }
        elseif ($v -is [array]) { $parts += "-$k " + (($v | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') }
        else { $parts += "-$k '" + ("$v" -replace "'", "''") + "'" }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parts -join ' '))
    Write-Host 'revtunnel needs administrator rights. Windows will ask you to allow it;'
    Write-Host 'setup then continues in a NEW window. You can close this one.'
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit
}

# ---- Constants and helpers --------------------------------------------------------------------------------

$Root = Join-Path $env:ProgramData 'revtunnel'
$SetupLog = "$Root\setup.log"
$SshDir = "$env:SystemRoot\System32\OpenSSH"
$AuthKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
$Line = '=' * 78

function Say($text, $color = 'Gray') { Write-Host "    $text" -ForegroundColor $color }
function Ok($text) { Write-Host "    [ok]   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    [!]    $text" -ForegroundColor Yellow }
function Bad($text) { Write-Host "    [x]    $text" -ForegroundColor Red }

$script:StepNo = 0
$script:StepCount = 0
function Step($title, $why) {
    $script:StepNo++
    Write-Host ''
    Write-Host "Step $($script:StepNo) of $($script:StepCount): $title" -ForegroundColor Cyan
    foreach ($l in @($why)) { Say $l 'DarkGray' }
}

function Ask($question, $default) {
    if ($Yes) { return "$default" }
    $a = Read-Host "    $question [$default]"
    if ($a) { $a.Trim() } else { "$default" }
}

function AskInt($question, $default, $min, $max) {
    while ($true) {
        $a = Ask $question $default
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        if ($Yes) { throw "$question`: '$a' is not a number from $min to $max" }
        Warn "Please enter a number from $min to $max."
    }
}

function AskYesNo($question, $default) {
    if ($Yes) { return $default }
    $d = if ($default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = Read-Host "    $question [$d]"
        if (-not $a) { return $default }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$') { return $false }
    }
}

function Banner($title, [string[]]$lines) {
    Write-Host ''
    Write-Host $Line -ForegroundColor Yellow
    Write-Host "  $title" -ForegroundColor Yellow
    Write-Host $Line -ForegroundColor Yellow
    foreach ($l in $lines) { Write-Host "  $l" }
    Write-Host $Line -ForegroundColor Yellow
}

function Invoke-Logged($exe, [string[]]$arguments) {
    # Runs a program with its output going to setup.log instead of the screen; returns its exit code
    $ErrorActionPreference = 'Continue'  # stderr lines must not stop the script (Windows PowerShell 5.1)
    Add-Content $SetupLog "`r`n$(Get-Date -Format s) > $exe $($arguments -join ' ')"
    & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Add-Content $SetupLog
    $LASTEXITCODE
}

function Get-Paths($n) {
    $d = "$Root\$n"
    @{ Dir = $d; Conf = "$d\tunnel.json"; Key = "$d\id_ed25519"; Loop = "$d\tunnel.ps1"; Log = "$d\tunnel.log";
       Task = "revtunnel $n"; Desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) "revtunnel-$n-relay-step.txt";
       Paused = "$d\paused" }
}

function KeyLabel($k) {
    $f = $k -split '\s+', 3
    if ($f.Count -ge 3 -and $f[2]) { $f[2] } else { "$($f[0]) ...$($f[1].Substring([Math]::Max(0, $f[1].Length - 8)))" }
}

function Protect($path) {
    # Exactly SYSTEM + Administrators, owned by Administrators, nothing inherited. icacls /grant:r keeps other
    # accounts' entries (seen: the setup user's, inherited by the key), and ssh.exe refuses a key that any
    # other account can read.
    $dir = Test-Path $path -PathType Container
    $sd = if ($dir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $sd.SetSecurityDescriptorSddlForm($(if ($dir) { 'O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)' } else { 'O:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)' }))
    Set-Acl -Path $path -AclObject $sd
}

function Read-Log($path) {
    # The tunnel keeps its log open; open it with sharing (Get-Content can't)
    if (-not (Test-Path $path)) { return '' }
    $f = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader $f).ReadToEnd() } finally { $f.Close() }
}

# Plain-language meanings of ssh's messages, first match wins
$Meanings = @(
    # key-file problems first: ssh then also reports "Permission denied"
    @('bad permissions|UNPROTECTED PRIVATE KEY', "Windows refused this computer's own tunnel key file because of its permissions (not a relay problem): run setup again and choose 'Go through the whole setup again' to fix them."),
    @('Permission denied', "The relay doesn't know this computer's tunnel key (yet): the relay step is needed."),
    @('remote port forwarding failed', "The relay refused the port: it's set up for another port for this key, or a tunnel that just dropped still holds it (it frees up within a minute)."),
    @('Could not resolve hostname', "The relay's name wasn't found: check the address."),
    @('Connection refused', "The relay was reached, but nothing answers on that SSH port: check the port."),
    @('timed out', "No answer from the relay: check the address and port, or a firewall / the network blocks it."),
    @('Network is unreachable|No route to host', 'This computer has no network route to the relay: check the internet connection.'),
    @('IDENTIFICATION HAS CHANGED|Host key verification failed', "The relay's identity changed (e.g. it was rebuilt): re-run setup to trust it again."),
    @('gave up after', 'The tunnel stopped retrying (the retry limit was reached): restart this computer or re-run setup.')
)

function Get-TunnelState($p) {
    # From the log: up / connecting / down, the time, and the reason when down (or paused, from its marker)
    if (Test-Path $p.Paused) {
        return @{ State = 'paused'; Detail = "paused since $((Get-Content $p.Paused -Raw).Trim()); to resume it, run this setup again (option 7)" }
    }
    $log = Read-Log $p.Log
    $i = $log.LastIndexOf('connecting to ')
    if ($i -lt 0) { return @{ State = 'not started'; Detail = '' } }
    $start = $log.LastIndexOf("`n", $i) + 1
    $session = $log.Substring($start)
    $when = $session.Substring(0, [Math]::Min(19, $session.Length)) -replace 'T', ' '
    if ($session -match 'gave up after') { return @{ State = 'stopped'; Detail = $Meanings[-1][1] } }
    if ($session -match 'disconnected \(exit') {
        foreach ($m in $Meanings) { if ($session -match $m[0]) { return @{ State = 'down'; Detail = $m[1]; When = $when } } }
        return @{ State = 'down'; Detail = "See the log: $($p.Log)"; When = $when }
    }
    if ($session -match 'Authenticated to') { return @{ State = 'up'; Detail = "connected since $when"; When = $when } }
    # still trying: say why the attempt before this one failed, if it did
    $previous = $log.Substring(0, $start)
    if ($previous -match 'disconnected \(exit') {
        foreach ($m in $Meanings) { if ($previous.Substring([Math]::Max(0, $previous.LastIndexOf('connecting to '))) -match $m[0]) {
            return @{ State = 'retrying'; Detail = "last attempt failed: $($m[1])"; When = $when } } }
    }
    @{ State = 'connecting'; Detail = "trying since $when"; When = $when }
}

function Stop-Tunnel($p) {
    try { Stop-ScheduledTask -TaskName $p.Task -ErrorAction SilentlyContinue } catch {}
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
        Where-Object { $_.CommandLine -like "*$($p.Dir)\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Tunnel($p) {
    Stop-Tunnel $p
    if (Test-Path $p.Log) { Move-Item -Force $p.Log "$($p.Log).old" }
    Start-ScheduledTask -TaskName $p.Task
}

function Wait-Tunnel($p) {
    # Returns the state once the first connection attempt has an outcome (or after ~35 s)
    for ($i = 0; $i -lt 35; $i++) {
        Start-Sleep 1
        $log = Read-Log $p.Log
        if ($log -match 'Authenticated to') { Start-Sleep 3; break }  # a refused port ends it right after login
        if ($log -match 'disconnected \(exit') { break }
    }
    Get-TunnelState $p
}

function Get-Tunnels {
    if (-not (Test-Path $Root)) { return @() }
    @(Get-ChildItem $Root -Directory | Where-Object { Test-Path "$($_.FullName)\tunnel.json" } | ForEach-Object { $_.Name })
}

function Show-Status([string[]]$names) {
    if (-not $names) { Say 'No tunnels are set up on this computer yet.'; return }
    foreach ($n in $names) {
        $p = Get-Paths $n
        $c = Get-Content $p.Conf -Raw | ConvertFrom-Json
        $task = (Get-ScheduledTask -TaskName $p.Task -ErrorAction SilentlyContinue)
        $s = Get-TunnelState $p
        $color = @{ up = 'Green'; connecting = 'Yellow'; retrying = 'Yellow'; paused = 'Cyan' }[$s.State]; if (-not $color) { $color = 'Red' }
        Write-Host ''
        Write-Host "    Tunnel '$n': $($s.State.ToUpper())" -ForegroundColor $color
        if ($s.Detail) { Say "  $($s.Detail)" }
        Say "  relay $($c.Host) (SSH port $($c.Port), user $($c.User)); relay port $($c.RemotePort) -> this computer's port $($c.LocalPort)"
        Say "  retries: $(if ($c.Retries -gt 0) { "$($c.Retries) in a row" } else { 'never gives up' }); task: $(if ($task) { $task.State } else { 'MISSING' }); log: $($p.Log)"
    }
}

function Show-Outcome($p, $c, $s) {
    # Says how a (re)connect went
    if ($s.State -eq 'up') { Ok "The tunnel is up ($($s.Detail))." }
    elseif ($s.Detail -match 'relay step') { Bad $s.Detail; Write-RelayStep $p $c (Get-Content "$($p.Key).pub" -Raw).Trim() }
    else { Bad "The tunnel is not up: $($s.Detail)"; Say 'It keeps retrying in the background.' }
}

function Suspend-Tunnel($p) {
    Stop-Tunnel $p
    Disable-ScheduledTask -TaskName $p.Task -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path $p.Paused -Encoding ascii -Value (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Ok "Tunnel '$Name' paused: it's stopped, and stays off after a restart. Its key and settings are kept."
    Say 'To resume it, run this setup again (option 7), or with -Resume.'
}

function Resume-Tunnel($p, $c) {
    # Returns the state after the first attempt
    Remove-Item -Force $p.Paused -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName $p.Task -ErrorAction SilentlyContinue | Out-Null
    Say 'Connecting ...'
    Start-Tunnel $p
    $s = Wait-Tunnel $p
    Show-Outcome $p $c $s
    $s
}

function Write-RelayStep($p, $c, $pub) {
    $lines = @(
        "Do this on the RELAY ($($c.Host)), not on this computer. It lets this computer's tunnel in.",
        '',
        '1. Log in to the relay as root (or as a user who can use sudo).',
        '2. Put revtunnel-relay.sh there: it comes with revtunnel, next to this script. For example,',
        "   from this computer:  scp revtunnel-relay.sh root@$($c.Host):",
        '3. On the relay, run this one line:',
        "     sudo bash revtunnel-relay.sh '$pub' $($c.RemotePort) $($c.User)",
        '   or just "sudo bash revtunnel-relay.sh" and paste this computer''s key when it asks.',
        '4. When the relay says "Done", come back to this computer.',
        '',
        "This computer's tunnel key (one line):",
        $pub
    )
    Set-Content -Path $p.Desktop -Encoding ascii -Value (@("revtunnel - relay step for tunnel '$Name' on $env:COMPUTERNAME (the target)", '') + $lines)
    Banner 'ACTION NEEDED - on the RELAY' ($lines + @('', "(All of this is also in a text file on this computer's Desktop: $(Split-Path -Leaf $p.Desktop))"))
}

# ---- Status only / which tunnel ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force $Root | Out-Null
Protect $Root

Write-Host ''
Write-Host 'revtunnel - reverse SSH tunnel from this computer to a relay' -ForegroundColor Cyan
$existing = @(Get-Tunnels)

if ($Status) { Show-Status $(if ($Name) { @($Name) } else { $existing }); exit }

if (-not $Name) {
    if ($existing.Count -gt 0 -and -not $Yes) {
        Say 'Tunnels already set up on this computer:'
        Show-Status $existing
        Write-Host ''
        Say 'To change one, type its name. To set up another one, type a new name.'
    }
    $default = if ($existing.Count -gt 0) { $existing[0] } else { 'main' }
    do { $Name = Ask 'Tunnel name (letters, digits, - or _)' $default } until ($Name -match '^[A-Za-z0-9_-]+$')
}
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw "Bad tunnel name: $Name (letters, digits, - or _)" }
$P = Get-Paths $Name
$isNew = -not (Test-Path $P.Conf)

if ($Pause -or $Resume) {
    if ($isNew) { Bad "There is no tunnel '$Name' on this computer."; exit 1 }
    $c = Get-Content $P.Conf -Raw | ConvertFrom-Json
    if ($Pause) {
        if (Test-Path $P.Paused) { Say "Tunnel '$Name' is already paused (since $((Get-Content $P.Paused -Raw).Trim()))." }
        else { Suspend-Tunnel $P }
        exit 0
    }
    if (-not (Test-Path $P.Paused)) { Say "Tunnel '$Name' isn't paused; reconnecting it." }
    $s = @(Resume-Tunnel $P $c)[-1]
    if ($s.State -eq 'up') { exit 0 } else { exit 1 }
}

if ($Remove) {
    if ($isNew) { Say "There is no tunnel '$Name' on this computer."; exit }
    $c = Get-Content $P.Conf -Raw | ConvertFrom-Json
    Stop-Tunnel $P
    Unregister-ScheduledTask -TaskName $P.Task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $P.Dir
    Remove-Item -Force $P.Desktop -ErrorAction SilentlyContinue
    Ok "Tunnel '$Name' removed from this computer (task, key and settings)."
    Say "On the relay ($($c.Host)), remove its port too:  sudo bash revtunnel-relay.sh --remove $($c.RemotePort)"
    Say 'The SSH server and the login keys stay; other tunnels may use them.'
    exit
}

# ---- Re-run menu -----------------------------------------------------------------------------------------

$c = if ($isNew) { [pscustomobject]@{ Host = ''; Port = 22; User = 'tunnel'; RemotePort = 2222; LocalPort = 22; Retries = 0 } }
     else { Get-Content $P.Conf -Raw | ConvertFrom-Json }
# extras only apply to a whole setup, so presets that always pass them still get the re-run menu
$changeParams = $PSBoundParameters.Keys | Where-Object { $_ -notin 'Name', 'Yes', 'KeepAwake', 'NoVpn', 'Python', 'PythonPackages' }
$action = 'all'
if (-not $isNew -and -not $Yes -and -not $changeParams) {
    Write-Host ''
    Show-Status @($Name)
    Write-Host ''
    $isPaused = Test-Path $P.Paused
    Say 'What would you like to do?'
    if (-not $isPaused) { Say '  1  Reconnect now (restart the tunnel)' }
    Say '  2  Change the relay address (or other relay details)'
    if ($c.LocalPort -eq 22) { Say '  3  Allow another key to log in to this computer' }
    Say '  4  Show the relay step again'
    Say '  5  Go through the whole setup again'
    Say '  6  Remove this tunnel'
    if ($isPaused) { Say '  7  Resume the tunnel (start it now, and from startup again)' }
    else { Say '  7  Pause the tunnel (stop it, also after a restart; its setup stays for later)' }
    Say '  8  Nothing (quit)'
    $choice = Ask 'Choice' '8'
    switch ($choice) {
        '1' {
            if ($isPaused) { Resume-Tunnel $P $c | Out-Null; exit }
            Say 'Connecting ...'
            Start-Tunnel $P
            $s = Wait-Tunnel $P
            Show-Outcome $P $c $s
            exit
        }
        '2' { $action = 'relay' }
        '3' { $action = 'keys' }
        '4' { Write-RelayStep $P $c (Get-Content "$($P.Key).pub" -Raw).Trim(); exit }
        '5' { $action = 'all' }
        '6' { & $PSCommandPath -Name $Name -Remove; exit }
        '7' { if ($isPaused) { Resume-Tunnel $P $c | Out-Null } else { Suspend-Tunnel $P }; exit }
        default { exit }
    }
}

# ---- Plan the steps --------------------------------------------------------------------------------------

if ($action -eq 'all') {
    if ($TargetPort) { $c.LocalPort = $TargetPort }
    elseif (-not $Yes) {
        Write-Host ''
        Say 'Where should the tunnel lead on this computer? 22 = SSH logins (the usual choice; sets up the'
        Say "computer's SSH server). Another port forwards to that program instead, e.g. 3389 for Remote Desktop."
        $c.LocalPort = AskInt 'Port on this computer' $c.LocalPort 1 65535
    }
}
$doSsh = $action -eq 'all' -and $c.LocalPort -eq 22
$doKeys = ($action -eq 'all' -and $c.LocalPort -eq 22) -or $action -eq 'keys'
$doExtras = $action -eq 'all'
$doRelay = $action -in 'all', 'relay'
$script:StepCount = @($doSsh, $doKeys, $doExtras, $doRelay, $doRelay | Where-Object { $_ }).Count

# ---- SSH server on this computer -------------------------------------------------------------------------------

if ($doSsh) {
    Step "This computer's SSH server" @('People log in to this computer with SSH through the tunnel, so this computer needs an SSH server.',
        'It only listens on this computer itself (127.0.0.1), so the tunnel is the only way in, and only keys work.',
        'On a fresh Windows this can take a few minutes.')
    foreach ($cap in 'OpenSSH.Client~~~~0.0.1.0', 'OpenSSH.Server~~~~0.0.1.0') {
        if ((Get-WindowsCapability -Online -Name $cap).State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap | Out-Null }
    }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd  # the first start writes sshd_config and the host keys
    $cfg = "$env:ProgramData\ssh\sshd_config"
    $text = (Get-Content $cfg -Raw) -replace '(?s)# (revtunnel|mihomo-tester): begin.*?# (revtunnel|mihomo-tester): end\r?\n', ''
    $ours = "# revtunnel: begin`r`nListenAddress 127.0.0.1`r`nPasswordAuthentication no`r`n# revtunnel: end`r`n"
    Set-Content -Path $cfg -Value ($ours + $text) -Encoding ascii -NoNewline
    if (-not (Test-Path HKLM:\SOFTWARE\OpenSSH)) { New-Item HKLM:\SOFTWARE\OpenSSH | Out-Null }
    New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -PropertyType String -Force `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
    Restart-Service sshd
    Ok 'SSH server running: this computer only (127.0.0.1:22), keys only, PowerShell as the shell'
} elseif ($action -eq 'all' -and (Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0').State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null  # the tunnel itself needs ssh.exe
}

# ---- Who may log in --------------------------------------------------------------------------------------

if ($doKeys) {
    Step 'Who may log in to this computer' @('Paste the PUBLIC SSH key of each machine people will log in FROM: usually your own computer',
        '(with "ssh -J" through the relay), or the relay itself if you log in from there. This computer checks',
        'the key of the machine that makes the last hop to it. A public key is one line starting with ssh-ed25519,',
        'ssh-rsa or ecdsa-, e.g. ~/.ssh/id_ed25519.pub (show it: cat ~/.ssh/id_ed25519.pub; make one:',
        'ssh-keygen -t ed25519). Never paste a PRIVATE key (it starts with -----BEGIN).',
        'The Windows user they log in as is the one running this setup.')
    $have = @(if (Test-Path $AuthKeys) { Get-Content $AuthKeys | Where-Object { $_.Trim() } })
    if ($have) { Say "Already allowed: $(($have | ForEach-Object { KeyLabel $_ }) -join ', ')" }
    $new = @($LoginKey | Where-Object { $_ })
    if (-not $Yes) {
        Say 'Paste one key and press Enter; repeat for more. Press Enter on an empty line when done.'
        while ($true) {
            $k = (Read-Host '    Key').Trim()
            if (-not $k) { break }
            if ($k -match 'PRIVATE KEY') { Bad 'That is a PRIVATE key. Never share it; paste the .pub file instead.'; continue }
            if ($k -notmatch '^(ssh-|ecdsa-|sk-)\S+ \S+') { Warn 'That is not a public SSH key (see above). Try again, or press Enter to finish.'; continue }
            $new += $k
        }
    }
    foreach ($k in $new) {
        if ($have -contains $k) { Say "Already allowed: $(KeyLabel $k)"; continue }
        Add-Content -Path $AuthKeys -Value $k -Encoding ascii
        $have += $k
        Ok "Added: $(KeyLabel $k)"
    }
    if (Test-Path $AuthKeys) {
        Protect $AuthKeys  # sshd wants it owned by Administrators or SYSTEM, and readable by nobody else
    }
    if ($have) { Ok "$($have.Count) key(s) may log in as $env:USERNAME" }
    else { Warn 'No keys yet, so nobody can log in. Re-run setup and choose "Allow another key" to add one.' }
    if ($action -eq 'keys') { exit }
}

# ---- Extras ----------------------------------------------------------------------------------------------

if ($doExtras) {
    Step 'Optional extras' @('Things that help when this computer runs unattended. Skip what you don''t need.')

    if ($KeepAwake -or (-not $PSBoundParameters.ContainsKey('KeepAwake') -and
            (AskYesNo 'Keep this computer awake when plugged in? (a sleeping computer drops the tunnel)' $false))) {
        powercfg /change standby-timeout-ac 0 | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null
        Ok 'This computer no longer sleeps on mains power'
    }

    if ($NoVpn -or (-not $PSBoundParameters.ContainsKey('NoVpn') -and
            (AskYesNo 'Turn off VPNs? (a VPN can carry or break the tunnel; say yes if unsure what runs here)' $false))) {
        $found = $false
        $vpns = @(Get-VpnConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)
        foreach ($v in $vpns | Where-Object { $_.ConnectionStatus -eq 'Connected' }) {
            rasdial.exe $v.Name /disconnect | Out-Null
            Ok "Disconnected VPN connection '$($v.Name)'"
            $found = $true
        }
        $pattern = 'VPN|Tunnel|\bTUN\b|TAP-Win|Wintun|WireGuard|OpenVPN|Tailscale|ZeroTier|AnyConnect|Fortinet|' +
            'GlobalProtect|PANGP|Juniper|Pulse Secure|SonicWall|NordLynx|Mullvad|Hamachi|\bMeta\b|Mihomo|Clash|' +
            'sing-box|v2ray|Xray'
        foreach ($a in Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' -and "$($_.Name) $($_.InterfaceDescription)" -match $pattern }) {
            Disable-NetAdapter -Name $a.Name -Confirm:$false
            Ok "Turned off network adapter '$($a.Name)' ($($a.InterfaceDescription))"
            Say "       to turn it back on: Enable-NetAdapter -Name '$($a.Name)'"
            $found = $true
        }
        if ($found) {
            Warn 'Also turn off the VPN in its own app (its "TUN" or auto-connect setting), or it comes back.'
        } else { Ok 'No VPN found' }
    }

    $wantPython = $Python
    if (-not $wantPython -and -not $Yes) {
        while ($true) {
            $wantPython = (Read-Host '    Install Python? Type a version such as 3.13 (or y for 3.13), or press Enter to skip').Trim()
            if ($wantPython -match '^(y|yes)$') { $wantPython = '3.13' }
            if ($wantPython -match '^(n|no)$') { $wantPython = '' }
            if (-not $wantPython -or $wantPython -match '^\d+(\.\d+)*$') { break }
            Warn 'Type a version number such as 3.13, y, or press Enter to skip.'
        }
    }
    if ($wantPython) {
        Say "Installing Python $wantPython (details go to $SetupLog) ..."
        if (-not (Get-Command py.exe -ErrorAction SilentlyContinue) -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Invoke-Logged winget.exe @('install', '-e', '--id', 'Python.PythonInstallManager', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
        }
        if (Get-Command py.exe -ErrorAction SilentlyContinue) {
            Invoke-Logged py.exe @('install', '-y', $wantPython) | Out-Null
        }
        $version = ''
        if (Get-Command py.exe -ErrorAction SilentlyContinue) {
            $ErrorActionPreference = 'Continue'; $version = "$(& py.exe "-V:$wantPython" --version 2>&1)"; $ErrorActionPreference = 'Stop'
        }
        if ($version -match '^Python \d') {
            Ok "$version (run it with: py -V:$wantPython)"
            foreach ($pkg in @($PythonPackages | Where-Object { $_ })) {
                $rc = Invoke-Logged py.exe @("-V:$wantPython", '-m', 'pip', 'install', '--disable-pip-version-check', '--only-binary', ':all:', $pkg)
                if ($rc -eq 0) { Ok "Python package $pkg" }
                else { Warn "No ready-made $pkg for Python $wantPython (details in $SetupLog); an older Python may have one" }
            }
        } else {
            Bad "Python $wantPython could not be installed (details in $SetupLog)."
            Say '       Install it by hand from https://www.python.org/downloads/ and re-run setup.'
        }
    }
}

# ---- Relay details --------------------------------------------------------------------------------------

if ($doRelay) {
    Step 'The relay' @('The relay is a computer with a fixed address that this computer can reach, e.g. a VPS. This computer',
        'keeps a connection open to it, and you reach this computer from there. Press Enter to keep a value in [ ].')
    if ($Relay) { $c.Host = $Relay }
    do { $c.Host = (Ask "Relay address (IP or host name)" $c.Host).Trim('[', ']') } until ($c.Host -or $Yes)
    if (-not $c.Host) { throw 'No relay address: give -Relay.' }
    $c.Port = if ($RelaySshPort) { $RelaySshPort } else { AskInt "Relay's SSH port" $c.Port 1 65535 }
    $c.User = if ($RelayUser) { $RelayUser } else { Ask 'User on the relay that holds the tunnel (the relay step creates it)' $c.User }
    $c.RemotePort = if ($TunnelPort) { $TunnelPort } else { AskInt 'Port on the relay that leads to this computer (each target needs its own, e.g. 2222, 2223, ...)' $c.RemotePort 1024 65535 }
    if ($Retries -ge 0) { $c | Add-Member -Force Retries $Retries }
    else { $c | Add-Member -Force Retries (AskInt 'Reconnect attempts before giving up (0 = never give up)' $(if ($null -ne $c.Retries) { $c.Retries } else { 0 }) 0 1000000) }
    New-Item -ItemType Directory -Force $P.Dir | Out-Null
    $c | ConvertTo-Json | Set-Content -Path $P.Conf -Encoding ascii
    Ok "Relay $($c.Host), port $($c.RemotePort) there leads to port $($c.LocalPort) here"

# ---- The tunnel ------------------------------------------------------------------------------------------

    Step 'Start the tunnel' @("Makes this computer's own key for the tunnel (separate from the login keys), then connects.",
        'The first time, the relay does not know this computer yet: you will be asked to do the relay step.')
    if (-not (Test-Path $P.Key)) {
        $proc = Start-Process "$SshDir\ssh-keygen.exe" -Wait -NoNewWindow -PassThru `
            -ArgumentList "-q -t ed25519 -N `"`" -C revtunnel-$Name-$env:COMPUTERNAME -f `"$($P.Key)`""
        if ($proc.ExitCode -ne 0) { throw 'ssh-keygen failed' }
    }
    # ssh-keygen makes the user running this the key's owner; ssh.exe running as SYSTEM refuses that
    Protect $P.Dir
    Protect $P.Key
    Protect "$($P.Key).pub"
    $pub = (Get-Content "$($P.Key).pub" -Raw).Trim()
    # trust the relay's host key afresh (the relay or its address may have changed)
    Remove-Item "$($P.Dir)\known_hosts" -ErrorAction SilentlyContinue

    Set-Content -Path $P.Loop -Encoding ascii -Value @'
# Written by revtunnel-target-windows.ps1; run as SYSTEM by the "revtunnel NAME" task. Keeps the tunnel up.
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log = "$Dir\tunnel.log"
$fails = 0
while ($true) {
    $c = Get-Content "$Dir\tunnel.json" -Raw | ConvertFrom-Json
    if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) { Move-Item -Force $Log "$Log.old" }
    Add-Content $Log "$(Get-Date -Format s) connecting to $($c.User)@$($c.Host) port $($c.Port)"
    $start = Get-Date
    # ssh's messages go to the log through cmd.exe, which lets others read the file meanwhile ("ssh -E"
    # locks it). No paths here contain spaces or quotes, so plain words are safe on cmd's command line.
    cmd.exe /c ("$env:SystemRoot\System32\OpenSSH\ssh.exe -N -i $Dir\id_ed25519 -p $($c.Port) " +
        '-o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o LogLevel=VERBOSE ' +
        '-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 ' +
        "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$Dir\known_hosts " +
        "-R 127.0.0.1:$($c.RemotePort):127.0.0.1:$($c.LocalPort) $($c.User)@$($c.Host) 2>>$Log")
    $code = $LASTEXITCODE
    if (((Get-Date) - $start).TotalSeconds -ge 60) { $fails = 0 }  # it was up: count failures afresh
    $fails++
    if ($c.Retries -gt 0 -and $fails -gt $c.Retries) {
        Add-Content $Log "$(Get-Date -Format s) disconnected (exit $code); gave up after $($c.Retries) attempts (restart this computer or re-run setup)"
        exit 0
    }
    $of = if ($c.Retries -gt 0) { " of $($c.Retries)" } else { '' }
    Add-Content $Log "$(Get-Date -Format s) disconnected (exit $code); reconnecting in 15 s (attempt $fails$of)"
    Start-Sleep 15
}
'@
    $taskAction = New-ScheduledTaskAction -Execute powershell.exe `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($P.Loop)`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    Stop-Tunnel $P
    Remove-Item -Force $P.Paused -ErrorAction SilentlyContinue  # a setup un-pauses
    Register-ScheduledTask -TaskName $P.Task -Action $taskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Settings $settings -Principal $principal -Force | Out-Null

    Say 'Connecting ...'
    Start-Tunnel $P
    $s = Wait-Tunnel $P
    $shown = $false
    while ($s.State -ne 'up') {
        if (($s.State -in 'down', 'retrying') -and $s.Detail -match 'relay step') {
            if (-not $shown) {
                Say "That's expected the first time: the relay doesn't know this computer yet."
                Write-RelayStep $P $c $pub
                $shown = $true
            } else {
                # once is enough; then say what to check
                Bad "The relay still doesn't accept this computer's tunnel key (it ends in ...$($pub.Split(' ')[1].Substring($pub.Split(' ')[1].Length - 8)))."
                Say "       On the relay, 'sudo bash revtunnel-relay.sh --list' shows the key it has for port $($c.RemotePort)"
                Say "       (named $(($pub -split ' ')[2])). Same port and user on both sides? Option 4 of the re-run menu shows the step again."
            }
        } else {
            Bad "The tunnel is not up: $($s.Detail)"
        }
        if ($Yes) { Warn 'The tunnel keeps retrying in the background; it connects once that is fixed.'; break }
        $a = Read-Host '    Press Enter here when that is done to try again (or type q to stop; the tunnel keeps retrying)'
        if ($a -match '^q') { break }
        Say 'Connecting ...'
        Start-Tunnel $P
        $s = Wait-Tunnel $P
    }

    # ---- Summary -----------------------------------------------------------------------------------------
    $listening = @(Get-NetTCPConnection -State Listen -LocalPort $c.LocalPort -ErrorAction SilentlyContinue)
    $lines = @()
    if ($s.State -eq 'up') {
        $lines += "The tunnel is UP: port $($c.RemotePort) on $($c.Host) leads to port $($c.LocalPort) on this computer."
    } else {
        $lines += 'The tunnel is NOT up yet. It keeps retrying in the background and connects once fixed.'
    }
    if (-not $listening) { $lines += "Note: nothing on this computer listens on port $($c.LocalPort) yet, so the tunnel leads nowhere until it does." }
    $lines += ''
    if ($c.LocalPort -eq 22) {
        $lines += 'To log in to this computer: first log in to the relay, then run there:'
        $lines += "    ssh -p $($c.RemotePort) $env:USERNAME@127.0.0.1"
        $lines += 'Or in one go from your own computer (not this computer), if it can log in to the relay as root:'
        $lines += "    ssh -J root@$($c.Host) -p $($c.RemotePort) $env:USERNAME@127.0.0.1"
        $lines += 'Only the keys allowed in "Who may log in" work for this computer (passwords are off); the jump'
        $lines += 'to the relay uses your usual login there.'
    } else {
        $lines += "To reach port $($c.LocalPort) of this computer from your own computer (not this computer), open a forward through the relay:"
        $lines += "    ssh -L $($c.LocalPort):127.0.0.1:$($c.RemotePort) root@$($c.Host)"
        $lines += "and, while that runs, connect your program to localhost:$($c.LocalPort)."
    }
    $lines += ''
    $lines += "It runs by itself from startup (task ""$($P.Task)""), also when nobody is signed in, and reconnects"
    $lines += "every 15 s if it drops$(if ($c.Retries -gt 0) { " (gives up after $($c.Retries) failed attempts in a row)" })."
    $lines += 'Status, pausing, a new relay address, more login keys or removal: run this setup again.'
    $lines += "Log: $($P.Log)"
    Banner $(if ($s.State -eq 'up') { 'DONE' } else { 'SET UP, BUT NOT CONNECTED YET' }) $lines
    if ($s.State -eq 'up') { Remove-Item -Force $P.Desktop -ErrorAction SilentlyContinue }
}
