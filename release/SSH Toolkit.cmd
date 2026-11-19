@echo off
rem SSH Toolkit - double-click to start it.
rem Each time, this makes (or refreshes) the SSH Toolkit shortcut in this folder and in the Start menu,
rem then starts SSH Toolkit from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start SSH Toolkit without a console window.
rem The execution-policy bypass applies to SSH Toolkit's own run only; no Windows settings are changed.
rem If SSH Toolkit doesn't open, run   "SSH Toolkit.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SSH-Toolkit.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-SSHToolkitShortcut.ps1" -Launch
if errorlevel 1 pause
