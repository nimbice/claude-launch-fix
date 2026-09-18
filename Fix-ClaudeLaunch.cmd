@echo off
rem Double-click when Claude will not start with a "file is in use" error. Details in Fix-ClaudeLaunch.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-ClaudeLaunch.ps1" %*
pause
