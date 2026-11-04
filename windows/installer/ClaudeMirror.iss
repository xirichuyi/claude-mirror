#ifndef Payload
  #define Payload "..\dist\claude-mirror"
#endif
#ifndef AppVersion
  #error Pass AppVersion via windows/build-installer.ps1
#endif
[Setup]
AppId={{7A069CA4-F0B5-4503-935E-48C6EF2CC5B7}
AppName=Claude Mirror
AppVersion={#AppVersion}
AppPublisher=Claude Mirror
AppPublisherURL=https://github.com/xirichuyi/claude-mirror
DefaultDirName={localappdata}\Programs\Claude Mirror
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableDirPage=yes
DisableProgramGroupPage=yes
WizardStyle=modern
SetupIconFile=..\ClaudeMirror.App\Assets\AppIcon.ico
UninstallDisplayIcon={app}\claude-mirror.exe
OutputDir=..\dist
OutputBaseFilename=Claude-Mirror-Setup-x64
Compression=lzma2/fast
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}

[Languages]
Name: "zh"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.pdb"

[Icons]
Name: "{userprograms}\Claude Mirror"; Filename: "{app}\claude-mirror.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\claude-mirror.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,Claude Mirror}"; Flags: postinstall nowait skipifsilent
Filename: "{app}\claude-mirror.exe"; WorkingDir: "{app}"; Flags: nowait; Check: IsUpdateRestart

[Code]
function IsUpdateRestart: Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/UPDATEANDRESTART') = 0 then
    begin
      Result := WizardSilent;
      Exit;
    end;
end;
