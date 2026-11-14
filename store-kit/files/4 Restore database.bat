@echo off
setlocal
call "%~dp0_common.bat" || exit /b 1
echo Backups in this folder:
echo.
dir /b "%~dp0backups\*.dump" 2>nul
echo.
set /p FILE=Type the full file name to restore (for example MainStore_2026-11-14_0930.dump): 
if not exist "%~dp0backups\%FILE%" ( echo That file is not in the backups folder. & pause & exit /b 1 )
echo.
echo This REPLACES everything in the store database with the backup "%FILE%".
echo Make a backup of the current database first if you might want it back.
set /p SURE=Type RESTORE to go ahead: 
if /i not "%SURE%"=="RESTORE" ( echo Cancelled. Nothing was changed. & pause & exit /b 0 )
echo Rebuilding a blank database...
"%SB%" db reset
if errorlevel 1 ( echo Could not rebuild the database. & pause & exit /b 1 )
echo Loading the backup...
docker cp "%~dp0backups\%FILE%" %DBC%:/tmp/restore.dump
docker exec %DBC% psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "do $$ declare t text; begin for t in select format('%%I.%%I', schemaname, tablename) from pg_tables where schemaname = 'public' loop execute 'truncate table ' || t || ' cascade'; end loop; truncate table auth.users cascade; end $$;"
if errorlevel 1 ( echo Could not clear the blank database. & pause & exit /b 1 )
docker exec %DBC% pg_restore -U supabase_admin -d postgres --data-only --disable-triggers --no-owner /tmp/restore.dump
if errorlevel 1 ( echo The restore reported problems. Take a photo of this window and send it to support before using the database. & pause & exit /b 1 )
echo.
echo Restored "%FILE%". On each till: sign out, then on the sign-in screen tap Database, choose Online, then choose this store again (this clears the till's old copy).
pause
