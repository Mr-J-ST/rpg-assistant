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

function Test-ProjectNodeExecutable {
  param(
    [string]$NodeExecutable,
    [string]$ExpectedVersion
  )

  try {
    $versionOutput = @(& $NodeExecutable --version)
    return $LASTEXITCODE -eq 0 -and
      $versionOutput.Count -gt 0 -and
      $versionOutput[0].Trim() -eq "v$ExpectedVersion"
  } catch {
    return $false
  }
}

function Remove-ProjectRuntimeTemporaryDirectory {
  param(
    [string]$TemporaryDirectory,
    [string]$RuntimeRoot
  )

  $resolvedRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $resolvedTemporaryDirectory = [IO.Path]::GetFullPath($TemporaryDirectory)
  $runtimePrefix = $resolvedRuntimeRoot + [IO.Path]::DirectorySeparatorChar

  if (-not $resolvedTemporaryDirectory.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a temporary directory outside the project runtime folder."
  }

  if (Test-Path -LiteralPath $resolvedTemporaryDirectory -PathType Container) {
    Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force
  }
}

function Get-ProjectNodeExecutable {
  param([string]$ProjectDirectory)

  $nodeVersion = "24.18.1"
  $nodeDistribution = "node-v$nodeVersion-win-x64"
  $nodeArchiveName = "$nodeDistribution.zip"
  $expectedArchiveHash = "EC56B84A7551893AB2324EBDFDC4AB974A63B4781162600B68A1293CC3E53765"
  $archivePath = Join-Path $ProjectDirectory "vendor\node\$nodeArchiveName"
  $runtimeRoot = Join-Path $ProjectDirectory ".runtime"
  $runtimeDirectory = Join-Path $runtimeRoot $nodeDistribution
  $nodeExecutable = Join-Path $runtimeDirectory "node.exe"

  if (Test-ProjectNodeExecutable -NodeExecutable $nodeExecutable -ExpectedVersion $nodeVersion) {
    return $nodeExecutable
  }

  if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
    throw "The project-local Node.js runtime is incomplete. Delete '.runtime' in the project folder, then start again."
  }

  if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    return $null
  }

  $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  if (-not $archiveHash.Equals($expectedArchiveHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The bundled Node.js archive failed its SHA-256 check. Download a fresh copy of the project before starting it."
  }

  New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
  $temporaryDirectory = Join-Path $runtimeRoot ("extract-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

  Write-Host "首次启动：正在准备项目内置的 Node.js 运行环境……" -ForegroundColor Cyan
  try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryDirectory
    $extractedDirectory = Join-Path $temporaryDirectory $nodeDistribution
    $extractedNode = Join-Path $extractedDirectory "node.exe"

    if (-not (Test-ProjectNodeExecutable -NodeExecutable $extractedNode -ExpectedVersion $nodeVersion)) {
      throw "The bundled Node.js runtime could not be validated after extraction."
    }

    Move-Item -LiteralPath $extractedDirectory -Destination $runtimeDirectory
  } finally {
    try {
      Remove-ProjectRuntimeTemporaryDirectory -TemporaryDirectory $temporaryDirectory -RuntimeRoot $runtimeRoot
    } catch {
      Write-Warning "Could not clean the temporary runtime folder: $($_.Exception.Message)"
    }
  }

  return $nodeExecutable
}

function Find-NodeExecutable {
  param([string]$ProjectDirectory)

  $projectNode = Get-ProjectNodeExecutable -ProjectDirectory $ProjectDirectory
  if ($projectNode) {
    return $projectNode
  }

  $bundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    return $bundledNode
  }

  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($nodeCommand) {
    return $nodeCommand.Source
  }

  throw "Node.js 20 or newer was not found, and this copy of the project does not include its portable runtime."
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
  param(
    [string]$NodeExecutable,
    [string]$ServerFile
  )

  $catalogOutput = @(& $NodeExecutable $ServerFile "--print-provider-catalog")
  if ($LASTEXITCODE -ne 0 -or $catalogOutput.Count -eq 0) {
    throw "无法从程序读取模型服务商目录。"
  }

  try {
    $decodedProviders = (($catalogOutput -join "`n") | ConvertFrom-Json)
    $providers = @()
    foreach ($decodedProvider in $decodedProviders) {
      $providers += $decodedProvider
    }
  } catch {
    throw "模型服务商目录格式无效：$($_.Exception.Message)"
  }

  if ($providers.Count -eq 0) {
    throw "模型服务商目录为空。"
  }
  return $providers
}

