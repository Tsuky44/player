; La version est injectee par le workflow Release (ISCC /DAppVersion=1.0.1) pour
; que "Programmes et fonctionnalites" affiche la meme version que le nom du
; fichier. La valeur par defaut garde un build local manuel fonctionnel.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; Le theme sombre et le fond PNG n'existent qu'a partir de la 6.7 : un ISCC
; plus ancien compilerait quand meme, avec l'assistant gris d'origine.
#if VER < EncodeVer(6, 7, 0)
  #error Inno Setup 6.7 ou plus recent est requis (winget upgrade -e --id JRSoftware.InnoSetup)
#endif

[Setup]
; AppName sert aussi d'AppId implicite : le changer ferait installer Onyx en
; double au lieu de mettre a jour les installations existantes.
AppName=Onyx
AppVersion={#AppVersion}
UninstallDisplayName=Onyx
DefaultDirName={commonpf}\Onyx
DefaultGroupName=Onyx
OutputBaseFilename=Onyx-Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
UninstallDisplayIcon={app}\app.exe
SetupIconFile=windows\runner\resources\app_icon.ico
VersionInfoDescription=Installation d'Onyx
VersionInfoProductName=Onyx

; Habillage : voir brand/installer-background.svg et
; brand/generate-installer-art.ps1 pour regenerer les fonds.
WizardStyle=modern dark includetitlebar hidebevels
WizardBackColor=#121414
WizardBackImageFile=windows\installer\background-100.png,windows\installer\background-125.png,windows\installer\background-150.png,windows\installer\background-175.png,windows\installer\background-200.png,windows\installer\background-250.png
WizardImageFile=
WizardSmallImageFile=
; Le fond est dessine pour une taille fixe : redimensionner decalerait les
; textes par rapport au lockup.
WizardResizable=no

DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Messages]
SetupWindowTitle=Onyx

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Onyx"; Filename: "{app}\app.exe"
Name: "{commondesktop}\Onyx"; Filename: "{app}\app.exe"

[Run]
Filename: "{app}\app.exe"; Description: "Lancer Onyx"; Flags: nowait postinstall skipifsilent

[Code]
const
  { Couleurs en BGR ($00BBGGRR), pas en RGB. }
  TextColor = $E4E6E8;
  MutedColor = $94979A;
  TrackColor = $2C2C2A;
  { Premiere ligne libre sous le lockup du fond, en pixels a 100 %. }
  ContentTop = 232;
  BarWidth = 320;

var
  IsUpgrade: Boolean;
  DirText: TNewStaticText;
  DirLink: TNewLinkLabel;
  PercentText: TNewStaticText;
  BarFill: TBitmapImage;

function MeasureText(const S: String; Font: TFont): Integer;
var
  Probe: TNewStaticText;
begin
  Probe := TNewStaticText.Create(WizardForm);
  try
    Probe.Parent := WizardForm;
    Probe.Font := Font;
    Probe.AutoSize := True;
    Probe.Caption := S;
    Result := Probe.Width;
  finally
    Probe.Free;
  end;
end;

{ Un aplat de couleur. TBitmapImage sans image ne dessine que BackColor, que
  le theme sombre laisse intact, contrairement a un TPanel. }
function CreateBlock(Parent: TWinControl; Color: TColor): TBitmapImage;
begin
  Result := TBitmapImage.Create(WizardForm);
  Result.Parent := Parent;
  Result.BackColor := Color;
end;

function CreateCenteredText(Parent: TWinControl; Top, Width, FontSize: Integer;
  Color: TColor; const Caption: String): TNewStaticText;
begin
  Result := TNewStaticText.Create(WizardForm);
  Result.Parent := Parent;
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Alignment := taCenter;
  Result.Font.Size := FontSize;
  Result.Font.Color := Color;
  Result.Caption := Caption;
  Result.SetBounds(0, Top, Width, ScaleY(FontSize * 2 + 8));
end;

{ Chemin et lien sont deux controles : un TNewLinkLabel ne sait pas centrer
  son texte, donc on centre le couple a partir de leurs largeurs mesurees. }
procedure UpdateDirLink;
var
  LinkWidth, Gap, Total: Integer;
begin
  DirText.Caption := MinimizePathName(WizardDirValue, DirText.Font, ScaleX(360));
  LinkWidth := MeasureText('Modifier', DirLink.Font) + ScaleX(2);
  Gap := ScaleX(12);
  Total := DirText.Width + Gap + LinkWidth;
  DirText.Left := (WizardForm.WelcomePage.Width - Total) div 2;
  DirLink.SetBounds(DirText.Left + DirText.Width + Gap, DirText.Top, LinkWidth, DirText.Height);
end;

