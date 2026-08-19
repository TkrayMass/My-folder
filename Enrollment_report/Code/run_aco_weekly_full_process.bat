@echo off
setlocal
set "SCRIPT=%USERPROFILE%\OneDrive - Commonwealth of Massachusetts\Ad Hoc\Run_ACO_Weekly_Full_Process.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo ACO Weekly full process completed successfully.
) else (
  echo ERROR: ACO Weekly full process failed with exit code %RC%.
)
exit /b %RC%