function Read-ManualModelId {
  param([string]$DefaultModel)

  while ($true) {
    $enteredModel = Read-Host ("请输入完整模型 ID [{0}]" -f $DefaultModel)
    $model = if ([string]::IsNullOrWhiteSpace($enteredModel)) { $DefaultModel } else { $enteredModel.Trim() }
    if ($model.Length -gt 160) {
      Write-Host "模型 ID 不能超过 160 个字符。" -ForegroundColor Yellow
      continue
    }
    if ($model -notmatch '^[A-Za-z0-9._~:/@+-]+$') {
      Write-Host "模型 ID 只能包含英文字母、数字以及 . _ ~ : / @ + -。" -ForegroundColor Yellow
      continue
    }
    return $model
  }
}

function Read-ModelChoice {
  param([object]$Provider)

  $models = @($Provider.Models)
  while ($true) {
    Write-Host ""
    Write-Host ("{0} 推荐模型 ID：" -f $Provider.Label)
    for ($index = 0; $index -lt $models.Count; $index += 1) {
      $defaultMark = if ($models[$index] -eq $Provider.DefaultModel) { "（默认）" } else { "" }
      Write-Host ("  [{0}] {1}{2}" -f ($index + 1), $models[$index], $defaultMark)
    }
    if ($models.Count -eq 0) {
      Write-Host "  此接口没有通用推荐列表，请输入接口实际支持的模型 ID。"
    } else {
      Write-Host "  [M] 手动输入其他模型 ID"
    }

    $selectionPrompt = if ($models.Count -eq 0) {
      "直接回车输入模型 ID"
    } else {
      "请输入编号；直接回车选择默认模型；输入 M 手动填写"
    }
    $selection = Read-Host $selectionPrompt
    $model = $null

    if ($models.Count -eq 0) {
      $model = Read-ManualModelId -DefaultModel $Provider.DefaultModel
    } elseif ([string]::IsNullOrWhiteSpace($selection)) {
      $model = $Provider.DefaultModel
    } elseif ($selection.Trim().ToUpperInvariant() -eq "M") {
      $model = Read-ManualModelId -DefaultModel $Provider.DefaultModel
    } else {
      $selectedIndex = 0
      if ([int]::TryParse($selection.Trim(), [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $models.Count) {
        $model = $models[$selectedIndex - 1]
      } else {
        Write-Host "请输入列表中的有效编号或 M。" -ForegroundColor Yellow
        continue
      }
    }

    Write-Host ""
    Write-Host ("最终模型 ID：{0}" -f $model) -ForegroundColor Cyan
    while ($true) {
      $confirmation = Read-Host "直接回车确认；输入 R 重新选择"
      if ([string]::IsNullOrWhiteSpace($confirmation)) {
        return $model
      }
      if ($confirmation.Trim().ToUpperInvariant() -eq "R") {
        break
      }
      Write-Host "请直接回车确认，或输入 R 重新选择。" -ForegroundColor Yellow
    }
  }
}

function Read-ProviderConfiguration {
  param([object[]]$Providers)

  $providers = @($Providers)
  while ($true) {
    Write-Host ""
    Write-Host "请选择模型服务商："
    for ($index = 0; $index -lt $providers.Count; $index += 1) {
      $defaultMark = if ($index -eq 0) { "（默认）" } else { "" }
      Write-Host ("  [{0}] {1}{2} — 默认模型：{3}" -f ($index + 1), $providers[$index].Label, $defaultMark, $providers[$index].DefaultModel)
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

  $model = Read-ModelChoice -Provider $provider

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

$nodeExecutable = Find-NodeExecutable -ProjectDirectory $resolvedProjectDirectory

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
  $providerChoices = @(Get-ProviderChoices -NodeExecutable $nodeExecutable -ServerFile $serverFile)
  $onlineConfiguration = Read-ProviderConfiguration -Providers $providerChoices
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
  $activeConfigurationOutput = @(& $nodeExecutable $serverFile "--print-active-config")
  if ($LASTEXITCODE -ne 0 -or $activeConfigurationOutput.Count -eq 0) {
    throw "后端未能验证本次模型配置。"
  }
  $activeConfiguration = ($activeConfigurationOutput -join "`n") | ConvertFrom-Json
  if ($activeConfiguration.Provider -ne $onlineConfiguration.Id -or
      $activeConfiguration.DefaultModel -cne $onlineConfiguration.Model -or
      -not $activeConfiguration.ModelLocked -or
      -not $activeConfiguration.OnlineEnabled) {
    throw "后端读取到的模型配置与启动向导选择不一致，已拒绝启动。"
  }
  Write-Host ""
  Write-Host ("后端已确认并锁定模型：{0} / {1}" -f $onlineConfiguration.Label, $onlineConfiguration.Model) -ForegroundColor Green
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
