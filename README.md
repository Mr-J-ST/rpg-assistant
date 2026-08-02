# 跑团助手原型

一个只在本机运行、只提供回复建议的跑团辅助程序。它不会读取或控制 QQ，也不会替你发送消息；当前原型先验证场景资料管理、关键词识别和长回复生成链路。

## 已实现

- 创建、复制、切换和删除多个场景。
- 每个场景分别保存规则书摘要、角色设定、人物关系、能力、底线、语言风格和禁用倾向。
- 自动识别角色名、别名和自定义关键词，并显示命中次数及上下文高亮。
- 使用 OpenAI Responses API 生成中等、长篇或超长回复。
- 未配置 API Key 时提供本地演示生成，方便先检查全部界面和流程。
- API Key 只从服务器环境变量读取，不写入网页或数据文件。

## 启动

双击 `start-assistant.cmd`，或在 PowerShell 中运行：

```powershell
cd D:\Codex\Local\rpg-assistant
.\start-assistant.cmd
```

程序默认打开 <http://127.0.0.1:4317>。按 `Ctrl+C` 停止。

## 启用在线模型

先在同一个 PowerShell 窗口中临时设置 API Key，再启动：

```powershell
$env:OPENAI_API_KEY = "你的 OpenAI API Key"
.\start-assistant.cmd
```

关闭该 PowerShell 窗口后，临时环境变量会失效。不要把密钥填写进源码、`scenes.json` 或截图。

可选：用环境变量改变服务端默认模型：

```powershell
$env:OPENAI_MODEL = "gpt-5.6-terra"
```

界面中也可以为单次生成选择 `gpt-5.6-sol`、`gpt-5.6-terra` 或 `gpt-5.6-luna`。

## 数据位置

场景资料保存在：

```text
D:\Codex\Local\rpg-assistant\data\scenes.json
```

保存时使用临时文件替换，减少意外中断造成 JSON 损坏的风险。当前版本不会自动上传整个资料库；在线生成时，只会把当前选择场景及本次粘贴的聊天上下文发送给模型，并设置 `store: false`。

## 自测

```powershell
.\start-assistant.cmd --self-test
```

自测覆盖本地存储、场景创建、关键词识别、提示构建和无 Key 演示生成。

## 原型边界

- 尚未接入 QQ 窗口捕获或 OCR；聊天内容需要手动粘贴。
- 不包含自动发送能力。
- 规则书建议录入你实际需要的规则摘要和角色边界，不建议无筛选地复制整本书。
