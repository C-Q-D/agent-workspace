<#
.SYNOPSIS
验证自用效率性能基线脚本的静态契约和输出契约。

.DESCRIPTION
E004 需要先有一个可复用的性能与进程基线入口。该测试不启动桌面应用，
只检查脚本是否明确包含阶段标签、主进程与子进程记账、P95、句柄、
零残留和 1/9/16 工作区参数支持；传入结果 JSON/Markdown 后，还会验证
真实输出是否包含同样字段，防止后续阶段因报告字段缺失而无法比较。
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$ResultJsonPath,
    [string]$MarkdownPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $repositoryRoot 'scripts\运行Windows自用效率基线.ps1'
}

function Assert-True {
    <# 用稳定错误消息表达缺失字段，方便定位脚本契约退化。 #>
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-HasText {
    <# 检查脚本文本是否显式包含某个关键契约词。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Assert-True -Condition ($Content.Contains($Needle)) -Message $Message
}

Assert-True -Condition (Test-Path -LiteralPath $ScriptPath -PathType Leaf) -Message "缺少自用效率基线脚本：$ScriptPath"
$content = Get-Content -LiteralPath $ScriptPath -Raw

foreach ($needle in @(
        '运行Windows活动上下文性能验收.ps1',
        '运行Windows终端矩阵验收.ps1',
        'WorkspaceCount',
        'ValidateSet(1, 9, 16)',
        'SampleSeconds',
        'StageLabel',
        'Grid',
        'Focused',
        'Review',
        'AppWorkingSetPeakMiB',
        'TreeWorkingSetPeakMiB',
        'PowerShellWorkingSetPeakMiB',
        'SwitchP95Milliseconds',
        'AppHandlePeak',
        'ZeroRemainingProcesses',
        'SamplerExcludedFromAppAccounting'
    )) {
    Assert-HasText -Content $content -Needle $needle -Message "自用效率基线脚本缺少契约词：$needle"
}

if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $ResultJsonPath -PathType Leaf) -Message "缺少结果 JSON：$ResultJsonPath"
    $result = Get-Content -LiteralPath (Resolve-Path -LiteralPath $ResultJsonPath) -Raw | ConvertFrom-Json
    Assert-True -Condition ([bool]$result.OverallPassed) -Message '结果 JSON 未通过 OverallPassed。'
    Assert-True -Condition (@($result.Runs).Count -ge 2) -Message '结果 JSON 至少应包含两轮真实运行。'
    foreach ($run in @($result.Runs)) {
        Assert-True -Condition (@($run.Stages).Count -eq 3) -Message '每轮结果必须包含 Grid、Focused、Review 三个阶段。'
        foreach ($stage in @($run.Stages)) {
            foreach ($property in @(
                    'StageLabel',
                    'AppWorkingSetPeakMiB',
                    'TreeWorkingSetPeakMiB',
                    'PowerShellWorkingSetPeakMiB',
                    'AppHandlePeak',
                    'ZeroRemainingProcesses'
                )) {
                Assert-True -Condition ($stage.PSObject.Properties.Name -contains $property) -Message "阶段结果缺少字段：$property"
            }
        }
        foreach ($property in @('SwitchP95Milliseconds', 'SamplerExcludedFromAppAccounting', 'ZeroRemainingProcesses')) {
            Assert-True -Condition ($run.PSObject.Properties.Name -contains $property) -Message "运行结果缺少字段：$property"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($MarkdownPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $MarkdownPath -PathType Leaf) -Message "缺少 Markdown 报告：$MarkdownPath"
    $markdown = Get-Content -LiteralPath (Resolve-Path -LiteralPath $MarkdownPath) -Raw
    foreach ($needle in @('Grid', 'Focused', 'Review', 'Switch P95', '零残留', 'PowerShell')) {
        Assert-HasText -Content $markdown -Needle $needle -Message "Markdown 报告缺少验收信息：$needle"
    }
}

Write-Output 'Windows 自用效率基线脚本契约测试通过。'
