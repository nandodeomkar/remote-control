; Remote Control -- Windows server installer (quick 260729-38z)
;
; Build with installer\build-installer.ps1, which passes the version:
;   ISCC /DMyAppVersion=1.3.0 installer\RemoteControl.iss
;
; DESIGN NOTES
;
; * PER-USER, NO ADMIN. PrivilegesRequired=lowest means no UAC prompt and
;   {autopf} resolves to %LOCALAPPDATA%\Programs. That matches everything else
;   about this app: the autostart entry is HKCU, the config lives in %APPDATA%,
;   and the paired-device store is per-user. A machine-wide install would buy
;   nothing and cost an elevation prompt on a program the owner starts daily.
;
; * SPACE-FREE DEFAULT DIRECTORY. The app's own "start with Windows" toggle
;   writes the HKCU Run value through the auto-launch crate. That crate does no
;   quoting of its own, so server-windows quotes the path itself
;   (autostart.rs::quote_path) -- but a space-free install directory keeps the
;   command line unambiguous regardless of who wrote the value.
;
; * APPMUTEX over auto-close. Setup asks the owner to quit a running copy
;   rather than letting Restart Manager terminate it. The server writes
;   config.toml (paired devices, settings) as it shuts down, so a clean
;   tray-menu Quit is worth one extra dialog on upgrades. CloseApplications
;   stays on as a backstop for any other file lock.

#define MyAppName "Remote Control"
#define MyAppExeName "RemoteControl.exe"
#define MyAppPublisher "Omkar"
#define MyAppURL "https://github.com/nandodeomkar/remote-control"

; Version is supplied by build-installer.ps1 from server-windows/Cargo.toml.
; The fallback only exists so a bare `ISCC RemoteControl.iss` still compiles.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif

; VersionInfoVersion must be strictly numeric, so it travels separately with
; any pre-release suffix stripped (build-installer.ps1 does the stripping).
#ifndef MyVersionInfo
  #define MyVersionInfo "0.0.0"
#endif

