@echo off

set "PYTHON_EXE=C:\Users\TKray\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Advocacy_Monthly_Transfer.py"
set "LOG=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Advocacy_Monthly_Transfer_Launcher.log"

echo. >> "%LOG%"
echo ============================================================ >> "%LOG%"
echo Advocacy Monthly transfer started: %DATE% %TIME% >> "%LOG%"

"%PYTHON_EXE%" "%SCRIPT%" >> "%LOG%" 2>&1

set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% EQU 0 (
    echo Advocacy Monthly transfer completed successfully: %DATE% %TIME% >> "%LOG%"
) else (
    echo ERROR: Advocacy Monthly transfer failed with code %EXIT_CODE%: %DATE% %TIME% >> "%LOG%"
)

echo ============================================================ >> "%LOG%"

exit /b %EXIT_CODE%