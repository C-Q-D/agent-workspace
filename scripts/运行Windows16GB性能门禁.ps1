<#
.SYNOPSIS
运行 AgentWorkspace 面向 16GB Windows 用户的性能回归门禁。

.DESCRIPTION
脚本在独立 PowerShell 进程中依次调用真实终端矩阵验收，汇总 1、9、16 个
PowerShell/ConPTY 的容量、切换、重绘、进程与资源数据，并可追加 9 终端
30 分钟长稳。任何门禁失败都会保留原始证据并以非零状态退出。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(10, 300)]
    [int]$CapacityDurationSeconds = 30,

    [switch]$IncludeLongStability,

    [ValidateRange(600, 3600)]
    [int]$StabilityDurationSeconds = 1800,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\P1.5性能数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$matrixScript = (Resolve-Path (Join-Path $PSScriptRoot '运行Windows终端矩阵验收.ps1')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryPath = Join-Path $outputRoot "16GB性能门禁-$timestamp.json"
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

function Invoke-MatrixRun {
    <# 在独立进程运行一次真实矩阵，避免 Win32 Add-Type 在多轮之间冲突。 #>
    param(
        [Parameter(Mandatory = $true)][int]$TerminalCount,
        [Parameter(Mandatory = $true)][int]$DurationSeconds,
        [Parameter(Mandatory = $true)][int]$OutputIntervalMilliseconds,
        [Parameter(Mandatory = $true)][int]$SwitchCount,
        [Parameter(Mandatory = $true)][string]$Variant
    )

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $matrixScript,
        '-BinaryPath', $binary,
        '-TerminalCount', $TerminalCount,
        '-DurationSeconds', $DurationSeconds,
        '-OutputIntervalMilliseconds', $OutputIntervalMilliseconds,
        '-SwitchCount', $SwitchCount,
        '-Variant', $Variant,
        '-OutputDirectory', $outputRoot
    )
    & pwsh @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Variant 的 $TerminalCount 终端真实矩阵执行失败，退出码 $LASTEXITCODE。" }

    $prefix = '{0}-{1:D2}终端-' -f $Variant, $TerminalCount
    $directory = Get-ChildItem -LiteralPath $outputRoot -Directory |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $directory) { throw "找不到 $Variant 的 $TerminalCount 终端结果目录。" }
    $resultPath = Join-Path $directory.FullName '运行结果.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "结果缺少运行结果.json：$($directory.FullName)" }
    return Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
}

function Test-CommonRunGate {
    <# 判断容量与长稳都必须满足的进程、输出、切换和清理条件。 #>
    param([Parameter(Mandatory = $true)][object]$Result)

    $names = @($Result.ProcessTreeSnapshot | ForEach-Object { [string]$_.Name })
    $agentProcesses = @($names | Where-Object { $_ -match '^(codex|claude|node|bun|deno)$' })
    $focused = $Result.FirstSurfaceRenderDelta
    $hidden = $Result.LastSurfaceRenderDelta
    $focusedRenderPassed = ([uint64]$focused.change_batches -gt 0) -and
        ([uint64]$focused.immediate_redraw_requests -gt 0)
    $hiddenRenderPassed = if ([int]$Result.TerminalCount -le 1) {
        $true
    }
    else {
        ([uint64]$hidden.change_batches -gt 0) -and
        ([uint64]$hidden.hidden_suppressed_redraw_requests -gt 0) -and
        ([uint64]$hidden.immediate_redraw_requests -eq 0)
    }

    return [ordered]@{
        CpuWithinOnePercent = ([double]$Result.AppCpuAveragePercent -le 1.0)
        WorkingSetWithin256MiB = ([double]$Result.AppWorkingSetPeakMiB -le 256.0)
        SwitchP95Within100Ms = ([double]$Result.SwitchP95Milliseconds -le 100.0)
        ProcessTreeStable = [bool]$Result.ProcessTreeStableDuringSample
        ProcessIdsStable = [bool]$Result.ProcessIdsStableDuringSample
        SwitchProcessIdsStable = [bool]$Result.SwitchProcessIdsStable
        AllFinalMarkersObserved = [bool]$Result.AllFinalMarkersObserved
        FocusedRenderActive = $focusedRenderPassed
        HiddenRenderSuppressed = $hiddenRenderPassed
        NoAgentsSpecificProcess = ($agentProcesses.Count -eq 0)
        ZeroRemainingProcesses = (@($Result.RemainingProcessIds).Count -eq 0)
    }
}

function Test-AllTrue {
    <# 检查有序门禁对象中的全部布尔值。 #>
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Checks)
    return @($Checks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
}

