@echo off
setlocal
call "%~dp0_common.bat" || exit /b 1
if not exist "%~dp0backups" mkdir "%~dp0backups"
set /p NAME=Name for this backup (for example MainStore), no spaces: 
if "%NAME%"=="" set NAME=backup
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmm"') do set STAMP=%%i
set "FILE=%NAME%_%STAMP%.dump"
echo Backing up...
docker exec %DBC% pg_dump -U supabase_admin -d postgres -Fc --data-only --schema=public -t auth.users -t auth.identities -f /tmp/restopos.dump
if errorlevel 1 ( echo Backup failed. Is the store database started? & pause & exit /b 1 )
docker cp %DBC%:/tmp/restopos.dump "%~dp0backups\%FILE%"
if errorlevel 1 ( echo Could not save the backup file. & pause & exit /b 1 )
echo.
echo Saved: backups\%FILE%
echo Copy this file to a USB stick or cloud drive as well. Uploaded logo pictures are not in the backup.
pause
