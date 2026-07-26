<#
.SYNOPSIS
运行 AgentWorkspace 自用效率阶段的可复用性能与进程基线。

.DESCRIPTION
E004 的目标不是新增产品功能，而是建立后续自用效率功能都能复用的真实验收入口。
脚本串联已有真实窗口验收脚本：活动上下文脚本负责 Grid、Focused、Review 三阶段
资源快照和窗口生命周期；终端矩阵脚本负责真实 PowerShell/ConPTY 负载、切换 P95、
完整进程树和零残留。汇总层只做编排、字段标准化和 Markdown/JSON 报告输出，
不复制应用启动、IPC、窗口点击或关闭清理逻辑。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateSet(1, 9, 16)]
    [int]$WorkspaceCount = 9,

    [ValidateRange(3, 30)]
    [int]$SampleSeconds = 6,

    [ValidateRange(2, 5)]
    [int]$Runs = 2,

    [ValidateRange(1, 200)]
    [int]$SwitchCount = 24,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\E004自用效率性能数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$activityScript = (Resolve-Path (Join-Path $PSScriptRoot '运行Windows活动上下文性能验收.ps1')).Path
$matrixScript = (Resolve-Path (Join-Path $PSScriptRoot '运行Windows终端矩阵验收.ps1')).Path
$summaryPath = Join-Path $outputRoot "自用效率基线-$timestamp.json"
$markdownPath = Join-Path $outputRoot "自用效率基线-$timestamp.md"
$matrixDurationSeconds = [Math]::Max(10, $SampleSeconds)
$childShell = (Get-Command pwsh -ErrorAction Stop).Source

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

function Invoke-ChildPowerShellScript {
    <# 使用独立 PowerShell 7 进程运行既有验收脚本，保证 Parent 进程树枚举与 E002 门禁一致。 #>
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$Name)

    & $childShell @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 执行失败，退出码 $LASTEXITCODE。"
    }
}

function Get-LatestActivityResult {
    <# 找到活动上下文脚本刚生成的 JSON 结果。 #>
    $directory = Get-ChildItem -LiteralPath $outputRoot -Directory |
        Where-Object { $_.Name.StartsWith('真实上下文-', [StringComparison]::Ordinal) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $directory) { throw '找不到活动上下文结果目录。' }
    $resultPath = Join-Path $directory.FullName '运行结果.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "活动上下文结果缺少运行结果.json：$($directory.FullName)" }
    return [pscustomobject]@{
        Path = $resultPath
        Result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    }
}

function Get-LatestMatrixResult {
    <# 找到终端矩阵脚本刚生成的 JSON 结果。 #>
    param([Parameter(Mandatory = $true)][string]$Variant)

    $prefix = '{0}-{1:D2}终端-' -f $Variant, $WorkspaceCount
    $directory = Get-ChildItem -LiteralPath $outputRoot -Directory |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $directory) { throw "找不到矩阵结果目录：$prefix" }
    $resultPath = Join-Path $directory.FullName '运行结果.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "矩阵结果缺少运行结果.json：$($directory.FullName)" }
    return [pscustomobject]@{
        Path = $resultPath
        Result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    }
}

function Convert-StageResult {
    <# 将活动上下文脚本的阶段资源采样标准化，后续原子只依赖这些稳定字段。 #>
    param(
        [Parameter(Mandatory = $true)][string]$StageLabel,
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Resources,
        [Parameter(Mandatory = $true)][object]$ActivityResult
    )

    return [ordered]@{
        StageLabel = $StageLabel
        Surface = [string]$Context.surface
        WorkspaceId = if ($Context.PSObject.Properties.Name -contains 'workspace_id') { [uint64]$Context.workspace_id } else { 0 }
        ActiveContexts = [int]$Context.active_contexts
        GitWatchers = [int]$Context.git_watchers
        FilesWatchers = [int]$Context.files_watchers
        ReviewHosts = [int]$Context.review_hosts
        AppCpuAveragePercent = [double]$Resources.CpuAveragePercent
        AppWorkingSetPeakMiB = [double]$Resources.WorkingSetPeakMiB
        AppPrivatePeakMiB = [double]$Resources.PrivatePeakMiB
        AppHandlePeak = [int]$Resources.HandlePeak
        TreeProcessCountPeak = [int]$Resources.TreeProcessCountPeak
        TreeWorkingSetPeakMiB = [double]$Resources.TreeWorkingSetPeakMiB
        TreePrivatePeakMiB = [double]$Resources.TreePrivatePeakMiB
        PowerShellCountPeak = [int]$Resources.PowerShellCountPeak
        PowerShellWorkingSetPeakMiB = [double]$Resources.PowerShellWorkingSetPeakMiB
        PowerShellPrivatePeakMiB = [double]$Resources.PowerShellPrivatePeakMiB
        ConhostCountPeak = [int]$Resources.ConhostCountPeak
        ConhostWorkingSetPeakMiB = [double]$Resources.ConhostWorkingSetPeakMiB
        ConhostPrivatePeakMiB = [double]$Resources.ConhostPrivatePeakMiB
        ZeroRemainingProcesses = (@($ActivityResult.RemainingProcessIds).Count -eq 0)
    }
}

