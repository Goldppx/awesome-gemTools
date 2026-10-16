@echo off
REM Copyright 2026 GoldesqueMoON
REM SPDX-License-Identifier: Apache-2.0
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0EazyLoopback.ps1" -GuiProcess
exit /b
