<#
.SYNOPSIS
验证 A007 设置稳定性资源门禁的参数、阶段、资源归因与错误退出契约。

.DESCRIPTION
本测试不启动 GUI 或创建真实终端；它解析脚本 AST，并使用真实 Release 二进制执行
SelfCheck。A008 才负责运行 9/16 个真实 PowerShell/ConPTY 的完整性能回归。
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '运行Windows设置稳定性资源门禁.ps1'),
    [string]$BinaryPath = (Join-Path $PSScriptRoot '..\target\release\agent-workspace.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "待测门禁脚本不存在：$ScriptPath"
}
if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
    throw "真实 Release 二进制不存在：$BinaryPath"
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$BinaryPath = (Resolve-Path -LiteralPath $BinaryPath).Path
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source

$Tokens = $null
$Errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$Tokens,
    [ref]$Errors
) | Out-Null
if ($Errors.Count -ne 0) {
    throw "门禁脚本存在 PowerShell 语法错误：$($Errors | ForEach-Object Message | Out-String)"
}

$SelfCheckText = @(
    & $Pwsh -NoProfile -File $ScriptPath -SelfCheck -BinaryPath $BinaryPath 2>&1 |
        ForEach-Object { "$_" }
) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "SelfCheck 失败：$SelfCheckText" }
$Contract = $SelfCheckText | ConvertFrom-Json
if ($Contract.result -ne 'self-check-passed') { throw 'SelfCheck 没有返回通过状态。' }
if (($Contract.terminalCounts -join ',') -ne '9,16') { throw '门禁没有固定覆盖 9/16 窗格。' }
if (($Contract.phases -join ',') -ne
    'cold-start,stable-idle,active-output,focused-file-git') {
    throw '门禁四阶段或顺序不符合 A007 契约。'
}
if (($Contract.resourceGroups -join ',') -ne 'host,shell,cli,helper') {
    throw '宿主、Shell、CLI、辅助进程没有分组报告。'
}
if ($Contract.settingsKeys.Count -ne 10 -or
    @($Contract.settingsKeys | Sort-Object -Unique).Count -ne 10) {
    throw '十项设置磁盘键契约不完整或存在重复。'
}
if ($Contract.sampleIntervalMilliseconds -ne 1000 -or
    $Contract.phaseDurationSeconds -ne 10) {
    throw '默认采样间隔或阶段时长发生未审查漂移。'
}

$Source = Get-Content -Raw -LiteralPath $ScriptPath
foreach ($Required in @(
    'PrintWindow',
    'PostMessage',
    'focusAndExplicitRestoreCompleted',
    'noWriteAfterSecondRound',
    'gitHasUncommittedChange',
    'surfaceIdsStable',
    'powershellPidsStable',
    'threadCount',
    'handleCount',
    'workspaceIdsRestored',
    'powershellPidsRecreatedAcrossRestart',
    'gracefulExitBothRuns',
    'residueCount'
)) {
    if (-not $Source.Contains($Required)) { throw "门禁缺少关键契约：$Required" }
}
if ($Source.Contains('CopyFromScreen')) {
    throw '门禁不得截取桌面或用户正在使用的其他软件。'
}
if ($Source.Contains('Measure-Object TotalProcessorTime -Sum')) {
    throw 'CPU 累计值不得把 TimeSpan 直接交给 Measure-Object 求和。'
}
if (-not $Source.Contains('$ProcessItem = $_') -or
    $Source.Contains("'host' { `$_.Id")) {
    throw '资源分组必须冻结外层 Process，不能让 switch 重绑定自动变量。'
}
foreach ($ForbiddenPropertySum in @(
    'Measure-Object WorkingSet64 -Sum',
    'Measure-Object PrivateMemorySize64 -Sum',
    'Measure-Object HandleCount -Sum'
)) {
    if ($Source.Contains($ForbiddenPropertySum)) {
        throw "空资源组不得使用会返回空管道的属性求和：$ForbiddenPropertySum"
    }
}

$MissingBinary = Join-Path ([IO.Path]::GetTempPath()) 'A007-不存在-agent-workspace.exe'
$FailureText = @(
    & $Pwsh -NoProfile -File $ScriptPath -SelfCheck -BinaryPath $MissingBinary 2>&1 |
        ForEach-Object { "$_" }
) -join "`n"
if ($LASTEXITCODE -eq 0 -or -not $FailureText.Contains('Release 二进制不存在')) {
    throw '缺失二进制没有以明确非零错误退出。'
}

$CadenceText = @(
    & $Pwsh -NoProfile -File $ScriptPath -SelfCheck -BinaryPath $BinaryPath `
        -SampleIntervalMilliseconds 499 2>&1 |
        ForEach-Object { "$_" }
) -join "`n"
if ($LASTEXITCODE -eq 0 -or
    -not $CadenceText.Contains('SampleIntervalMilliseconds') -or
    -not $CadenceText.Contains('500')) {
    throw '高频采样参数没有被门禁拒绝。'
}

Write-Output 'A007 设置稳定性资源门禁脚本契约测试通过'
