@echo off
setlocal EnableExtensions
title KitDroid
cd /d "%~dp0"

rem Menu di KitDroid. Chiede i permessi di amministratore e poi propone: installa, disinstalla, controlla WSA.
rem Con "RUN.bat /noadmin" salta la richiesta dei permessi (utile solo per provare il menu).
rem
rem KitDroid menu. It asks for administrator rights, then offers: install, uninstall, check WSA.
rem With "RUN.bat /noadmin" the administrator request is skipped (only useful to test the menu).

if /i "%~1"=="/noadmin" goto menu
net session >nul 2>&1
if %errorlevel%==0 goto menu

echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
if errorlevel 1 goto refused
exit /b

:refused
echo.
echo Administrator rights were not granted, nothing was done.
pause
exit /b 1

:menu
cls
color 0A
call :banner
echo.
echo       1) Install KitDroid
echo       2) Uninstall KitDroid
echo       3) Check WSA
echo       Q) Quit
echo.
choice /c 123Q /n /m "      Choose [1,2,3,Q]: "
if errorlevel 4 goto end
if errorlevel 3 goto check
if errorlevel 2 goto uninstall
goto install

:install
cls
call :banner
echo.
echo   ==^> Install KitDroid
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
set "rc=%errorlevel%"
goto done

:uninstall
cls
call :banner
echo.
echo   ==^> Uninstall KitDroid
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
set "rc=%errorlevel%"
goto done

:check
cls
call :banner
echo.
echo   ==^> Check WSA
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Check-Wsa.ps1"
set "rc=%errorlevel%"
goto done

:done
echo.
if "%rc%"=="0" (echo   Finished.) else (echo   Finished with errors, exit code %rc%. Read the messages above.)
echo.
pause
goto menu

:banner
echo.
echo                  \           /
echo                   \         /
echo               _.-''''''''''''-._
echo             .'                  '.
echo            /     O          O     \
echo           /________________________\
echo.
echo    _  __ _  _    ____                _     _
echo   ^| ^|/ /(_)^| ^|_ ^|  _ \  _ __   ___  (_)  __^| ^|
echo   ^| ' / ^| ^|^| __^|^| ^| ^| ^|^| '__^| / _ \ ^| ^| / _` ^|
echo   ^| . \ ^| ^|^| ^|_ ^| ^|_^| ^|^| ^|   ^| (_) ^|^| ^|^| (_^| ^|
echo   ^|_^|\_\^|_^| \__^|^|____/ ^|_^|    \___/ ^|_^| \__,_^|
echo.
echo        APK installer for Windows Subsystem for Android
exit /b

:end
endlocal
exit /b 0
