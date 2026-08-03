@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "ASSISTANT_PORT=4317"
set "ASSISTANT_NO_BROWSER=0"
set "ASSISTANT_SELF_TEST=0"
set "ASSISTANT_DEMO=0"

:parse_arguments
if "%~1"=="" goto launch

if /I "%~1"=="--port" (
  if "%~2"=="" (
    echo Missing value after --port.
    exit /b 2
  )
  set "ASSISTANT_PORT=%~2"
  shift
  shift
  goto parse_arguments
)

if /I "%~1"=="--no-browser" (
  set "ASSISTANT_NO_BROWSER=1"
  shift
  goto parse_arguments
)

if /I "%~1"=="--self-test" (
  set "ASSISTANT_SELF_TEST=1"
  shift
  goto parse_arguments
)

if /I "%~1"=="--demo" (
  set "ASSISTANT_DEMO=1"
  shift
  goto parse_arguments
)

echo Unknown option: %~1
exit /b 2

:launch
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_DIR%start-assistant.ps1" -ProjectDirectory "%PROJECT_DIR%." -AssistantPort "%ASSISTANT_PORT%" -NoBrowser "%ASSISTANT_NO_BROWSER%" -SelfTest "%ASSISTANT_SELF_TEST%" -Demo "%ASSISTANT_DEMO%"
set "APP_EXIT=%ERRORLEVEL%"
if not "%APP_EXIT%"=="0" pause
exit /b %APP_EXIT%
