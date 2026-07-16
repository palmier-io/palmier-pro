; PalmierPro Windows installer (Stage E2).
;
; Packages the self-contained payload scripts/publish.ps1 produces under
; artifacts/publish/ into a single silent-install-capable setup.exe. Built via
; scripts/build-installer.ps1, which runs publish.ps1 first and then passes
; AppVersion here with /D (reading platforms/windows/VERSION) — do not hardcode
; a version below; ISCC.exe run directly without /DAppVersion=... falls back to
; the "0.0.0-dev" placeholder so the script still compiles for a manual check.
;
; Per-user install (PrivilegesRequired=lowest): no admin prompt, installs under
; %LOCALAPPDATA%\Programs\PalmierPro. This is deliberately NOT the app's own
; state directory (%LOCALAPPDATA%\PalmierPro — see AppPaths.cs: project
; registry, DiskCache, Serilog logs). The uninstaller only ever removes what it
; put under {app}, so a user's projects registry, cache, and logs survive an
; uninstall untouched by construction — nothing in this script deletes that
; directory, and it must stay that way.
;
; Unsigned: no Authenticode certificate exists yet (post-Phase-1, see AGENTS.md
; roadmap). Windows SmartScreen will warn on first run until one is added.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

#define AppName "PalmierPro"
#define AppPublisher "PalmierPro"
#define AppExeName "PalmierPro.App.exe"
#define PublishDir "..\artifacts\publish"
#define LicenseFilePath "..\..\..\LICENSE"

[Setup]
; Fixed GUID: identifies this app across versions so re-running a newer
; installer upgrades in place instead of side-installing. Never regenerate.
AppId={{1476B519-EAC4-4B25-9150-6434353043B0}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
; Per-user, no-admin install: matches the "silent-install capable, no elevation
; prompt" requirement. {localappdata}\Programs is user-writable, so this needs
; no privilege elevation at all.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; The published payload is a win-x64 self-contained deployment (bundled CLR +
; Windows App SDK); refuse to even offer install on non-x64-compatible hardware.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Floor matches the Windows App SDK's own minimum (Windows 10 1809 / 17763).
MinVersion=10.0.17763
LicenseFile={#LicenseFilePath}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir=..\artifacts\installer
OutputBaseFilename=PalmierProSetup-{#AppVersion}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplicationsFilter={#AppExeName}
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Whole publish payload (app, PalmierEngine.dll, FFmpeg DLLs, shaders, fonts,
; WinAppSDK/CLR runtime, THIRD_PARTY_NOTICES.md, LICENSE) verbatim — publish.ps1
; already verified completeness, so this is a straight recursive copy.
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

; No [UninstallDelete] entries on purpose — see header comment. The uninstaller
; must only remove {app} (the install directory) and its own Start Menu
; shortcuts; %LOCALAPPDATA%\PalmierPro (projects registry, cache, logs) is out
; of scope for both install and uninstall.
