<#
Fix-ClaudeLaunch.ps1 - recover when the Claude desktop app will not start and Windows reports
"The process cannot access the file because it is being used by another process" (0x80070020).

Why it happens (diagnosed 2026-09-13): Claude's auto-update quits the app to install a new version.
If a process from the old version fails to exit, the old version's app sandbox stays alive and keeps
Claude's per-user package registry hive loaded (...\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\
Helium), so Windows cannot create the sandbox for the new version. Settings > Apps > Repair does not
stop that process; stopping the process does.

Run: double-click Fix-ClaudeLaunch.cmd, or
     powershell -NoProfile -ExecutionPolicy Bypass -File Fix-ClaudeLaunch.ps1 [-DryRun]
-DryRun only reports what it finds; it never stops or launches anything.
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
    # (it lives under ...\Claude\claude-code\) and is left alone.
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

if ($claudeProcs.Count -eq 0) {
    Write-Log 'No Claude processes are running.'
} else {
    Write-Log ($claudeProcs | Sort-Object Stale, Role | Format-Table PID, Image, Role, Package, Started -AutoSize | Out-String -Width 250).TrimEnd()
}

$stale = @($claudeProcs | Where-Object { $_.Stale })
$current = @($claudeProcs | Where-Object { -not $_.Stale })
$targets = @()

if ($stale.Count -gt 0) {
    Write-Log "$($stale.Count) process(es) belong to an OLDER Claude version and block the new one from starting."
    if (Confirm-Step 'Stop them?') { $targets = $stale }
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

if ($targets.Count -eq 0 -and $claudeProcs.Count -gt 0) {
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
        Write-Log 'Still blocked (0x80070020). Sign out of Windows and back in; that clears it without a full reboot.'
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
