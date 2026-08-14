@echo off
set "PYTHON_EXE=C:\Users\TKray\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\export_snapshot_history.py"
set "LOG=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Snapshot_Monthly_Export.log"

echo. >> "%LOG%"
echo ============================================================ >> "%LOG%"
echo Snapshot Monthly export started: %DATE% %TIME% >> "%LOG%"

"%PYTHON_EXE%" "%SCRIPT%" >> "%LOG%" 2>&1

if %ERRORLEVEL% EQU 0 (
    echo Snapshot Monthly export completed successfully: %DATE% %TIME% >> "%LOG%"
) else (
    echo ERROR: Snapshot Monthly export failed with code %ERRORLEVEL%: %DATE% %TIME% >> "%LOG%"
)

echo ============================================================ >> "%LOG%"
