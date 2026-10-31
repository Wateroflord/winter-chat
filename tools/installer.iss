; Установщик Winter Chat для Windows (Inno Setup 6), ставится в профиль пользователя.
#define BuildNo GetEnv("BUILD_NO")
#if BuildNo == ""
  #define BuildNo "0"
#endif

[Setup]
AppId={{A7C3E1D4-6B2F-4E8A-9D51-3F0B7C2E8A64}
AppName=Winter Chat
AppVersion=1.0.{#BuildNo}
AppPublisher=Winter Hub
DefaultDirName={localappdata}\Programs\Winter Chat
DefaultGroupName=Winter Chat
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Winter-Chat-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\winter_chat.exe
CloseApplications=force
RestartApplications=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Winter Chat"; Filename: "{app}\winter_chat.exe"
Name: "{group}\{cm:UninstallProgram,Winter Chat}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Winter Chat"; Filename: "{app}\winter_chat.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\winter_chat.exe"; Description: "{cm:LaunchProgram,Winter Chat}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\winter_chat.exe"; Flags: nowait; Check: WizardSilent
