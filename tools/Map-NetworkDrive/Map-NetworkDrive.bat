@echo off
title Map Network Drive
cd /d "%~dp0"
start "Map Network Drive" powershell.exe -NoLogo -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Map-NetworkDrive.ps1"
