@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Send_Rebuilt_Enrollment_Friday.ps1" %* >> "%~dp0Friday_Notification.log" 2>&1
exit /b %ERRORLEVEL%
