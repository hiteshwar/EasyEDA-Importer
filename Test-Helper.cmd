@echo off
REM Double-click to check that the EasyEDA helper works on this PC.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ee_fetch.ps1" -SelfTest
echo.
set "P="
set /p P=LCSC number to test a real download (e.g. C2040), or Enter to skip: 
if not "%P%"=="" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ee_fetch.ps1" -Lcsc "%P%"
echo.
pause
