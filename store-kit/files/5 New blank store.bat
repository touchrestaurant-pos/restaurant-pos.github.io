@echo off
setlocal
call "%~dp0_common.bat" || exit /b 1
echo This wipes the store database on this computer and makes a brand-new BLANK store
echo (no staff, menu, stock or sales). Back up first if there is anything to keep.
set /p SURE=Type BLANK to go ahead: 
if /i not "%SURE%"=="BLANK" ( echo Cancelled. Nothing was changed. & pause & exit /b 0 )
"%SB%" db reset
if errorlevel 1 ( echo Could not rebuild the database. & pause & exit /b 1 )
echo.
echo Done. Now run "6 Create first admin" to make the owner's login.
pause
