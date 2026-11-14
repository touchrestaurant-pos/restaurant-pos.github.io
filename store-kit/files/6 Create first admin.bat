@echo off
setlocal
call "%~dp0_common.bat" || exit /b 1
for /f "tokens=1,* delims==" %%a in ('"%SB%" status -o env 2^>nul') do set "%%a=%%~b"
if "%SERVICE_ROLE_KEY%"=="" ( echo The store database is not running. Run "1 Start store database" first. & pause & exit /b 1 )
echo The first login made in a blank store becomes the admin (owner).
set /p UNAME=Username (lowercase letters and numbers, for example owner): 
set /p FULL=Full name: 
set /p PASS=Password (at least 8 characters, avoid the characters " and %%): 
curl -s -o "%TEMP%\restopos_admin.json" -w "%%{http_code}" -X POST "http://127.0.0.1:54321/auth/v1/admin/users" -H "apikey: %SERVICE_ROLE_KEY%" -H "Authorization: Bearer %SERVICE_ROLE_KEY%" -H "Content-Type: application/json" -d "{\"email\":\"%UNAME%@touchrestaurant-pos.github.io\",\"password\":\"%PASS%\",\"email_confirm\":true,\"user_metadata\":{\"username\":\"%UNAME%\",\"full_name\":\"%FULL%\"}}" > "%TEMP%\restopos_code.txt"
set /p CODE=<"%TEMP%\restopos_code.txt"
if "%CODE%"=="200" (
  echo.
  echo Login created. In the app choose this store's database, then sign in with username %UNAME%.
) else (
  echo.
  echo Could not create the login ^(code %CODE%^):
  type "%TEMP%\restopos_admin.json"
)
del "%TEMP%\restopos_admin.json" "%TEMP%\restopos_code.txt" >nul 2>&1
echo.
pause