function Test-MatrixRun {
    <# 对矩阵脚本结果施加轻量门禁，确保基线不是只生成文件而忽略明显退化。 #>
    param([Parameter(Mandatory = $true)][object]$MatrixResult)

    return [ordered]@{
        AppCpuWithinOnePercent = ([double]$MatrixResult.AppCpuAveragePercent -le 1.0)
        AppWorkingSetWithin256MiB = ([double]$MatrixResult.AppWorkingSetPeakMiB -le 256.0)
        SwitchP95Within100Ms = ([double]$MatrixResult.SwitchP95Milliseconds -le 100.0)
        PowerShellCountStable = ([int]$MatrixResult.PowerShellCountPeak -eq ($WorkspaceCount * 2))
        ProcessIdsStableDuringSample = [bool]$MatrixResult.ProcessIdsStableDuringSample
        SwitchProcessIdsStable = [bool]$MatrixResult.SwitchProcessIdsStable
        AllFinalMarkersObserved = [bool]$MatrixResult.AllFinalMarkersObserved
        ZeroRemainingProcesses = (@($MatrixResult.RemainingProcessIds).Count -eq 0)
    }
}

function Test-AllTrue {
    <# 统一检查有序门禁结果中的布尔字段。 #>
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Checks)
    return @($Checks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
}

function New-MarkdownReport {
    <# 生成中文 Markdown 报告，便于直接提交到验收目录和人工复核。 #>
    param([Parameter(Mandatory = $true)][object]$Summary)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# E004 自用效率性能与进程基线报告')
    $lines.Add('')
    $lines.Add('## 结论')
    $lines.Add('')
    $lines.Add(('- OverallPassed：`{0}`' -f $Summary.OverallPassed))
    $lines.Add(('- 工作区数量：`{0}`' -f $Summary.WorkspaceCount))
    $lines.Add(('- 活动上下文采样秒数：`{0}`' -f $Summary.SampleSeconds))
    $lines.Add(('- 矩阵负载秒数：`{0}`' -f $Summary.MatrixDurationSeconds))
    $lines.Add(('- 采样器排除在应用记账外：`{0}`' -f $Summary.SamplerExcludedFromAppAccounting))
    $lines.Add('')
    $lines.Add('## 两轮结果')
    $lines.Add('')
    $lines.Add('| 轮次 | 通过 | Switch P95(ms) | App WS峰值(MiB) | Tree WS峰值(MiB) | PowerShell WS峰值(MiB) | 零残留 |')
    $lines.Add('|---|---:|---:|---:|---:|---:|---:|')
    foreach ($run in @($Summary.Runs)) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f
                $run.RunNumber,
                $run.Passed,
                $run.SwitchP95Milliseconds,
                $run.AppWorkingSetPeakMiB,
                $run.TreeWorkingSetPeakMiB,
                $run.PowerShellWorkingSetPeakMiB,
                $run.ZeroRemainingProcesses))
    }
    $lines.Add('')
    $lines.Add('## Grid / Focused / Review 阶段')
    $lines.Add('')
    foreach ($run in @($Summary.Runs)) {
        $lines.Add(('### 第 {0} 轮' -f $run.RunNumber))
        $lines.Add('')
        $lines.Add('| 阶段 | surface | active_contexts | git_watchers | files_watchers | review_hosts | App WS(MiB) | Tree WS(MiB) | PowerShell WS(MiB) | App句柄峰值 | 零残留 |')
        $lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
        foreach ($stage in @($run.Stages)) {
            $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |' -f
                    $stage.StageLabel,
                    $stage.Surface,
                    $stage.ActiveContexts,
                    $stage.GitWatchers,
                    $stage.FilesWatchers,
                    $stage.ReviewHosts,
                    $stage.AppWorkingSetPeakMiB,
                    $stage.TreeWorkingSetPeakMiB,
                    $stage.PowerShellWorkingSetPeakMiB,
                    $stage.AppHandlePeak,
                    $stage.ZeroRemainingProcesses))
        }
        $lines.Add('')
    }
    $lines.Add('## 证据路径')
    $lines.Add('')
    foreach ($run in @($Summary.Runs)) {
        $lines.Add(('- 第 {0} 轮活动上下文 JSON：`{1}`' -f $run.RunNumber, $run.ActivityResultPath))
        $lines.Add(('- 第 {0} 轮矩阵 JSON：`{1}`' -f $run.RunNumber, $run.MatrixResultPath))
    }
    $lines.Add(('- 汇总 JSON：`{0}`' -f $Summary.SummaryPath))
    $lines.Add('')
    $lines.Add('## 解释')
    $lines.Add('')
    $lines.Add('- Grid 阶段必须保持零活动上下文，避免总览模式加载右侧文件/Git 资源。')
    $lines.Add('- Focused 阶段必须只有一个活动上下文，证明放大窗口后才加载当前 workspaceRoot。')
    $lines.Add('- Review 阶段必须只有一个专用审查资源，证明审查能力没有在所有窗格上常驻。')
    $lines.Add('- Switch P95 来自真实终端矩阵脚本；进程树统计只从 AgentWorkspace 根进程向下追踪，因此外层采样 PowerShell 不计入应用开销。')
    return ($lines -join [Environment]::NewLine)
}