[Setup]
; NEVER change AppId -- it is the upgrade identity. A new GUID would make
; Windows treat the next release as a separate product and leave the old one
; installed alongside it.
AppId={{7C3E9A54-1B62-4F0D-9E77-2A5C8D41B6F3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases/latest
VersionInfoVersion={#MyVersionInfo}
VersionInfoDescription={#MyAppName} Setup

DefaultDirName={autopf}\RemoteControl
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
PrivilegesRequired=lowest

SetupIconFile=..\server\server-windows\assets\icon\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Shared VERBATIM with server-windows/src/single_instance.rs::MUTEX_NAME.
; A test in that module pins the string so the two cannot drift apart.
AppMutex=RemoteControl.SingleInstance
CloseApplications=yes
RestartApplications=no

OutputDir=..\dist
OutputBaseFilename=RemoteControl-Setup-v{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Both default to CHECKED. The whole reason this installer exists is that
; quitting the tray server left no way to start it again without hunting
; through a build directory -- so the launcher and the autostart entry are the
; expected outcome, not an opt-in extra.
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start {#MyAppName} when Windows starts"; GroupDescription: "Startup:"

[Files]
; The cargo artifact is named after its crate; ship it under the product name
; so Task Manager, the tray, and the shortcut all say the same thing. Safe to
; rename: the browser extension talks WebSocket (no native-messaging host
; manifest) and no source file references the exe filename.
Source: "..\server\target\release\server-windows.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; Flags: ignoreversion
; The unpacked extension travels with the server so "Load unpacked" is a
; click away -- no separate zip download, no version skew against the server
; it talks to.
;
; The two extra Flags on the Source line below are the phase-12 Pattern 5
; mitigation (T-12-57) -- named there and deliberately not spelled again in
; this comment, because the plan greps for exactly one occurrence of each and
; a comment that quotes them would trip its own gate.
;
; The risk they cover: if Chrome held a write lock on a loaded unpacked
; extension's files, Inno's file-replace failure would raise an
; Abort/Retry/Ignore whose SUPPRESSED DEFAULT IS ABORT -- and under
; /SUPPRESSMSGBOXES, which is exactly how the in-app updater runs Setup, that
; would abort the ENTIRE server install because the browser happened to be
; open. The browser being open is the common case, not an edge case. With
; these flags a locked file is instead scheduled for replacement at next boot
; via MoveFileEx, and the install completes.
;
; NOT REPRODUCED (12-16 Task 1, observed 2026-08-05 on Windows 11 26200,
; per-user install, Chrome holding the extension via Load unpacked):
;
;   * two consecutive silent upgrades (1.5.0 -> 1.5.1 -> 1.5.2) both logged
;     "Installation process succeeded" with exit code 0;
;   * neither log contained ErrorReplacingExistingFile or any
;     Abort/Retry/Ignore entry;
;   * both logged "Need to restart Windows? No", so nothing even reached the
;     deferred-replacement path these flags provide;
;   * background.js, manifest.json and README.md were all overwritten in place
;     underneath the running browser.
;
; So Chrome does NOT appear to hold a write lock on an unpacked extension
; directory. THE FLAGS STAY ANYWAY: they cost nothing, the observation is one
; machine and one Chrome version, and the failure they prevent takes down the
; whole update rather than just the extension. Do not remove them on the
; strength of that single clean run.
;
; This CONTRADICTS the design spec's "no .iss change is needed" claim. That
; claim was correct about the [Run] entry and the AppMutex mechanism; it did
; not consider extension-file locking.
;
; Two things these flags would NOT guarantee if the lock ever does appear. A
; per-user install without admin rights may be unable to write the
; pending-rename registry key -- and the observed install WAS per-user
; ("User privileges: None" in the log) -- in which case the replacement simply
; does not happen; the fallback there is the D-18 user-facing state, "Restart
; your browser to finish updating". And a next-boot replacement means the
; extension is still on the OLD files for the rest of the session, so the
; server's one ext.reload nudge will not change its version; the guard is what
; stops that from becoming a loop.
;
; The server exe entry above is listed FIRST deliberately -- Inno processes
; [Files] in order, so the critical artifact lands before the risky one. Do
; not reorder. Do not add a delete-after-install flag or a clean-directory
; step either: Chrome writes its own _metadata folder into unpacked extension
; directories, recursesubdirs copies in without pruning, and [UninstallDelete]
; already removes the whole directory on uninstall.
Source: "..\extension\*"; DestDir: "{app}\extension"; Flags: ignoreversion recursesubdirs createallsubdirs restartreplace uninsrestartdelete

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\{#MyAppName} browser extension"; Filename: "{app}\extension"; Comment: "Folder to pick in the browser's Load unpacked dialog"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; ---- Autostart, and the migration of any stale entry -------------------
;
; Value name "Remote Control" is what auto-launch uses inside the app, so the
; in-app Settings toggle stays in sync with whatever Setup wrote: the crate's
; is_enabled() checks only that the NAME exists and disable() removes by name
; -- neither parses the data, so a quoted path here reads back as "enabled"
; and can still be switched off from the app.
;
; Writing it unconditionally is also the migration: a pre-installer entry
; pointing at server\target\release\server-windows.exe is overwritten with the
; installed path, so boot stops launching a build-directory copy that a
; `cargo clean` could delete out from under it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: startup

; Task Manager's Startup tab records a per-entry override here. If the owner
; ever disabled the old entry there, that override would silently suppress the
; new one too. Deleting the value restores the enabled default (auto-launch
; reads a missing value as enabled).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "{#MyAppName}"; Flags: deletevalue; Tasks: startup

; Declining the startup task must REMOVE a stale entry, not leave it pointing
; at a path this install may have just superseded.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "{#MyAppName}"; Flags: deletevalue uninsdeletevalue; Check: StartupNotSelected

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\extension"

[Code]

// NOTE: comments in this section use // rather than Pascal's { }, because an
// Inno constant such as {app} written inside a { } comment closes it at the
// first brace and the rest of the comment is parsed as code.

// Used by the [Registry] Check above. Wrapped in a function so the Check
// expression stays a plain identifier.
//
// WizardIsTaskSelected is the current name (IsTaskSelected still compiles but
// emits a deprecation hint), which is why the build needs Inno Setup 6.3 or
// newer -- see installer/build-installer.ps1 and DISTRIBUTION.md.
function StartupNotSelected: Boolean;
begin
  Result := not WizardIsTaskSelected('startup');
end;

// Settings and paired devices live in %APPDATA%, outside the install
// directory, so an uninstall would otherwise orphan them silently. Ask --
// defaulting to KEEP, because the common case is reinstalling a newer build
// and wanting the phones to stay paired.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{userappdata}\RemoteControl');
    if DirExists(DataDir) then
    begin
      if MsgBox('Also delete your Remote Control settings and paired devices?'#13#10#13#10
                + DataDir + #13#10#13#10
                + 'Choose No to keep them, so a future reinstall stays paired with your phone.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
  end;
end;
