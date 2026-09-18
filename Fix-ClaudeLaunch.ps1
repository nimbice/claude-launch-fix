<#
Fix-ClaudeLaunch.ps1 - recover when the Claude desktop app will not start and Windows reports
"The process cannot access the file because it is being used by another process" (0x80070020).

Why it happens (diagnosed 2026-09-13): Claude's auto-update quits the app to install a new version.
If a process from the old version fails to exit, the old version's app sandbox stays alive and keeps
Claude's per-user package registry hive loaded (...\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\
Helium), so Windows cannot create the sandbox for the new version. Settings > Apps > Repair does not
stop that process; stopping the process does.

Two kinds of leftover are looked for:
  1. processes that still carry an OLDER version's package identity (tasklist /apps shows them);
  2. processes spawned from a Claude Code session - the CLI under ...\Claude\claude-code\, its shells
     and whatever they started. They carry no package identity, so tasklist /apps does not list
     them, but they were started inside the sandbox and keep it alive.

Run: double-click Fix-ClaudeLaunch.cmd, or
     powershell -NoProfile -ExecutionPolicy Bypass -File Fix-ClaudeLaunch.ps1 [-DryRun]
-DryRun only reports what it finds; it never stops or launches anything.
Run it as administrator if the normal run finds nothing: processes started elevated are invisible otherwise.
#>
param([switch]$DryRun)

$logFile = Join-Path $PSScriptRoot 'Fix-ClaudeLaunch.log'

function Write-Log([string]$Text) {
    Write-Host $Text
    if (-not $DryRun) {
        Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text)
    }
}

function Confirm-Step([string]$Question) {
    if ($DryRun) { Write-Host "[dry run] would ask: $Question"; return $false }
    return (Read-Host "$Question [y/N]") -match '^(y|yes)$'
}

function Format-Procs($Procs) {
    ($Procs | Sort-Object Stale, Role | Format-Table PID, Image, Role, Package, Started -AutoSize | Out-String -Width 250).TrimEnd()
}

# Evidence for a bug report, and hints when the normal fix did not help.
function Write-Diagnostics {
    Write-Log '--- diagnostics ---'
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log "Running elevated: $elevated" + $(if (-not $elevated) { '  (processes started as administrator were invisible above; try again as administrator)' })
    $svc = Get-CimInstance Win32_Service -Filter "Name='CoworkVMService'" -ErrorAction SilentlyContinue
    if ($svc) { Write-Log "CoworkVMService: $($svc.State), PID $($svc.ProcessId), $($svc.PathName)" }
    $hive = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium'
    foreach ($f in 'User.dat', 'UserClasses.dat') {
        $p = Join-Path $hive $f
        if (-not (Test-Path $p)) { Write-Log "$f : absent"; continue }
        try { $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite'); $fs.Close(); Write-Log "$f : not locked (the sandbox is gone; the launch error has another cause)" }
        catch { Write-Log "$f : LOCKED - something still holds the old sandbox open" }
    }
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AppModel-Runtime/Admin'; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Claude_' } | Select-Object -First 12
    foreach ($e in $events) {
        $m = ($e.Message -replace '\s+', ' ')
        Write-Log ('event {0} {1:HH:mm:ss} {2}' -f $e.Id, $e.TimeCreated, $m.Substring(0, [Math]::Min(160, $m.Length)))
    }
}

$cim = @{}
Get-CimInstance Win32_Process | ForEach-Object { $cim[[int]$_.ProcessId] = $_ }

$pkg = Get-AppxPackage -Name Claude | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
if ($pkg) {
    Write-Log "Installed package: $($pkg.PackageFullName)"

    # tasklist /apps shows which processes carry a package identity (i.e. live in Claude's sandbox).
    # cowork-svc.exe is skipped: it is a SYSTEM service and the updater recycles it correctly.
    $claudeProcs = @(tasklist /apps /fo csv | ConvertFrom-Csv |
        Where-Object { $_.'Package Name' -like 'Claude_*' } |
        ForEach-Object {
            $id = [int]$_.PID
            $image = $_.'Image Name' -replace '\s*\(.*\)$', ''
            $proc = $cim[$id]
            $cmd = if ($proc) { [string]$proc.CommandLine } else { '' }
            $role = $image
            if ($image -ieq 'claude.exe') {
                $role = 'main'
                if ($cmd -match '--type=(\S+)') { $role = $Matches[1] }
                if ($cmd -match '--utility-sub-type=(\S+)') { $role += ':' + $Matches[1] }
            }
            [pscustomobject]@{
                PID     = $id
                Image   = $image
                Role    = $role
                Package = $_.'Package Name'
                Started = if ($proc) { $proc.CreationDate } else { $null }
                Stale   = ($_.'Package Name' -ne $pkg.PackageFullName)
                Cmd     = $cmd
            }
        } |
        Where-Object { $_.Image -ine 'cowork-svc.exe' })
} else {
    # Not the Store build. The .exe-installer build is blocked the same way when a claude.exe never
    # exits, so offer the generic version of the fix. The Claude Code CLI is also named claude.exe
    # (it lives under ...\Claude\claude-code\) and is handled as a leftover below.
    Write-Log 'The Store (MSIX) build of Claude is not installed for this user; checking for leftover claude.exe processes instead.'
    $claudeProcs = @($cim.Values |
        Where-Object { $_.Name -ieq 'claude.exe' -and $_.ExecutablePath -notmatch '\\claude-code\\' } |
        ForEach-Object {
            $cmd = [string]$_.CommandLine
            $role = 'main'
            if ($cmd -match '--type=(\S+)') { $role = $Matches[1] }
            [pscustomobject]@{
                PID     = [int]$_.ProcessId
                Image   = $_.Name
                Role    = $role
                Package = [string]$_.ExecutablePath
                Started = $_.CreationDate
                Stale   = $false
                Cmd     = $cmd
            }
        })
}

