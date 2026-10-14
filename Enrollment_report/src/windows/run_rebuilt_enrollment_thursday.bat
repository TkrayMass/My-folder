@echo off
setlocal
"%USERPROFILE%\AppData\Local\Programs\Python\Python313\python.exe" "%~dp0transfer_rebuilt_windows.py" --staging "%USERPROFILE%\ACO_Weekly_Rebuilt_Staging" --qc-folder "%USERPROFILE%\OneDrive - Commonwealth of Massachusetts\Desktop\Monthly Advocacy\Weekly enrollment\Enrollment_Automation_Test\QC" --publish-folder "%USERPROFILE%\OneDrive - Commonwealth of Massachusetts\Monthly_enrollment_report" --publish --replace-existing --latest-wednesday --not-before-local 13:00 >> "%~dp0Thursday_Transfer.log" 2>&1
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~dp0run_rebuilt_enrollment_friday.bat" -ValidateOnly
exit /b %ERRORLEVEL%
