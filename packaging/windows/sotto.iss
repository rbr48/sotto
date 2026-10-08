; Sotto for Windows: installer built with Inno Setup 6 in the release
; workflow.
;   iscc /DAppVersion=0.1.7 /DSourceDir=<Release folder> /DOutputDir=<dist> sotto.iss
;
; Installs per user (no administrator rights, like the portable ZIP) into
; %LOCALAPPDATA%\Programs\Sotto. It adds a Start menu entry and an uninstaller
; (Settings > Apps). Installing a newer version over an older one closes Sotto
; first and keeps the user's data: contacts and history live in the user's
; app-data folder, not in the program folder.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
; Keep this AppId forever: it is how Windows recognises an update.
AppId={{D44D3E58-C89A-4CAC-918B-BD5CC12187DB}
AppName=Sotto
AppVersion={#AppVersion}
AppVerName=Sotto {#AppVersion}
AppPublisher=Izhaan Intellect
AppPublisherURL=https://sottocall.com
AppSupportURL=https://sottocall.com
AppUpdatesURL=https://github.com/rbr48/sotto/releases/latest
DefaultDirName={autopf}\Sotto
DefaultGroupName=Sotto
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=sotto-windows-x64-setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\sotto.exe
UninstallDisplayName=Sotto
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Sotto"; Filename: "{app}\sotto.exe"
Name: "{autodesktop}\Sotto"; Filename: "{app}\sotto.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\sotto.exe"; Description: "{cm:LaunchProgram,Sotto}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; "Start Sotto when I log in" adds a Run entry; remove it with the app.
Filename: "reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v Sotto /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"
