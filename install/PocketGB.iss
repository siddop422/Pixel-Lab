#define AppName "PocketGB"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef PublishDir
  #define PublishDir "..\publish"
#endif
#define AppExeName "PocketGB.exe"

[Setup]
AppId={{9C1B127B-AD23-4E01-94A4-0BFECC2B1D31}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=siddop422
AppPublisherURL=https://github.com/siddop422/Pixel-Lab
AppSupportURL=https://github.com/siddop422/Pixel-Lab/issues
AppUpdatesURL=https://github.com/siddop422/Pixel-Lab/releases
AppVerName=PocketGB {#AppVersion}
VersionInfoVersion={#AppVersion}
SetupIconFile=..\assets\PocketGB.ico
DefaultDirName={localappdata}\Programs\PocketGB
DefaultGroupName=PocketGB
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\dist
OutputBaseFilename=PocketGB-Setup-{#AppVersion}
SetupLogging=yes
UsePreviousAppDir=yes
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
ChangesAssociations=yes
LicenseFile=..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "associate"; Description: "Open Game Boy ROM files with PocketGB"; GroupDescription: "File associations:"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\PocketGB"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\PocketGB"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\.gb"; ValueType: string; ValueName: ""; ValueData: "PocketGB.GameBoyROM"; Tasks: associate; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.gbc"; ValueType: string; ValueName: ""; ValueData: "PocketGB.GameBoyROM"; Tasks: associate; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.sgb"; ValueType: string; ValueName: ""; ValueData: "PocketGB.GameBoyROM"; Tasks: associate; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\PocketGB.GameBoyROM"; ValueType: string; ValueName: ""; ValueData: "Game Boy ROM"; Tasks: associate; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\PocketGB.GameBoyROM\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Tasks: associate
Root: HKCU; Subkey: "Software\Classes\PocketGB.GameBoyROM\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Tasks: associate

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch PocketGB"; Flags: postinstall nowait skipifsilent
