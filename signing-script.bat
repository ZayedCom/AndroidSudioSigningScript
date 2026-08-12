@echo off
cd /d "%~dp0"
title Signing Script
rem Created by Zaid K. Al Qassar (ZayedCom) - https://github.com/ZayedCom
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0signing-script.ps1" %*
echo.
pause
