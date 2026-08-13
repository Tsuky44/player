; La version est injectee par le workflow Release (ISCC /DAppVersion=1.0.1) pour
; que "Programmes et fonctionnalites" affiche la meme version que le nom du
; fichier. La valeur par defaut garde un build local manuel fonctionnel.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppName=Onyx
AppVersion={#AppVersion}
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
