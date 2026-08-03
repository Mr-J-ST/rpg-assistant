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

function Get-ProviderChoices {
  return @(
    [PSCustomObject]@{ Id = "openai"; Label = "OpenAI"; BaseUrl = "https://api.openai.com/v1"; DefaultModel = "gpt-5.6-sol"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "anthropic"; Label = "Anthropic Claude"; BaseUrl = "https://api.anthropic.com/v1"; DefaultModel = "claude-sonnet-5"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "google"; Label = "Google Gemini"; BaseUrl = "https://generativelanguage.googleapis.com/v1beta"; DefaultModel = "gemini-3.6-flash"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "deepseek"; Label = "DeepSeek"; BaseUrl = "https://api.deepseek.com"; DefaultModel = "deepseek-v4-pro"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "xai"; Label = "xAI Grok"; BaseUrl = "https://api.x.ai/v1"; DefaultModel = "grok-4.5"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "mistral"; Label = "Mistral AI"; BaseUrl = "https://api.mistral.ai/v1"; DefaultModel = "mistral-large-latest"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "openrouter"; Label = "OpenRouter"; BaseUrl = "https://openrouter.ai/api/v1"; DefaultModel = "~openai/gpt-latest"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "qwen"; Label = "阿里云百炼 Qwen"; BaseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1"; DefaultModel = "qwen3.7-plus"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "kimi"; Label = "Kimi / Moonshot"; BaseUrl = "https://api.moonshot.cn/v1"; DefaultModel = "kimi-k3"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "zhipu"; Label = "智谱 GLM"; BaseUrl = "https://open.bigmodel.cn/api/paas/v4"; DefaultModel = "glm-5.2"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "minimax"; Label = "MiniMax"; BaseUrl = "https://api.minimaxi.com/v1"; DefaultModel = "MiniMax-M2.7"; ApiKeyOptional = $false },
    [PSCustomObject]@{ Id = "custom"; Label = "自定义 OpenAI 兼容接口"; BaseUrl = "http://127.0.0.1:11434/v1"; DefaultModel = "local-model"; ApiKeyOptional = $true }
  )
}

function Read-ProviderConfiguration {
  $providers = @(Get-ProviderChoices)
  while ($true) {
    Write-Host ""
    Write-Host "请选择模型服务商："
    for ($index = 0; $index -lt $providers.Count; $index += 1) {
      $defaultMark = if ($index -eq 0) { "（默认）" } else { "" }
      Write-Host ("  [{0}] {1}{2}" -f ($index + 1), $providers[$index].Label, $defaultMark)
    }
    $selection = Read-Host "请输入编号，直接回车选择 OpenAI"
    if ([string]::IsNullOrWhiteSpace($selection)) {
      $provider = $providers[0]
      break
    }
    $selectedIndex = 0
    if ([int]::TryParse($selection.Trim(), [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $providers.Count) {
      $provider = $providers[$selectedIndex - 1]
      break
    }
    Write-Host "请输入列表中的有效编号。" -ForegroundColor Yellow
  }

  $baseUrl = $provider.BaseUrl
  if ($provider.Id -eq "custom") {
    $enteredBaseUrl = Read-Host "API Base URL [$baseUrl]"
    if (-not [string]::IsNullOrWhiteSpace($enteredBaseUrl)) {
      $baseUrl = $enteredBaseUrl.Trim().TrimEnd("/")
    }
    if ($baseUrl -notmatch '^https?://') {
      throw "API Base URL 必须以 http:// 或 https:// 开头。"
    }
  }

  $model = Read-Host ("模型 ID [{0}]" -f $provider.DefaultModel)
  if ([string]::IsNullOrWhiteSpace($model)) {
    $model = $provider.DefaultModel
  } else {
    $model = $model.Trim()
  }

  return [PSCustomObject]@{
    Id = $provider.Id
    Label = $provider.Label
    BaseUrl = $baseUrl
    Model = $model
    ApiKeyOptional = $provider.ApiKeyOptional
  }
}

function Read-OneTimeApiKey {
  param(
    [string]$ProviderLabel,
    [bool]$AllowEmpty = $false
  )

  while ($true) {
    Write-Host ""
    Write-Host "API Key 仅用于本次运行，不会写入文件或场景资料。"
    $prompt = if ($AllowEmpty) {
      "请输入 $ProviderLabel API Key（本地无鉴权接口可直接回车）"
    } else {
      "请输入 $ProviderLabel API Key（输入内容不会显示）"
    }
    $secureKey = Read-Host $prompt -AsSecureString
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
      $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }

    if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
      return $plainKey.Trim()
    }
    if ($AllowEmpty) {
      return ""
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
$managedEnvironmentNames = @("AI_PROVIDER", "AI_API_KEY", "AI_BASE_URL", "AI_DEFAULT_MODEL", "AI_ONLINE_MODE", "OPENAI_API_KEY")
$previousEnvironment = @{}
foreach ($environmentName in $managedEnvironmentNames) {
  $previousEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, "Process")
}

$onlineConfiguration = $null
$oneTimeApiKey = $null

if ($launchMode -eq "online") {
  $onlineConfiguration = Read-ProviderConfiguration
  $oneTimeApiKey = Read-OneTimeApiKey -ProviderLabel $onlineConfiguration.Label -AllowEmpty $onlineConfiguration.ApiKeyOptional
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
  [Environment]::SetEnvironmentVariable("AI_PROVIDER", $onlineConfiguration.Id, "Process")
  [Environment]::SetEnvironmentVariable("AI_API_KEY", $oneTimeApiKey, "Process")
  [Environment]::SetEnvironmentVariable("AI_BASE_URL", $onlineConfiguration.BaseUrl, "Process")
  [Environment]::SetEnvironmentVariable("AI_DEFAULT_MODEL", $onlineConfiguration.Model, "Process")
  [Environment]::SetEnvironmentVariable("AI_ONLINE_MODE", "1", "Process")
  [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $null, "Process")
  Write-Host ""
  Write-Host ("将以在线模型模式启动：{0} / {1}" -f $onlineConfiguration.Label, $onlineConfiguration.Model) -ForegroundColor Green
} else {
  foreach ($environmentName in $managedEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($environmentName, $null, "Process")
  }
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
  foreach ($environmentName in $managedEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($environmentName, $previousEnvironment[$environmentName], "Process")
  }
  $oneTimeApiKey = $null
}

exit $nodeExitCode
