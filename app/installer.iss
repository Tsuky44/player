[Setup]
AppName=Project Player
AppVersion=1.0.0
DefaultDirName={commonpf}\Project Player
DefaultGroupName=Project Player
OutputBaseFilename=ProjectPlayer-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\app.exe

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Project Player"; Filename: "{app}\app.exe"
Name: "{commondesktop}\Project Player"; Filename: "{app}\app.exe"

[Run]
Filename: "{app}\app.exe"; Description: "Launch Project Player"; Flags: nowait postinstall skipifsilent
