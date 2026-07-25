<#
.SYNOPSIS
验证十项设置组合验收脚本的帮助、自检、错误退出和静态安全契约。

.DESCRIPTION
本测试不启动 GUI。它使用现有 Release 二进制执行自检，并以独立 pwsh 子进程确认错误
路径返回非零退出码，防止调用方把失败误记为通过。
#>
[CmdletBinding()]
param(
    [string]$BinaryPath = (Join-Path $PSScriptRoot '..\target\release\agent-workspace.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot '运行Windows十项设置组合验收.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "待测试脚本不存在：$ScriptPath"
}
if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
    throw "Release 二进制不存在：$BinaryPath"
}

$Help = Get-Help -Full $ScriptPath | Out-String
foreach ($Marker in @('十项稳定设置', 'SelfCheck', 'TimeoutSeconds', 'KeepFixture')) {
    if (-not $Help.Contains($Marker)) { throw "帮助缺少标记：$Marker" }
}

$SelfCheckOutput = @(
    & $ScriptPath -SelfCheck -BinaryPath $BinaryPath -OutputDirectory $env:TEMP 2>&1 |
        ForEach-Object { "$_" }
)
if ($LASTEXITCODE -notin @(0, $null)) {
    throw "自检意外失败：$($SelfCheckOutput -join ' ')"
}
$SelfCheck = ($SelfCheckOutput -join "`n") | ConvertFrom-Json
if ($SelfCheck.result -ne 'self-check-passed') { throw '自检结果不是 self-check-passed。' }
if (@($SelfCheck.expectedKeys).Count -ne 10) { throw '自检没有报告十个设置键。' }
if ($SelfCheck.interactionRule -notlike '*设置页*') { throw '自检缺少真实设置页交互边界。' }

$Pwsh = (Get-Process -Id $PID).Path
$MissingBinary = Join-Path $env:TEMP "不存在-$([Guid]::NewGuid()).exe"
$ErrorOutput = @(
    & $Pwsh -NoProfile -File $ScriptPath -SelfCheck -BinaryPath $MissingBinary 2>&1 |
        ForEach-Object { "$_" }
)
if ($LASTEXITCODE -eq 0) { throw '缺失二进制错误路径错误返回了零退出码。' }
if (-not (($ErrorOutput -join "`n").Contains('Release 二进制不存在'))) {
    throw "错误输出没有指出二进制缺失：$($ErrorOutput -join ' ')"
}

$Source = Get-Content -Raw -LiteralPath $ScriptPath
foreach ($Key in @(
    'theme_mode',
    'theme',
    'font_family',
    'font_size',
    'default_shell',
    'default_reference_format',
    'workspace_grid_density',
    'git_auto_init',
    'claude_code_command',
    'codex_command'
)) {
    if (-not $Source.Contains("'$Key'")) { throw "脚本静态契约缺少键：$Key" }
}
if (-not $Source.Contains('Wait-SettingsRound')) { throw '脚本缺少只观察设置页写入的轮次门禁。' }
if ($Source -match 'Start-Process[^\r\n]*Start-Sleep') {
    throw '脚本不得把 Start-Sleep 当作新窗口进程。'
}

Write-Output 'Windows 十项设置组合验收脚本契约测试通过'
