; Inno Setup Script for CCS Sleep Studio Lite
[Setup]
AppId={{D1A39B10-E24F-465B-B91C-7B9F01194F66}
AppName=CCS Sleep Studio Lite
AppVersion=1.13.0
DefaultDirName={userappdata}\CCSSleepStudio-lite
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

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CCS Sleep Studio Lite"; Filename: "{app}\CCSSleepStudio.exe"
Name: "{autodesktop}\CCS Sleep Studio Lite"; Filename: "{app}\CCSSleepStudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CCSSleepStudio.exe"; Description: "{cm:LaunchProgram,CCS Sleep Studio Lite}"; Flags: nowait postinstall skipifsilent
