# claude-launch-fix

Recovers the Claude desktop app on Windows when it will not start after an auto-update and
Windows reports **"The process cannot access the file because it is being used by another
process"** (error 0x80070020). Settings > Apps > Repair does not help; a reboot does, but is
not needed.

## Cause

Claude's in-app updater quits the running version and relaunches the new one. If one process
of the old version never exits, the old version's app sandbox stays alive and keeps Claude's
per-user package registry hive open
(`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium\*.dat`), so Windows cannot
create the sandbox for the new version. Every launch then fails before any Claude code runs,
which is why Claude's own `main.log` shows nothing.

Evidence in Event Viewer: *Applications and Services Logs > Microsoft > Windows >
AppModel-Runtime > Admin*, events 215 and 208 with `0x80070020` ("error converting the job").

Diagnosed 2026-09-13 on the Store (MSIX) build, versions 1.52386.0 -> 1.52386.3.

## Use

1. Get the files onto the PC (see below).
2. Double-click `Fix-ClaudeLaunch.cmd`. It lists the processes running as part of Claude,
   flags any from an older version, asks before stopping them, relaunches Claude and reports
   whether the error came back.
3. Still blocked? Sign out of Windows and back in. No full reboot needed.

`Fix-ClaudeLaunch.log` (written next to the script, not committed) records what was stopped.
That is the evidence of *which* process hangs; worth attaching to a bug report to Anthropic.

Report only, changes nothing:

```
powershell -NoProfile -ExecutionPolicy Bypass -File Fix-ClaudeLaunch.ps1 -DryRun
```

If Claude was installed from the .exe rather than the Store, the script instead offers to stop
every leftover Claude desktop process and relaunches from `%LOCALAPPDATA%\AnthropicClaude`.

## Getting it onto another PC

```
git clone https://github.com/nimbice/claude-launch-fix.git C:\Scripts\claude-launch-fix
```

or open the repo on github.com and use *Code > Download ZIP*.

## No download at all: the fix by hand

In PowerShell, as the normal user:

```powershell
Get-AppxPackage Claude | Select-Object PackageFullName   # the version that should be running
tasklist /apps | findstr Claude_                          # what is actually running
taskkill /F /PID <pid>                                    # every row whose version is OLDER
explorer.exe shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude # relaunch
```
