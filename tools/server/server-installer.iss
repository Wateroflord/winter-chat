; Установщик Winter Chat Server (Inno Setup 6): запустил — сервер готов.
; Ставит сервер в профиль пользователя, одним запросом Windows настраивает брандмауэр
; и сон, включает автозапуск в фоне (без чёрного окна). Данные (winter-chat-data) при
; обновлении и удалении остаются на месте.
#define BuildNo GetEnv("BUILD_NO")
#if BuildNo == ""
  #define BuildNo "0"
#endif

[Setup]
AppId={{326EC2C1-328E-40A2-AC0C-32F128771DD2}
AppName=Winter Chat Server
AppVersion=1.0.{#BuildNo}
AppPublisher=Winter Hub
UninstallDisplayName=Winter Chat Server
DefaultDirName={localappdata}\Programs\Winter Chat Server
DisableDirPage=yes
DefaultGroupName=Winter Chat Server
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=Winter-Chat-Server-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=server.ico
UninstallDisplayIcon={app}\server.ico
CloseApplications=force
RestartApplications=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Значок на рабочем столе"
Name: "autostart"; Description: "Запускать сервер вместе с Windows (в фоне, без окна)"
Name: "firewall"; Description: "Разрешить сервер в брандмауэре Windows (чтобы друзья могли подключаться)"
Name: "nosleep"; Description: "Не давать компьютеру засыпать, когда он от сети (и при закрытой крышке)"

[Dirs]
Name: "{app}\winter-chat-data"; Flags: uninsneveruninstall

[Files]
Source: "..\..\pkg\winter-chat-server.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\pkg\livekit-server.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\pkg\LiveKit-LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "server-setup.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "server.ico"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
; Автозапуск версии из архива («Автозапуск - включить.bat») — иначе при входе в Windows запустятся два сервера.
Type: files; Name: "{userstartup}\Winter Chat Server.bat"
; Автозапуск выключили при переустановке.
Type: files; Name: "{userstartup}\Winter Chat Server.lnk"; Tasks: not autostart

[Icons]
Name: "{group}\Winter Chat Server"; Filename: "{app}\winter-chat-server.exe"; Parameters: "--background"; WorkingDir: "{app}"; IconFilename: "{app}\server.ico"; Comment: "Запустить сервер и открыть панель"; Flags: runminimized
Name: "{group}\Выключить сервер"; Filename: "{app}\winter-chat-server.exe"; Parameters: "--stop"; WorkingDir: "{app}"; IconFilename: "{app}\server.ico"; Flags: runminimized
Name: "{group}\Папка с данными сервера"; Filename: "{app}\winter-chat-data"
Name: "{group}\Удалить Winter Chat Server"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Winter Chat Server"; Filename: "{app}\winter-chat-server.exe"; Parameters: "--background"; WorkingDir: "{app}"; IconFilename: "{app}\server.ico"; Comment: "Запустить сервер и открыть панель"; Flags: runminimized; Tasks: desktopicon
Name: "{userstartup}\Winter Chat Server"; Filename: "{app}\winter-chat-server.exe"; Parameters: "--background --no-browser"; WorkingDir: "{app}"; IconFilename: "{app}\server.ico"; Flags: runminimized; Tasks: autostart

[Run]
Filename: "{app}\winter-chat-server.exe"; Parameters: "--background"; WorkingDir: "{app}"; Description: "Запустить сервер и открыть панель"; Flags: nowait postinstall skipifsilent

[Code]
const
  RegKey = 'Software\Winter Chat Server';

function SetupArgs(): String;
begin
  Result := '';
  if WizardIsTaskSelected('firewall') then Result := Result + ' firewall';
  if WizardIsTaskSelected('nosleep') then Result := Result + ' nosleep';
  Result := Trim(Result);
end;

procedure StopServer();
var
  Exe: String;
  Code: Integer;
begin
  Exe := ExpandConstant('{app}\winter-chat-server.exe');
  if FileExists(Exe) then
    Exec(Exe, '--stop', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  // Обновление: сначала аккуратно выключить работающий сервер, потом менять файлы.
  StopServer();
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Args, Done, Mark: String;
  Code: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Args := SetupArgs();
  Mark := ExpandConstant('{app}') + '|' + Args;
  // Брандмауэр и сон — один запрос Windows «Разрешить вносить изменения?».
  // При обновлении (то же самое уже сделано) второй раз не спрашиваем.
  if (Args <> '') and not (RegQueryStringValue(HKCU, RegKey, 'SetupDone', Done) and (Done = Mark)) then
  begin
    if ShellExec('runas', ExpandConstant('{app}\server-setup.cmd'), Args, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
      RegWriteStringValue(HKCU, RegKey, 'SetupDone', Mark);
  end;
  // Тихая установка или обновление (из Winter Hub): сразу запустить сервер в фоне.
  if WizardSilent then
    Exec(ExpandConstant('{app}\winter-chat-server.exe'), '--background --no-browser', ExpandConstant('{app}'), SW_HIDE, ewNoWait, Code);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Done: String;
  Code: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    StopServer();
    if RegQueryStringValue(HKCU, RegKey, 'SetupDone', Done) and (Pos('firewall', Done) > 0) then
      ShellExec('runas', ExpandConstant('{app}\server-setup.cmd'), 'remove', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code);
    RegDeleteKeyIncludingSubkeys(HKCU, RegKey);
  end;
  if (CurUninstallStep = usPostUninstall) and not UninstallSilent then
    MsgBox('Сообщения, файлы и аккаунты остались в папке:' + #13#10 + ExpandConstant('{app}\winter-chat-data') + #13#10 + #13#10 +
      'Если поставишь сервер снова, он их подхватит. Не нужны — удали эту папку.', mbInformation, MB_OK);
end;