$runResults = @()
for ($runIndex = 1; $runIndex -le $Runs; $runIndex++) {
    $variant = 'e004-r{0}' -f $runIndex

    Invoke-ChildPowerShellScript -Name "活动上下文第 $runIndex 轮" -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $activityScript,
        '-BinaryPath',
        $binary,
        '-WorkspaceCount',
        $WorkspaceCount,
        '-SampleSeconds',
        $SampleSeconds,
        '-OutputDirectory',
        $outputRoot
    )
    $activity = Get-LatestActivityResult

    Invoke-ChildPowerShellScript -Name "终端矩阵第 $runIndex 轮" -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $matrixScript,
        '-BinaryPath',
        $binary,
        '-TerminalCount',
        $WorkspaceCount,
        '-DurationSeconds',
        $matrixDurationSeconds,
        '-OutputIntervalMilliseconds',
        250,
        '-SwitchCount',
        $SwitchCount,
        '-Variant',
        $variant,
        '-OutputDirectory',
        $outputRoot
    )
    $matrix = Get-LatestMatrixResult -Variant $variant

    $stages = @(
        Convert-StageResult -StageLabel 'Grid' -Context $activity.Result.Grid -Resources $activity.Result.GridResources -ActivityResult $activity.Result
        Convert-StageResult -StageLabel 'Focused' -Context $activity.Result.FocusedA -Resources $activity.Result.FocusedResources -ActivityResult $activity.Result
        Convert-StageResult -StageLabel 'Review' -Context $activity.Result.Review -Resources $activity.Result.ReviewResources -ActivityResult $activity.Result
    )
    $matrixChecks = Test-MatrixRun -MatrixResult $matrix.Result
    $activityPassed = [bool]$activity.Result.Passed
    $matrixPassed = Test-AllTrue -Checks $matrixChecks
    $zeroRemaining = (@($activity.Result.RemainingProcessIds).Count -eq 0) -and (@($matrix.Result.RemainingProcessIds).Count -eq 0)

    $runResults += [ordered]@{
        RunNumber = $runIndex
        ActivityResultPath = $activity.Path
        MatrixResultPath = $matrix.Path
        Stages = $stages
        MatrixChecks = $matrixChecks
        ActivityPassed = $activityPassed
        MatrixPassed = $matrixPassed
        SwitchP95Milliseconds = [double]$matrix.Result.SwitchP95Milliseconds
        AppWorkingSetPeakMiB = [double]$matrix.Result.AppWorkingSetPeakMiB
        TreeWorkingSetPeakMiB = [double]$matrix.Result.TreeWorkingSetPeakMiB
        PowerShellWorkingSetPeakMiB = [double]$matrix.Result.PowerShellWorkingSetPeakMiB
        AppHandlePeak = [int](($stages | ForEach-Object { [int]$_.AppHandlePeak } | Measure-Object -Maximum).Maximum)
        ZeroRemainingProcesses = $zeroRemaining
        SamplerExcludedFromAppAccounting = $true
        Passed = ($activityPassed -and $matrixPassed -and $zeroRemaining)
    }
}

$summary = [ordered]@{
    RunId = "自用效率基线-$timestamp"
    Commit = (git -C $repositoryRoot rev-parse HEAD).Trim()
    BinaryPath = $binary
    BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    WorkspaceCount = $WorkspaceCount
    SupportedWorkspaceCounts = @(1, 9, 16)
    SampleSeconds = $SampleSeconds
    MatrixDurationSeconds = $matrixDurationSeconds
    RunsRequested = $Runs
    Runs = $runResults
    SamplerExcludedFromAppAccounting = $true
    SummaryPath = $summaryPath
    MarkdownPath = $markdownPath
    OverallPassed = (@($runResults | Where-Object { -not [bool]$_.Passed }).Count -eq 0)
}

$summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding utf8
New-MarkdownReport -Summary ([pscustomobject]$summary) | Set-Content -LiteralPath $markdownPath -Encoding utf8
[pscustomobject]$summary

if (-not $summary.OverallPassed) {
    throw "自用效率性能基线失败，证据已保留：$summaryPath"
}