procedure DirLinkClick(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  Dir: String;
begin
  Dir := WizardDirValue;
  if BrowseForFolder('Choisissez le dossier dans lequel installer Onyx.', Dir, True) then
  begin
    { Comme le bouton Parcourir d'origine : choisir "D:\Apps" installe dans
      "D:\Apps\Onyx", pas en vrac dans le dossier choisi. }
    if CompareText(ExtractFileName(RemoveBackslashUnlessRoot(Dir)), 'Onyx') <> 0 then
      Dir := AddBackslash(Dir) + 'Onyx';
    WizardForm.DirEdit.Text := Dir;
    UpdateDirLink;
  end;
end;

procedure InitializeWizard;
var
  PageWidth, InnerWidth: Integer;
begin
  IsUpgrade := WizardForm.PrevAppDir <> '';

  { Le titre, l'image laterale et l'en-tete des pages internes sont ce qui
    fait reconnaitre un assistant Inno : on les retire, le lockup du fond
    tient lieu de titre. }
  WizardForm.MainPanel.Visible := False;
  WizardForm.WelcomeLabel1.Visible := False;
  WizardForm.WelcomeLabel2.Visible := False;
  WizardForm.FinishedHeadingLabel.Visible := False;
  WizardForm.FinishedLabel.Visible := False;

  { Les pages internes (progression, fermeture d'applications) vivent sous le
    lockup, jamais par-dessus. }
  WizardForm.InnerNotebook.SetBounds(ScaleX(40), ScaleY(ContentTop),
    WizardForm.ClientWidth - ScaleX(80), WizardForm.Bevel.Top - ScaleY(ContentTop));

  PageWidth := WizardForm.WelcomePage.Width;
  InnerWidth := WizardForm.InnerNotebook.Width;

  if IsUpgrade then
    CreateCenteredText(WizardForm.WelcomePage, ScaleY(ContentTop + 8), PageWidth, 10,
      TextColor, 'Une nouvelle version d''Onyx est prête à être installée.')
  else
  begin
    CreateCenteredText(WizardForm.WelcomePage, ScaleY(ContentTop + 8), PageWidth, 10,
      TextColor, 'Onyx va être installé sur cet ordinateur.');

    { Pas de page "Dossier de destination" : l'emplacement reste modifiable
      depuis l'accueil, pour ceux qui le veulent. Masque en mise a jour, ou
      deplacer l'installation laisserait l'ancienne en place. }
    DirText := TNewStaticText.Create(WizardForm);
    DirText.Parent := WizardForm.WelcomePage;
    DirText.AutoSize := True;
    DirText.Font.Color := MutedColor;
    DirText.Top := ScaleY(ContentTop + 44);

    DirLink := TNewLinkLabel.Create(WizardForm);
    DirLink.Parent := WizardForm.WelcomePage;
    DirLink.AutoSize := False;
    DirLink.Caption := '<a id="browse">Modifier</a>';
    DirLink.OnLinkClick := @DirLinkClick;
    UpdateDirLink;
  end;

  CreateCenteredText(WizardForm.InstallingPage, ScaleY(8), InnerWidth, 10,
    TextColor, 'Installation d''Onyx…');
  WizardForm.StatusLabel.Visible := False;
  WizardForm.FilenameLabel.Visible := False;

  { La barre native prend la couleur d'accent de Windows (vert, bleu...) :
    une piste et un remplissage monochromes restent dans la marque. }
  WizardForm.ProgressGauge.Visible := False;
  with CreateBlock(WizardForm.InstallingPage, TrackColor) do
    SetBounds((InnerWidth - ScaleX(BarWidth)) div 2, ScaleY(46), ScaleX(BarWidth), ScaleY(4));
  BarFill := CreateBlock(WizardForm.InstallingPage, TextColor);
  BarFill.SetBounds((InnerWidth - ScaleX(BarWidth)) div 2, ScaleY(46), 0, ScaleY(4));

  PercentText := CreateCenteredText(WizardForm.InstallingPage, ScaleY(60), InnerWidth, 9,
    MutedColor, '');

  if IsUpgrade then
    CreateCenteredText(WizardForm.FinishedPage, ScaleY(ContentTop + 8), PageWidth, 10,
      TextColor, 'Onyx est à jour.')
  else
    CreateCenteredText(WizardForm.FinishedPage, ScaleY(ContentTop + 8), PageWidth, 10,
      TextColor, 'Onyx est installé.');
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  Ratio: Extended;
begin
  if MaxProgress <= 0 then
    Exit;
  Ratio := CurProgress / MaxProgress;
  BarFill.Width := Round(ScaleX(BarWidth) * Ratio);
  PercentText.Caption := Format('%d %%', [Round(Ratio * 100)]);
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Width: Integer;
begin
  { Parcours lineaire accueil -> installation -> fin : un bouton Precedent
    n'aurait rien vers quoi revenir. }
  WizardForm.BackButton.Visible := False;

  if CurPageID = wpWelcome then
  begin
    if IsUpgrade then
      WizardForm.NextButton.Caption := 'Mettre à jour'
    else
      WizardForm.NextButton.Caption := 'Installer';
  end
  else if (CurPageID = wpFinished) and (WizardForm.RunList.Items.Count > 0) then
  begin
    { Largeur ajustee au contenu (case + libelle) pour que le centrage porte
      sur ce qu'on voit, pas sur une boite plus large que son texte. }
    Width := MeasureText(WizardForm.RunList.ItemCaption[0], WizardForm.RunList.Font) + ScaleX(30);
    WizardForm.RunList.SetBounds((WizardForm.FinishedPage.Width - Width) div 2,
      ScaleY(ContentTop + 44), Width, ScaleY(24));
  end;
end;
