<#
文件职责：用只读方式检查 Windows 终端矩阵验收脚本是否使用 AgentWorkspace 当前运行时事实。
主要内容：固定 IPC 命名管道、用户数据目录和进程名探测不能回退到旧 Paneflow 公开身份。
重要约束：本测试只读取脚本文本，不启动 GUI、不修改用户数据，适合作为验收脚本改动的红灯。
#>

[CmdletBinding()]
param(
    # 默认检查同目录下的真实矩阵验收脚本，允许 CI 或本地诊断显式传入候选脚本。
    [string]$ScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '运行Windows终端矩阵验收.ps1'
}

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "缺少矩阵验收脚本：$ScriptPath"
}

$content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$failures = New-Object System.Collections.Generic.List[string]

# 真实 Release IPC 已迁移到 \\.\pipe\agent-workspace；旧 pipe 会让脚本永远等不到就绪。
if (-not $content.Contains("'agent-workspace'")) {
    $failures.Add('脚本没有显式使用 agent-workspace IPC 命名管道。')
}
if ($content.Contains("NamedPipeClientStream]::new('.', 'paneflow'")) {
    $failures.Add('脚本仍硬编码旧 paneflow IPC 命名管道。')
}

# 当前用户数据根是用户目录下 .agent-workspace；旧 AppData\paneflow 路径会污染错误状态源。
if (-not $content.Contains("'.agent-workspace'")) {
    $failures.Add('脚本没有使用 .agent-workspace 用户数据根。')
}
if ($content.Contains("'ApplicationData'") -or $content.Contains("'paneflow\paneflow.json'") -or $content.Contains("'paneflow\session.json'")) {
    $failures.Add('脚本仍包含旧 AppData Paneflow 数据路径。')
}

# 进程名必须从传入二进制派生；否则 agent-workspace.exe 会绕过启动前残留检查。
if (-not $content.Contains('$appProcessName')) {
    $failures.Add('脚本没有从 BinaryPath 派生应用进程名。')
}
if ($content.Contains('Get-Process paneflow')) {
    $failures.Add('脚本仍固定检查 paneflow 进程名。')
}

if ($failures.Count -gt 0) {
    Write-Host 'Windows 终端矩阵验收脚本检查失败：' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Windows 终端矩阵验收脚本检查通过。' -ForegroundColor Green
