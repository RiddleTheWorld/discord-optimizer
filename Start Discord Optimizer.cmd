@echo off
rem Opens the Discord Optimizer window. Works from any folder, as long as the .ps1/.cs files sit next to it.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DiscordOptimizerUI.ps1"