# Leftovers without package identity: the Claude Code CLI, anything running from Claude's install
# folder that tasklist /apps missed, and every descendant of those. This script's own process tree
# is left alone so it can finish.
$seen = @{}
$claudeProcs | ForEach-Object { $seen[$_.PID] = $true }
$me = $PID
while ($me -and $cim[$me]) { $seen[$me] = $true; $me = [int]$cim[$me].ParentProcessId; if ($me -eq 0) { break } }
# A process whose ancestor chain still reaches a running current-version Claude belongs to a live
# session, not to a dead sandbox.
$liveIds = @{}
$claudeProcs | Where-Object { -not $_.Stale } | ForEach-Object { $liveIds[$_.PID] = $true }
function Test-LiveAncestor([int]$Id) {
    $hops = 0
    while ($Id -and $cim[$Id] -and $hops -lt 32) {
        $Id = [int]$cim[$Id].ParentProcessId
        if ($liveIds[$Id]) { return $true }
        $hops++
    }
    return $false
}
$queue = New-Object System.Collections.Queue
$cim.Values | Where-Object {
    -not $seen[[int]$_.ProcessId] -and $_.ExecutablePath -and
    ($_.ExecutablePath -match '\\Claude\\claude-code\\' -or $_.ExecutablePath -like 'C:\Program Files\WindowsApps\Claude_*') -and
    -not (Test-LiveAncestor ([int]$_.ProcessId))
} | ForEach-Object { $queue.Enqueue($_) }
$leftovers = @()
while ($queue.Count -gt 0) {
    $p = $queue.Dequeue()
    $id = [int]$p.ProcessId
    if ($seen[$id]) { continue }
    $seen[$id] = $true
    $leftovers += [pscustomobject]@{
        PID     = $id
        Image   = $p.Name
        Role    = 'no package identity'
        Package = [string]$p.ExecutablePath
        Started = $p.CreationDate
        Stale   = $true
        Cmd     = [string]$p.CommandLine
    }
    $cim.Values | Where-Object { $_.ParentProcessId -eq $id } | ForEach-Object { $queue.Enqueue($_) }
}

if ($claudeProcs.Count -eq 0 -and $leftovers.Count -eq 0) {
    Write-Log 'No Claude processes are running.'
}
if ($claudeProcs.Count -gt 0) { Write-Log (Format-Procs $claudeProcs) }
if ($leftovers.Count -gt 0) {
    Write-Log "$($leftovers.Count) process(es) come from a Claude Code session and carry no package identity; they can hold the old sandbox open:"
    Write-Log (Format-Procs $leftovers)
}

$stale = @($claudeProcs | Where-Object { $_.Stale }) + $leftovers
$current = @($claudeProcs | Where-Object { -not $_.Stale })
$targets = @()

if ($stale.Count -gt 0) {
    $old = @($claudeProcs | Where-Object { $_.Stale }).Count
    if ($old -gt 0) { Write-Log "$old process(es) belong to an OLDER Claude version and block the new one from starting." }
    if (Confirm-Step "Stop these $($stale.Count) old-version/leftover process(es)?") { $targets = $stale }
} elseif ($current.Count -gt 0) {
    if ($pkg) { Write-Log 'No old-version leftovers; these are all the installed version.' }
    if (Confirm-Step 'Is Claude hung or windowless? Stop ALL Claude processes (closes Claude)?') { $targets = $current }
}

if ($DryRun) {
    Write-Host '[dry run] nothing was stopped or launched.'
    exit 0
}

foreach ($t in $targets) {
    try {
        Stop-Process -Id $t.PID -Force -ErrorAction Stop
        Write-Log "Stopped PID $($t.PID): $($t.Image) [$($t.Role)] $($t.Package), started $($t.Started)"
    } catch {
        Write-Log "Could not stop PID $($t.PID): $($_.Exception.Message)"
    }
    if ($t.Cmd) { Write-Log ('    ' + $t.Cmd.Substring(0, [Math]::Min(300, $t.Cmd.Length))) }
}

if ($targets.Count -eq 0 -and ($claudeProcs.Count -gt 0 -or $leftovers.Count -gt 0)) {
    Write-Log 'Nothing stopped, so not relaunching.'
    exit 0
}
if ($targets.Count -gt 0) { Start-Sleep -Seconds 3 }

$launchedAt = Get-Date
if ($pkg) {
    Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($pkg.PackageFamilyName)!Claude"
    Write-Log 'Launched Claude; checking for the sandbox error...'
    Start-Sleep -Seconds 10

    $blocked = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AppModel-Runtime/Admin'; Id = 208, 215; StartTime = $launchedAt } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match '0x80070020' -and $_.Message -match 'Claude_' }
    if ($blocked) {
        Write-Log 'Still blocked (0x80070020).'
        Write-Diagnostics
        Write-Log 'Next: rerun this as administrator if it found nothing; otherwise sign out of Windows and back in (no full reboot needed).'
    } else {
        Write-Log 'No sandbox errors; Claude should be opening.'
    }
} else {
    $exe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (Test-Path $exe) {
        Start-Process $exe
        Write-Log "Launched $exe"
    } else {
        Write-Log 'Could not find claude.exe under %LOCALAPPDATA%\AnthropicClaude; start Claude from the Start menu.'
    }
}
