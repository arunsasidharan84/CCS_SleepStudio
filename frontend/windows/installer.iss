; Inno Setup Script for CCS Sleep Studio
#ifndef AppVer
  #define AppVer "1.19.0"
#endif

[Setup]
AppId={{C6D29A10-D24E-464A-A91B-6B8F01184F65}
AppName=CCS Sleep Studio
AppVersion={#AppVer}
; Install per-user under %LOCALAPPDATA%\Programs (like other per-user apps).
; Older builds installed into the *roaming* profile (%APPDATA%), which is
; synchronised on domain/roaming profiles and rescanned by antivirus on
; every launch, making start-up and model loading slow on many PCs.
DefaultDirName={localappdata}\Programs\CCSSleepStudio
UsePreviousAppDir=no
DefaultGroupName=CCS Sleep Studio
OutputDir=..\dist
OutputBaseFilename=CCSSleepStudio-Installer
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
Type: filesandordirs; Name: "{userappdata}\CCSSleepStudio"
Type: filesandordirs; Name: "{app}\autoscore-backend"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CCS Sleep Studio"; Filename: "{app}\CCSSleepStudio.exe"
Name: "{autodesktop}\CCS Sleep Studio"; Filename: "{app}\CCSSleepStudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CCSSleepStudio.exe"; Description: "{cm:LaunchProgram,CCS Sleep Studio}"; Flags: nowait postinstall skipifsilent