$capacityResults = @()
foreach ($count in @(1, 9, 16)) {
    $capacityResults += Invoke-MatrixRun `
        -TerminalCount $count `
        -DurationSeconds $CapacityDurationSeconds `
        -OutputIntervalMilliseconds 250 `
        -SwitchCount 32 `
        -Variant 'p15-capacity'
}

$capacityByCount = @{}
foreach ($result in $capacityResults) { $capacityByCount[[int]$result.TerminalCount] = $result }
$one = $capacityByCount[1]
$nine = $capacityByCount[9]
$sixteen = $capacityByCount[16]
$marginalOneToNine = ([double]$nine.AppWorkingSetPeakMiB - [double]$one.AppWorkingSetPeakMiB) / 8.0
$marginalNineToSixteen = ([double]$sixteen.AppWorkingSetPeakMiB - [double]$nine.AppWorkingSetPeakMiB) / 7.0

$capacityChecks = [ordered]@{
    OneTerminal = Test-CommonRunGate -Result $one
    NineTerminals = Test-CommonRunGate -Result $nine
    SixteenTerminals = Test-CommonRunGate -Result $sixteen
    MarginalOneToNineMiB = [Math]::Round($marginalOneToNine, 3)
    MarginalNineToSixteenMiB = [Math]::Round($marginalNineToSixteen, 3)
    MarginalOneToNineWithin8MiB = ($marginalOneToNine -le 8.0)
    MarginalNineToSixteenWithin8MiB = ($marginalNineToSixteen -le 8.0)
    SixteenWorkingSetRegressionWithin16MiB = ([double]$sixteen.AppWorkingSetPeakMiB -le 247.289)
    MaxSwitchRegressionWithin25Ms = ((@($capacityResults.SwitchP95Milliseconds | Measure-Object -Maximum).Maximum) -le 88.328)
}
$capacityRunsPassed = (Test-AllTrue -Checks $capacityChecks.OneTerminal) -and
    (Test-AllTrue -Checks $capacityChecks.NineTerminals) -and
    (Test-AllTrue -Checks $capacityChecks.SixteenTerminals)
$capacityPassed = $capacityRunsPassed -and
    $capacityChecks.MarginalOneToNineWithin8MiB -and
    $capacityChecks.MarginalNineToSixteenWithin8MiB -and
    $capacityChecks.SixteenWorkingSetRegressionWithin16MiB -and
    $capacityChecks.MaxSwitchRegressionWithin25Ms

$stabilityResult = $null
$stabilityChecks = $null
$stabilityPassed = $true
if ($IncludeLongStability) {
    $stabilityResult = Invoke-MatrixRun `
        -TerminalCount 9 `
        -DurationSeconds $StabilityDurationSeconds `
        -OutputIntervalMilliseconds 250 `
        -SwitchCount 64 `
        -Variant 'p15-stability'
    $rows = @(Import-Csv -LiteralPath ([string]$stabilityResult.SamplesCsv))
    if ($rows.Count -lt 600) { throw "长稳采样不足 600 条，实际为 $($rows.Count)。" }
    $tail = @($rows | Select-Object -Last 600)
    $previousWindow = @($tail | Select-Object -First 300)
    $finalWindow = @($tail | Select-Object -Last 300)
    $previousPrivate = [double](($previousWindow | ForEach-Object { [double]$_.AppPrivateMiB } | Measure-Object -Average).Average)
    $finalPrivate = [double](($finalWindow | ForEach-Object { [double]$_.AppPrivateMiB } | Measure-Object -Average).Average)
    $privateTailGrowth = $finalPrivate - $previousPrivate
    $commonStability = Test-CommonRunGate -Result $stabilityResult
    $stabilityChecks = [ordered]@{
        Common = $commonStability
        SampleCount = $rows.Count
        PreviousFiveMinutePrivateAverageMiB = [Math]::Round($previousPrivate, 3)
        FinalFiveMinutePrivateAverageMiB = [Math]::Round($finalPrivate, 3)
        PrivateTailGrowthMiB = [Math]::Round($privateTailGrowth, 3)
        PrivateTailGrowthWithin8MiB = ($privateTailGrowth -le 8.0)
    }
    $stabilityPassed = (Test-AllTrue -Checks $commonStability) -and $stabilityChecks.PrivateTailGrowthWithin8MiB
}

$summary = [ordered]@{
    RunId = "16GB性能门禁-$timestamp"
    Commit = (git -C $repoRoot rev-parse HEAD).Trim()
    BinaryPath = $binary
    BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    CapacityDurationSeconds = $CapacityDurationSeconds
    StabilityIncluded = [bool]$IncludeLongStability
    StabilityDurationSeconds = if ($IncludeLongStability) { $StabilityDurationSeconds } else { 0 }
    CapacityResults = $capacityResults
    CapacityChecks = $capacityChecks
    CapacityPassed = $capacityPassed
    StabilityResult = $stabilityResult
    StabilityChecks = $stabilityChecks
    StabilityPassed = $stabilityPassed
    OverallPassed = ($capacityPassed -and $stabilityPassed)
}
$summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding utf8
[pscustomobject]$summary

if (-not $summary.OverallPassed) {
    throw "16GB 性能门禁失败，证据已保留：$summaryPath"
}
