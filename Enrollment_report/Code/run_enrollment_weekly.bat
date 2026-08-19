@echo off
setlocal

set "PYTHON_EXE=C:\Users\TKray\AppData\Local\Programs\Python\Python313\python.exe"
set "SCRIPT=C:\Users\TKray\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Enrollment_Weekly_Automation.py"

echo ==========================================================
echo ACO Weekly transfer started: %DATE% %TIME%
echo ==========================================================

"%PYTHON_EXE%" "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"

echo ==========================================================
if "%RC%"=="0" (
    echo ACO Weekly transfer completed successfully.
) else (
    echo ERROR: ACO Weekly transfer failed with exit code %RC%.
)
echo Finished: %DATE% %TIME%
echo ==========================================================

exit /b %RC%
