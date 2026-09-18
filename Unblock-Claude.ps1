# Unblock-Claude.ps1  (Windows PowerShell 5.1, run elevated)
# Tests suspected holders of the stale Claude AppX container one at a time.
# Relaunches Claude after each step and stops at the first step that fixes it.
# Order: Gradle daemons -> adb server -> Appinfo service restart.
# Do NOT run during a Gradle build or while something depends on adb.

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Not elevated. Rerun as administrator.'; return }

$log = Join-Path $env:TEMP ('Unblock-Claude_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
function Say([string]$m) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $m
    Write-Host $line
    Add-Content -Path $log -Value $line
}

# --- package / AUMID -------------------------------------------------------
$pkg = Get-AppxPackage -Name Claude | Select-Object -First 1
if (-not $pkg) { $pkg = Get-AppxPackage -AllUsers -Name Claude | Select-Object -First 1 }
if (-not $pkg) { Say 'Claude package not found.'; return }

$appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application |
    Select-Object -First 1 -ExpandProperty Id
$aumid = '{0}!{1}' -f $pkg.PackageFamilyName, $appId
Say "Package: $($pkg.PackageFullName)"
Say "AUMID  : $aumid"

# --- helpers ---------------------------------------------------------------
function Get-ClaudeProc {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -ne 'cowork-svc.exe' -and (
            $_.ExecutablePath -like "$($pkg.InstallLocation)\*" -or $_.Name -eq 'Claude.exe')
    }
}

function Get-HiveState {
    $h = Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\SystemAppData\Helium\User.dat"
    if (-not (Test-Path $h)) { return 'n/a (hive not found for this account)' }
    try {
        $fs = [IO.File]::Open($h, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return 'free'
    } catch { return 'LOCKED' }
}

function Test-Launch {
    $t = Get-Date
    Start-Process explorer.exe "shell:AppsFolder\$aumid"
    Start-Sleep -Seconds 12
    $procs = @(Get-ClaudeProc)
    $errs = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-AppModel-Runtime/Admin'; StartTime = $t
        } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match '0x80070020' -and $_.Message -match 'Claude' })
    Say ("  launch test: {0} Claude process(es), {1} new 0x80070020 event(s)" -f $procs.Count, $errs.Count)
    return ($procs.Count -gt 0)
}

# --- steps (each returns $true if it changed something) --------------------
$steps = @(
    @{ Name = 'Kill Gradle daemons'; Action = {
            $gd = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
                Where-Object { $_.CommandLine -match 'GradleDaemon' })
            if ($gd.Count -eq 0) { return $false }
            foreach ($p in $gd) {
                Say "  killing Gradle daemon PID $($p.ProcessId)"
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 3
            return $true
        }
    },
    @{ Name = 'Kill adb server'; Action = {
            $adb = @(Get-CimInstance Win32_Process -Filter "Name='adb.exe'")
            if ($adb.Count -eq 0) { return $false }
            foreach ($p in $adb) { Say "  adb PID $($p.ProcessId) $($p.ExecutablePath)" }
            $exe = ($adb | Where-Object ExecutablePath | Select-Object -First 1).ExecutablePath
            if ($exe) { & $exe kill-server 2>&1 | Out-Null }
            Start-Sleep -Seconds 2
            Get-Process adb -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            return $true
        }
    },
    @{ Name = 'Restart Appinfo service'; Action = {
            try {
                Restart-Service Appinfo -Force -ErrorAction Stop
                Start-Sleep -Seconds 4
                Say "  Appinfo: $((Get-Service Appinfo).Status)"
                return $true
            } catch {
                Say "  Appinfo restart failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
)

# --- run -------------------------------------------------------------------
$result = $null

if (@(Get-ClaudeProc).Count -gt 0) {
    $result = 'Claude already running - nothing tested.'
} else {
    Say "Baseline. hive: $(Get-HiveState)"
    if (Test-Launch) {
        $result = 'Not blocked - launched without any changes.'
    } else {
        foreach ($s in $steps) {
            Say "--- $($s.Name)"
            $did = & $s.Action
            if (-not $did) { Say '  nothing to do, skipped'; continue }
            Say "  hive: $(Get-HiveState)"
            if (Test-Launch) { $result = "FIXED BY: $($s.Name)"; break }
        }
    }
}

if (-not $result) {
    $result = 'STILL BLOCKED after all steps - sign out needed.'
    Say '--- remaining state'
    $h = Get-Command handle64.exe, handle.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($h) {
        & $h.Source -accepteula -a -nobanner pzs8sxrjxfjjc 2>&1 | ForEach-Object { Say "  $_" }
    } else { Say '  handle.exe not in PATH' }
    tasklist /apps 2>&1 | Select-String -Pattern 'claude' | ForEach-Object { Say "  $_" }
}

Say "RESULT: $result"
Say "Log: $log"
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Enter to close' | Out-Null }
