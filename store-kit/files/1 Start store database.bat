@echo off
call "%~dp0_common.bat" || exit /b 1
echo.
echo Starting the store database. The very first start downloads about 3 GB and can take 10-30 minutes.
echo.
"%SB%" start
if errorlevel 1 ( echo. & echo The database did not start. Take a photo of this window and send it to support. & pause & exit /b 1 )
"%SB%" status > "%~dp0connection.txt" 2>&1
echo.>> "%~dp0connection.txt"
echo For the app on THIS computer use the address  http://127.0.0.1:54321 >> "%~dp0connection.txt"
echo For other tills on the same network use  http://THIS-COMPUTERS-IP:54321  (IP addresses below) >> "%~dp0connection.txt"
ipconfig | findstr /c:"IPv4" >> "%~dp0connection.txt"
echo.
echo The store database is running. The address and key for the app are in connection.txt in this folder.
echo You can close this window. The database keeps running until you run "2 Stop store database" or shut down.
pause
