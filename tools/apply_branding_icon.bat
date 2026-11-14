@echo off
REM Copies the branded app icon over the default Flutter icon so the
REM built .exe and taskbar match the web app's icon.
cd /d "%~dp0.."
if not exist windows\runner\resources\app_icon.ico (
  echo Could not find windows\runner\resources\app_icon.ico
  echo Run "flutter create --platforms=windows ." first, then re-run this script.
  pause
  exit /b 1
)
copy /y branding\windows\app_icon.ico windows\runner\resources\app_icon.ico
echo Icon replaced. Now rebuild:
echo   flutter clean
echo   flutter run -d windows --release
pause
