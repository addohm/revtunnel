@echo off
rem revtunnel for Windows: double-click to set up this computer's tunnel, or to see its status and change it.
rem Keep this file in the same folder as revtunnel-target-windows.ps1.
if not exist "%~dp0revtunnel-target-windows.ps1" (
    echo revtunnel-target-windows.ps1 must be in the same folder as this file: %~dp0
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0revtunnel-target-windows.ps1" %*
pause
