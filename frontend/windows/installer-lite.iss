; Inno Setup Script for CCS Sleep Studio Lite
#ifndef AppVer
  #define AppVer "1.19.0"
#endif

[Setup]
AppId={{D1A39B10-E24F-465B-B91C-7B9F01194F66}
AppName=CCS Sleep Studio Lite
AppVersion={#AppVer}
; Install per-user under %LOCALAPPDATA%\Programs (like other per-user apps).
; Older builds installed into the *roaming* profile (%APPDATA%), which is
; synchronised on domain/roaming profiles and rescanned by antivirus on
; every launch, making start-up and model loading slow on many PCs.
DefaultDirName={localappdata}\Programs\CCSSleepStudio-lite
UsePreviousAppDir=no
DefaultGroupName=CCS Sleep Studio Lite
OutputDir=..\dist
OutputBaseFilename=CCSSleepStudio-lite-Installer
SetupIconFile=runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Remove the previous roaming-profile installation and the retired Python
; autoscore backend (thousands of files) left behind by older versions.
Type: filesandordirs; Name: "{userappdata}\CCSSleepStudio-lite"
Type: filesandordirs; Name: "{app}\autoscore-backend"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CCS Sleep Studio Lite"; Filename: "{app}\CCSSleepStudio.exe"
Name: "{autodesktop}\CCS Sleep Studio Lite"; Filename: "{app}\CCSSleepStudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CCSSleepStudio.exe"; Description: "{cm:LaunchProgram,CCS Sleep Studio Lite}"; Flags: nowait postinstall skipifsilent
