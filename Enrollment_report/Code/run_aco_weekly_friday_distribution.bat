@echo off
setlocal

set "SCRIPT=%USERPROFILE%\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Send_ACO_Weekly_Friday_Distribution.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo ACO Weekly Friday distribution process completed successfully.
) else (
    echo ERROR: ACO Weekly Friday distribution process failed with exit code %RC%.
)

exit /b %RC%
