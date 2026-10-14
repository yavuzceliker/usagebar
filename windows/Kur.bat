@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Kur.ps1"
if errorlevel 1 (
  echo Kurulum olmadi.
  pause
) else (
  echo.
  echo Kuruldu. Windows acilinca cubuk kendiliginden gelir.
  timeout /t 5
)
