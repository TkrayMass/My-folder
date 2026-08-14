@echo off
set "PYTHON_EXE=C:\Users\TKray\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Caseload\caseload_monthly_export.py"
set "LOG=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Caseload\Caseload_Monthly_Export.log"

echo. >> "%LOG%"
echo ============================================================ >> "%LOG%"
echo Caseload Monthly export started: %DATE% %TIME% >> "%LOG%"

"%PYTHON_EXE%" "%SCRIPT%" >> "%LOG%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% EQU 0 (
    echo Caseload Monthly export completed successfully: %DATE% %TIME% >> "%LOG%"
) else (
    echo ERROR: Caseload Monthly export failed with code %EXIT_CODE%: %DATE% %TIME% >> "%LOG%"
)

echo ============================================================ >> "%LOG%"
exit /b %EXIT_CODE%
