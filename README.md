# claude-launch-fix

Recovers the Claude desktop app on Windows when it will not start after an auto-update and
Windows reports **"The process cannot access the file because it is being used by another
process"** (error 0x80070020). Settings > Apps > Repair does not help; signing out or rebooting
does, but is not needed.

## Cause (confirmed 2026-09-18)

A program started from a **Claude Code session** that detaches and keeps running after the app
quits. In the confirmed case it was the **Android `adb` server** (`adb.exe`), started by an
`adb` command Claude ran in the Code tab.

Commands run by Claude Code start inside the desktop app's sandbox (its Desktop AppX
container). `adb` forks a background server that cuts its ties to the shell. When the
auto-update quits the app, every Claude process exits but the adb server does not, so the old
version's sandbox stays alive and keeps Claude's per-user package registry hive mounted
(`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\SystemAppData\Helium\*.dat`). Windows then cannot
create the sandbox for the new version, and every launch fails before any Claude code runs,
which is why Claude's own `main.log` shows nothing.

Why it was hard to find:

- `tasklist /apps` does not list the adb server: it has no package identity.
- Its parent process is gone, so it does not look related to Claude.
- Sysinternals `handle.exe` finds no handle into the hive or the sandbox. Being a member of the
  sandbox is enough to keep it alive.

The proof, from `Unblock-Claude.ps1` on 2026-09-18 (Claude 2.2553.1.0, Windows 11 26200):

```
03:48:56 Baseline hive: LOCKED
03:49:09   launch: 0 Claude proc, 6 new 0x80070020
03:49:09 --- 1 Gradle daemons
03:49:09   kill PID 18544
03:49:12   hive: LOCKED
03:49:25   launch: 0 Claude proc, 6 new 0x80070020
03:49:25 --- 2 adb
03:49:29   hive: free
03:49:42   launch: 11 Claude proc, 0 new 0x80070020
03:49:42 RESULT: FIXED BY adb kill
```

Killing the Gradle daemon (also started from the Code tab) did not release the hive on its own;
stopping adb did, within seconds. Any other detached long-lived program started from a Claude
Code session (dev servers, emulators, file watchers) is a suspect for the same reason.

Evidence in Event Viewer: *Applications and Services Logs > Microsoft > Windows >
AppModel-Runtime > Admin*, events 215 and 208 with `0x80070020` ("error converting the job").

Reported as [anthropics/claude-code#95266](https://github.com/anthropics/claude-code/issues/95266).

## The quick fix

```
adb kill-server
```

then start Claude. If `adb` is not on the PATH, end `adb.exe` in Task Manager.

To avoid it: run `adb kill-server` when you are done with a device or emulator in a Claude Code
session, before the app next updates.

## Use the script

1. Get the files onto the PC (see below).
2. Double-click `Fix-ClaudeLaunch.cmd`. It
   - lists the processes running as part of Claude and flags any from an older version,
   - finds leftovers of Claude Code sessions that carry no package identity,
   - if nothing of Claude is left but its hive is still locked, offers to stop the adb server
     and Gradle daemons **one at a time**, checking the hive after each, so the log names the
     process that was responsible,
   - asks before stopping anything, relaunches Claude and reports whether the error came back.
3. Still blocked? Stop anything else you started from a Claude Code session, or sign out of
   Windows and back in. No full reboot needed.

Run it as administrator if the normal run finds nothing.

`Fix-ClaudeLaunch.log` (written next to the script, not committed) records what was stopped and
which step released the hive; worth attaching to a bug report.

Report only, changes nothing:

```
powershell -NoProfile -ExecutionPolicy Bypass -File Fix-ClaudeLaunch.ps1 -DryRun
```

If Claude was installed from the .exe rather than the Store, the script instead offers to stop
every leftover Claude desktop process and relaunches from `%LOCALAPPDATA%\AnthropicClaude`.

`Unblock-Claude.ps1` is the experiment that found the cause, kept as it was run: elevated, no
prompts, it kills Gradle daemons, then the adb server, then restarts the Appinfo service,
relaunching Claude after each and stopping at the first step that works. Prefer
`Fix-ClaudeLaunch`, which asks first.

## Getting it onto another PC

```
git clone https://github.com/nimbice/claude-launch-fix.git C:\Scripts\claude-launch-fix
```

or open the repo on github.com and use *Code > Download ZIP*.

## No download at all: the fix by hand

In PowerShell, as the normal user:

```powershell
Get-Process adb -ErrorAction SilentlyContinue | Stop-Process -Force   # the confirmed culprit
explorer.exe shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude             # relaunch
```

If that was not it, look for an old-version process:

```powershell
Get-AppxPackage Claude | Select-Object PackageFullName   # the version that should be running
tasklist /apps | findstr Claude_                          # what is actually running
taskkill /F /PID <pid>                                    # every row whose version is OLDER
```
