; Windows installer for RestoPOS, built by GitHub Actions with Inno Setup.
#define AppVersion GetEnv("APP_VERSION")

[Setup]
AppId={{6C1C8F43-6E2D-4C3B-9F7A-5D2E7B1A9C10}
AppName=RestoPOS
AppVersion={#AppVersion}
AppPublisher=RestoPOS
DefaultDirName={autopf}\RestoPOS
DefaultGroupName=RestoPOS
OutputDir=..\..\build\installer
OutputBaseFilename=RestoPOS-Setup-{#AppVersion}
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\restaurant_pos.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\RestoPOS"; Filename: "{app}\restaurant_pos.exe"
Name: "{autodesktop}\RestoPOS"; Filename: "{app}\restaurant_pos.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"

[Run]
Filename: "{app}\restaurant_pos.exe"; Description: "Start RestoPOS"; Flags: nowait postinstall skipifsilent
