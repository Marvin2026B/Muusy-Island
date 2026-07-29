@echo off
cd /d "%~dp0"
start "Muusy Island" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dynamic_island.ps1"
