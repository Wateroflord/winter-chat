@echo off
chcp 65001 >nul
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
> "%STARTUP%\Winter Chat Server.bat" echo @echo off
>> "%STARTUP%\Winter Chat Server.bat" echo cd /d "%~dp0"
>> "%STARTUP%\Winter Chat Server.bat" echo start "Winter Chat Server" /min "%~dp0winter-chat-server.exe" --no-browser
echo.
echo Готово! Сервер будет сам запускаться, когда ты входишь в Windows.
echo Важно: не перемещай эту папку, иначе автозапуск перестанет работать.
echo.
pause
