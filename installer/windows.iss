; Windows installer, built by .github/workflows/build_windows.yml with
; ISCC /DBuild=<build number>. It installs for the current user only (no
; administrator rights needed) and is also what the app runs silently to
; update itself. The app's data lives in the user's AppData folder, outside
; the program folder, so installing over an older version keeps it.
#ifndef Build
  #define Build "0"
#endif

[Setup]
AppId={{8F2A6C1E-5B7D-4E3A-9C21-7D4B2E6F1A90}
AppName=مدیریت مالی شخصی
AppVersion=1.0.{#Build}
AppPublisher=Modiriat Mali
DefaultDirName={localappdata}\Programs\Modiriat Mali
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\installer-output
OutputBaseFilename=ModiriatMali-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\personal_finance.exe
UninstallDisplayName=مدیریت مالی شخصی
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Files of an older version that the new one no longer has.
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\مدیریت مالی شخصی"; Filename: "{app}\personal_finance.exe"
Name: "{autodesktop}\مدیریت مالی شخصی"; Filename: "{app}\personal_finance.exe"; Tasks: desktopicon

[Run]
; Also after a silent update, so the app comes back by itself.
Filename: "{app}\personal_finance.exe"; Description: "{cm:LaunchProgram,مدیریت مالی شخصی}"; Flags: nowait postinstall
