@echo off
rem Windows-Yet-Bench-Script - cmd.exe launcher for wybs.ps1
rem Usage: wybs.cmd [-flags]   e.g.  wybs.cmd -SkipGeekbench -ReduceNet
rem
rem The window is held open by wybs.ps1 itself (pass -NoPause to disable that),
rem so no pause here - it would just cost a second keypress.

setlocal
set "PSEXE=powershell"
where pwsh >nul 2>&1 && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0wybs.ps1" %*
set "RC=%ERRORLEVEL%"

rem 9009 = PowerShell itself could not be started; nothing printed the reason yet
if "%RC%"=="9009" (
    echo.
    echo Could not start %PSEXE%. Is PowerShell available in PATH?
    pause
)

endlocal & exit /b %RC%
