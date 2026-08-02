param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4317,
    [switch]$SelfTest,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverPath = Join-Path $projectDir 'server.mjs'
$bundledNode = 'C:\Users\32313\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$nodeExe = $null

if (Test-Path -LiteralPath $bundledNode) {
    $nodeExe = $bundledNode
} else {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCommand) {
        $nodeExe = $nodeCommand.Source
    }
}

if (-not $nodeExe) {
    throw 'Node.js 20 or newer was not found. Install Node.js and try again.'
}

if ($SelfTest) {
    & $nodeExe $serverPath --self-test
    exit $LASTEXITCODE
}

$arguments = @($serverPath, '--port', $Port)
if ($NoBrowser) {
    $arguments += '--no-browser'
}

Write-Host ''
Write-Host 'RPG Assistant is starting...' -ForegroundColor Cyan
Write-Host ("URL: http://127.0.0.1:{0}" -f $Port) -ForegroundColor Green
if (-not $env:OPENAI_API_KEY) {
    Write-Host 'OPENAI_API_KEY is not set. Demo generation mode will be used.' -ForegroundColor Yellow
}
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

& $nodeExe @arguments
