; Inno Setup Script for CCS Sleep Studio
[Setup]
AppId={{C6D29A10-D24E-464A-A91B-6B8F01184F65}
AppName=CCS Sleep Studio
AppVersion=1.14.0
DefaultDirName={userappdata}\CCSSleepStudio
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

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CCS Sleep Studio"; Filename: "{app}\CCSSleepStudio.exe"
Name: "{autodesktop}\CCS Sleep Studio"; Filename: "{app}\CCSSleepStudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CCSSleepStudio.exe"; Description: "{cm:LaunchProgram,CCS Sleep Studio}"; Flags: nowait postinstall skipifsilent
