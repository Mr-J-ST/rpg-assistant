param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectDirectory,

  [ValidateRange(1024, 65535)]
  [int]$AssistantPort = 4317,

  [ValidateSet(0, 1)]
  [int]$NoBrowser = 0,

  [ValidateSet(0, 1)]
  [int]$SelfTest = 0,

  [ValidateSet(0, 1)]
  [int]$Demo = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-NodeExecutable {
  $bundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    return $bundledNode
  }

  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($nodeCommand) {
    return $nodeCommand.Source
  }

  throw "Node.js 20 or newer was not found. Install Node.js and try again."
}

function Get-ExistingAssistantStatus {
  param(
    [string]$Url
  )

  try {
    $status = Invoke-RestMethod -Uri "$Url/api/status" -Method Get -TimeoutSec 2
    $propertyNames = @($status.PSObject.Properties.Name)
    if (($propertyNames -contains "appId" -and $status.appId -eq "scene-scribe-rpg-assistant") -or
        (($propertyNames -contains "generationMode") -and ($propertyNames -contains "models"))) {
      return $status
    }
  } catch {
    return $null
  }

  return $null
}

function Test-TcpPortInUse {
  param([int]$Port)

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $connection = $client.ConnectAsync("127.0.0.1", $Port)
    return $connection.Wait(700) -and $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Get-ListenerProcessIds {
  param([int]$Port)

  $processIds = @()
  $portPattern = [Regex]::Escape([string]$Port)
  foreach ($line in (netstat -ano)) {
    if ($line -match "^\s*TCP\s+127\.0\.0\.1:$portPattern\s+\S+\s+LISTENING\s+(\d+)\s*$") {
      $processIds += [int]$Matches[1]
    }
  }
  return @($processIds | Select-Object -Unique)
}

function Stop-ExistingAssistant {
  param(
    [object]$Status,
    [int]$Port
  )

  $listenerProcessIds = @(Get-ListenerProcessIds -Port $Port)
  if ($listenerProcessIds.Count -ne 1) {
    throw "无法唯一确认现有助手进程。请关闭原来的助手窗口后重试。"
  }

  $targetProcessId = $listenerProcessIds[0]
  $statusPropertyNames = @($Status.PSObject.Properties.Name)
  if (($statusPropertyNames -contains "processId") -and [int]$Status.processId -ne $targetProcessId) {
    throw "端口进程与助手状态不一致。请关闭原来的助手窗口后重试。"
  }

  $targetProcess = Get-Process -Id $targetProcessId -ErrorAction Stop
  if ($targetProcess.ProcessName -ne "node") {
    throw "现有端口并非由跑团助手的 Node 进程占用，未执行重启。"
  }

  Stop-Process -Id $targetProcessId
  for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
    Start-Sleep -Milliseconds 100
    if (-not (Test-TcpPortInUse -Port $Port)) {
      return
    }
  }
  throw "现有助手未能及时停止。请关闭原来的助手窗口后重试。"
}

function Read-LaunchMode {
  while ($true) {
    Write-Host ""
    Write-Host "请选择运行模式："
    Write-Host "  [1] 在线模型（默认）"
    Write-Host "  [2] 演示模式"
    $selection = Read-Host "请输入 1 或 2，直接回车选择在线模型"
    if ([string]::IsNullOrWhiteSpace($selection) -or $selection.Trim() -eq "1") {
      return "online"
    }
    if ($selection.Trim() -eq "2") {
      return "demo"
    }
    Write-Host "请输入 1 或 2。" -ForegroundColor Yellow
  }
}

function Read-OneTimeApiKey {
  while ($true) {
    Write-Host ""
    Write-Host "API Key 仅用于本次运行，不会写入文件或场景资料。"
    $secureKey = Read-Host "请输入 OpenAI API Key（输入内容不会显示）" -AsSecureString
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
      $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }

    if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
      return $plainKey.Trim()
    }
    Write-Host "API Key 不能为空。也可以重新启动并选择演示模式。" -ForegroundColor Yellow
  }
}

$resolvedProjectDirectory = [IO.Path]::GetFullPath($ProjectDirectory)
$serverFile = Join-Path $resolvedProjectDirectory "server.mjs"
if (-not (Test-Path -LiteralPath $serverFile -PathType Leaf)) {
  throw "server.mjs was not found in the project directory."
}

$nodeExecutable = Find-NodeExecutable

if ($SelfTest -eq 1) {
  & $nodeExecutable $serverFile "--self-test"
  exit $LASTEXITCODE
}

$assistantUrl = "http://127.0.0.1:$AssistantPort"
$existingAssistantStatus = Get-ExistingAssistantStatus -Url $assistantUrl

if (-not $existingAssistantStatus -and (Test-TcpPortInUse -Port $AssistantPort)) {
  Write-Host "端口 $AssistantPort 已被其他程序占用，未打开该地址以避免进入无关服务。" -ForegroundColor Red
  Write-Host "请关闭占用程序，或使用 start-assistant.cmd --port 4318 启动。"
  exit 1
}

$launchMode = if ($Demo -eq 1) { "demo" } else { Read-LaunchMode }
$previousApiKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "Process")
$oneTimeApiKey = $null

if ($launchMode -eq "online") {
  $oneTimeApiKey = Read-OneTimeApiKey
}

if ($existingAssistantStatus) {
  Write-Host ""
  Write-Host "检测到跑团助手已在运行：$assistantUrl" -ForegroundColor Yellow
  Write-Host "要让本次选择的模式和 API Key 生效，需要重启现有助手。"
  $existingAction = Read-Host "直接回车重启；输入 O 仅打开现有页面"
  if ($existingAction.Trim().ToUpperInvariant() -eq "O") {
    if ($NoBrowser -eq 0) {
      Start-Process -FilePath $assistantUrl
      Write-Host "已在默认浏览器中打开现有页面。"
    } else {
      Write-Host "浏览器打开已被 --no-browser 跳过。"
    }
    $oneTimeApiKey = $null
    exit 0
  }

  Write-Host "正在停止现有助手……"
  Stop-ExistingAssistant -Status $existingAssistantStatus -Port $AssistantPort
}

if ($launchMode -eq "online") {
  [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $oneTimeApiKey, "Process")
  Write-Host ""
  Write-Host "将以在线模型模式启动。" -ForegroundColor Green
} else {
  [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $null, "Process")
  Write-Host ""
  Write-Host "将以演示模式启动。" -ForegroundColor Yellow
}

$serverArguments = @($serverFile, "--port", $AssistantPort)
if ($NoBrowser -eq 1) {
  $serverArguments += "--no-browser"
}

Write-Host "地址：$assistantUrl"
Write-Host "按 Ctrl+C 可停止程序。"
Write-Host ""

try {
  & $nodeExecutable @serverArguments
  $nodeExitCode = $LASTEXITCODE
} finally {
  [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $previousApiKey, "Process")
  $oneTimeApiKey = $null
}

exit $nodeExitCode
