@echo off
REM Copyright 2026 GoldesqueMoON
REM SPDX-License-Identifier: Apache-2.0
setlocal

set "SERVICE=messagetransfer"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Please run this file as Administrator.
    pause
    exit /b 1
)

echo Checking service: %SERVICE%
sc query "%SERVICE%" | findstr /i "RUNNING" >nul

if %errorlevel% equ 0 (
    echo Service is running. Stopping now...
    echo Now you can play Wardogs!!!
    net stop "%SERVICE%"
) else (
    echo Service is not running. Starting now...
    echo Now you can play CS PerfectWorld!!!
    net start "%SERVICE%"
)

echo.
echo Done.
pause
