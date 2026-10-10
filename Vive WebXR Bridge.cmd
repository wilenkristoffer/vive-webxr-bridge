@echo off
rem Opens the vive-webxr-bridge window without a console.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\gui.ps1"
