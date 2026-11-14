@echo off
rem Shared checks. Called by the other scripts.
cd /d "%~dp0"
set "SB=%~dp0bin\supabase.exe"
set "DBC=supabase_db_restopos"
docker info >nul 2>&1
if errorlevel 1 (
  echo.
  echo Docker Desktop is not running. Open Docker Desktop, wait for it to say "Engine running", then try again.
  echo.
  pause
  exit /b 1
)
if not exist "%SB%" (
  echo Downloading the database tool ^(one time, needs internet^)...
  if not exist "%~dp0bin" mkdir "%~dp0bin"
  curl -L --fail -o "%~dp0bin\supabase.tar.gz" https://github.com/supabase/cli/releases/latest/download/supabase_windows_amd64.tar.gz
  if errorlevel 1 ( echo Download failed. Check the internet and try again. & pause & exit /b 1 )
  tar -xzf "%~dp0bin\supabase.tar.gz" -C "%~dp0bin"
  if not exist "%SB%" ( echo Could not unpack the database tool. & pause & exit /b 1 )
)
exit /b 0
