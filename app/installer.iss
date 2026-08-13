[Setup]
AppName=Onyx
AppVersion=1.0.0
DefaultDirName={commonpf}\Onyx
DefaultGroupName=Onyx
OutputBaseFilename=Onyx-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\app.exe

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Onyx"; Filename: "{app}\app.exe"
Name: "{commondesktop}\Onyx"; Filename: "{app}\app.exe"

[Run]
Filename: "{app}\app.exe"; Description: "Launch Onyx"; Flags: nowait postinstall skipifsilent
