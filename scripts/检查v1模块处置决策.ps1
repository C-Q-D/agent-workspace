# 只读验证 A014 的 v1 模块处置决策具有完整分类、责任原子和 31 个交付单元追溯。
# 本脚本不决定产品策略；Telemetry、包型和版本号的人工门仍由计划中的 A109+ 执行。
[CmdletBinding()]
param(
    # 默认检查仓库内正式 ADR；可传入其他相对或绝对路径用于审查。
    [string]$DecisionPath = "docs/架构/A014v1模块处置决策.md",
    # 可选 JSON 输出路径；未提供时只写标准输出。
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ResolvedDecision = [IO.Path]::GetFullPath($DecisionPath, $RepositoryRoot)
if (-not (Test-Path -LiteralPath $ResolvedDecision -PathType Leaf)) {
    throw "v1 模块处置决策不存在：$ResolvedDecision"
}

$Text = Get-Content -Raw -LiteralPath $ResolvedDecision
$AllowedClasses = @(
    "v1核心保留",
    "默认不编译/不公开但暂留源码",
    "删除公开面后保留内部兼容",
    "完全删除"
)

# 模块表使用稳定 M-xx 行作为机器可读边界；每行必须有且只有一种分类和责任原子。
$ModuleRows = [regex]::Matches($Text, '(?m)^\| M-\d{2} \|.*\|$') |
    ForEach-Object { $_.Value }
if ($ModuleRows.Count -lt 15) {
    throw "模块处置行不足：实际 $($ModuleRows.Count)，至少需要 15"
}

$ModuleResults = foreach ($Row in $ModuleRows) {
    $Id = [regex]::Match($Row, 'M-\d{2}').Value
    $MatchedClasses = @($AllowedClasses | Where-Object { $Row.Contains("| $_ |") })
    if ($MatchedClasses.Count -ne 1) {
        throw "模块 $Id 必须且只能命中一种处置分类"
    }
    $Atoms = @([regex]::Matches($Row, 'A\d{3}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($Atoms.Count -eq 0) {
        throw "模块 $Id 没有责任原子"
    }
    [ordered]@{
        id = $Id
        classification = $MatchedClasses[0]
        atoms = $Atoms
    }
}

# 31 个交付单元由 NOW-01 加 V1-01～V1-30 组成；每个必须出现在追溯表的独立行。
$ExpectedUnits = @("NOW-01") + (1..30 | ForEach-Object { "V1-{0:d2}" -f $_ })
$UnitResults = foreach ($Unit in $ExpectedUnits) {
    $Pattern = "(?m)^\| " + [regex]::Escape($Unit) + " \|.*\|$"
    $Matches = [regex]::Matches($Text, $Pattern)
    if ($Matches.Count -ne 1) {
        throw "交付单元 $Unit 必须在追溯表中恰好出现一次，实际 $($Matches.Count)"
    }
    $Atoms = @([regex]::Matches($Matches[0].Value, 'A\d{3}') | ForEach-Object { $_.Value })
    if ($Atoms.Count -eq 0) {
        throw "交付单元 $Unit 没有对应原子"
    }
    [ordered]@{
        id = $Unit
        atoms = $Atoms
    }
}

# A010～A013 是 A014 的四个输入证据，链接缺失时决策不成立。
$EvidencePaths = @(
    "docs/架构/A010公开入口与产品面清单.md",
    "docs/架构/A011默认构建依赖图.md",
    "docs/架构/A012展示状态与会话所有权审查.md",
    "docs/性能/A013后台资源生命周期审查.md"
)
foreach ($Path in $EvidencePaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $Path) -PathType Leaf)) {
        throw "A014 输入证据缺失：$Path"
    }
}

if ($Text.Contains("以后再看") -or $Text.Contains("无责任原子")) {
    throw "决策文档包含未分配责任的模糊措辞"
}

$Report = [ordered]@{
    schemaVersion = 1
    repositoryRoot = $RepositoryRoot
    decisionPath = $ResolvedDecision
    moduleCount = $ModuleResults.Count
    deliveryUnitCount = $UnitResults.Count
    evidenceCount = $EvidencePaths.Count
    result = "passed"
    modules = @($ModuleResults)
    deliveryUnits = @($UnitResults)
}
$Json = $Report | ConvertTo-Json -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $ResolvedOutput = [IO.Path]::GetFullPath($OutputPath, $RepositoryRoot)
    $Parent = Split-Path -Parent $ResolvedOutput
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    [IO.File]::WriteAllText($ResolvedOutput, "$Json`n", [Text.UTF8Encoding]::new($false))
}

Write-Output $Json
Write-Output "A014 v1 模块处置决策检查通过：$($ModuleResults.Count) 个模块，$($UnitResults.Count) 个交付单元"
