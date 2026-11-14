@echo off
call "%~dp0_common.bat" || exit /b 1
"%SB%" stop
echo.
echo Stopped. Your data is kept and comes back the next time you start.
pause
