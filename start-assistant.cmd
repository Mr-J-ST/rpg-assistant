@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "BUNDLED_NODE=C:\Users\32313\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
set "NODE_EXE="

if exist "%BUNDLED_NODE%" set "NODE_EXE=%BUNDLED_NODE%"
if not defined NODE_EXE (
  where node >nul 2>nul
  if not errorlevel 1 set "NODE_EXE=node"
)

if not defined NODE_EXE (
  echo Node.js 20 or newer was not found. Install Node.js and try again.
  pause
  exit /b 1
)

echo.
echo RPG Assistant is starting...
echo URL: http://127.0.0.1:4317
if not defined OPENAI_API_KEY echo OPENAI_API_KEY is not set. Demo generation mode will be used.
echo Press Ctrl+C to stop.
echo.

"%NODE_EXE%" "%PROJECT_DIR%server.mjs" %*
set "APP_EXIT=%ERRORLEVEL%"
if not "%APP_EXIT%"=="0" pause
exit /b %APP_EXIT%
