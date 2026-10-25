; Compile with Inno Setup 6.3+ via tool/package-windows.ps1.
#if Ver < EncodeVer(6, 3, 0, 0)
  #error Inno Setup 6.3 or later is required.
#endif
#ifndef AppVersion
  #error Invoke tool/package-windows.ps1 with an explicit target architecture.
#endif
#if TargetArch == "arm64"
  #define AllowedArchitecture "arm64"
#elif TargetArch == "x64"
  #define AllowedArchitecture "x64compatible and not arm64"
#else
  #error Unsupported TargetArch.
#endif

[Setup]
AppId=Portly.SerialDebugger
AppName=Portly
AppVersion={#AppVersion}
AppVerName=Portly {#AppVersion} ({#TargetArch})
VersionInfoVersion={#AppVersion}.{#BuildNumber}
AppPublisher=Portly contributors
DefaultDirName={localappdata}\Programs\Portly
DefaultGroupName=Portly
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\portly.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Portly"; Filename: "{app}\portly.exe"
Name: "{autodesktop}\Portly"; Filename: "{app}\portly.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\portly.exe"; Description: "{cm:LaunchProgram,Portly}"; Flags: nowait postinstall skipifsilent

; User configuration, history, and logs are deliberately not uninstalled.
