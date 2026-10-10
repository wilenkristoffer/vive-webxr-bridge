@echo off
title vive-webxr-bridge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0webxr-vive.ps1" %*
pause
