@echo off
rem Winter Chat Server: settings that need administrator rights.
rem The installer runs it once (one Windows "Yes/No" prompt):
rem   firewall - allow the server and the calls (livekit-server) in Windows Firewall
rem   nosleep  - the computer does not fall asleep while plugged in (also with the lid closed)
rem   remove   - delete the firewall rules (uninstall)
setlocal
set "DIR=%~dp0"
set FW=0
set SLEEP=0
set REMOVE=0
:args
if "%~1"=="" goto run
if /i "%~1"=="firewall" set FW=1
if /i "%~1"=="nosleep" set SLEEP=1
if /i "%~1"=="remove" set REMOVE=1
shift
goto args

:run
if "%FW%%REMOVE%"=="00" goto sleep
netsh advfirewall firewall delete rule name="Winter Chat Server" >nul 2>&1
netsh advfirewall firewall delete rule name="Winter Chat Server (calls)" >nul 2>&1
if "%REMOVE%"=="1" goto sleep
netsh advfirewall firewall add rule name="Winter Chat Server" dir=in action=allow program="%DIR%winter-chat-server.exe" enable=yes profile=any >nul || exit /b 1
netsh advfirewall firewall add rule name="Winter Chat Server (calls)" dir=in action=allow program="%DIR%livekit-server.exe" enable=yes profile=any >nul || exit /b 1

:sleep
if not "%SLEEP%"=="1" goto done
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 >nul 2>&1
powercfg /setactive SCHEME_CURRENT >nul 2>&1

:done
exit /b 0
