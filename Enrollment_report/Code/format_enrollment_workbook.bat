@echo off
setlocal

if "%~1"=="" (
    echo Usage:
    echo   format_enrollment_workbook.bat "full-path-to-REGXSA.xls"
    exit /b 2
)

set "SCRIPT=%USERPROFILE%\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Format_Enrollment_Workbook.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -WorkbookPath "%~1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo ERROR: Workbook formatting failed with exit code %RC%.
    exit /b %RC%
)

echo Workbook formatting completed successfully.
exit /b 0
