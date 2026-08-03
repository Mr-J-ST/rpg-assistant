param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4317,
    [switch]$SelfTest,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $projectDirectory 'start-assistant.ps1'

& $launcher `
    -ProjectDirectory $projectDirectory `
    -AssistantPort $Port `
    -NoBrowser ([int]$NoBrowser.IsPresent) `
    -SelfTest ([int]$SelfTest.IsPresent)

exit $LASTEXITCODE
