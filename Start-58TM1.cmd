@echo off
setlocal
set "Repair58PowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "Repair58PowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%Repair58PowerShell%" -NoProfile -STA -File "%~dp0Start-58TM1.ps1"
if errorlevel 1 pause
