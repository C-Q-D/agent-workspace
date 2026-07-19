<#
.SYNOPSIS
检查 AgentWorkspace 上游归属与修改声明是否和真实 Git 历史一致。

.DESCRIPTION
脚本把派生基线、首个修改提交、日期、仓库地址和 GPL 标识视为稳定契约。
任何历史重写或声明漂移都会失败，避免公开文档与实际来源分离。
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 所有路径从脚本位置解析，调用者可以在任意目录运行。
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$AttributionPath = Join-Path $RepositoryRoot "上游归属与修改说明.md"
$AboutPath = Join-Path $RepositoryRoot "ABOUT.md"
$LicensePath = Join-Path $RepositoryRoot "LICENSE"
$ManifestPath = Join-Path $RepositoryRoot "Cargo.toml"
$AppManifestPath = Join-Path $RepositoryRoot "src-app\Cargo.toml"
$UpstreamBase = "040f71a4f8112db131f2e00a4b80550a3620963d"
$FirstDerivativeCommit = "d5c26d88dd0d4ff7d3a34d0f79ad2f1cb4c0c0e9"
$ExpectedDerivativeDate = "2026-07-15"

function Assert-Contains {
    <# 检查公开文档必须包含的稳定事实。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Label 缺少预期内容：$Expected"
    }
}

foreach ($Path in @($AttributionPath, $AboutPath, $LicensePath, $ManifestPath, $AppManifestPath)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "缺少归属验收文件：$Path"
    }
}

$Attribution = Get-Content -LiteralPath $AttributionPath -Raw
$About = Get-Content -LiteralPath $AboutPath -Raw
$License = Get-Content -LiteralPath $LicensePath -Raw
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw
$AppManifest = Get-Content -LiteralPath $AppManifestPath -Raw

foreach ($Fact in @(
    "AgentWorkspace 是 [Paneflow](https://github.com/ArthurDEV44/paneflow) 的独立修改版本",
    "Arthur Jean",
    "Copyright (C) 2025 Arthur Jean",
    $UpstreamBase,
    $FirstDerivativeCommit,
    $ExpectedDerivativeDate,
    "Copyright (C) 2026 C-Q-D",
    "https://github.com/C-Q-D/agent-workspace",
    "GPL-3.0-or-later",
    "不附带任何明示或默示担保",
    "不是 Paneflow 官方发行版"
)) {
    Assert-Contains -Text $Attribution -Expected $Fact -Label "上游归属与修改说明"
}

Assert-Contains -Text $License -Expected "GNU GENERAL PUBLIC LICENSE" -Label "LICENSE"
Assert-Contains -Text $License -Expected "Version 3, 29 June 2007" -Label "LICENSE"
Assert-Contains -Text $Manifest -Expected 'license = "GPL-3.0-or-later"' -Label "Cargo 工作区"
foreach ($Fact in @(
    "# AgentWorkspace",
    "AgentWorkspace 基于 [Paneflow](https://github.com/ArthurDEV44/paneflow) 修改",
    "不是 Paneflow 官方发行版",
    "上游归属与修改说明.md",
    "GPL-3.0-or-later",
    "https://github.com/C-Q-D/agent-workspace",
    "不附带任何明示或默示担保"
)) {
    Assert-Contains -Text $About -Expected $Fact -Label "ABOUT"
}
if ($About.Contains("# About Paneflow") -or $About.Contains("paneflow.dev")) {
    throw "ABOUT 仍把当前产品表述为 Paneflow 官方项目"
}
Assert-Contains -Text $AppManifest -Expected 'maintainer = "C-Q-D"' -Label "应用包元数据"
Assert-Contains -Text $AppManifest -Expected 'copyright = "2025 Arthur Jean; 2026 C-Q-D"' -Label "应用包元数据"

Push-Location $RepositoryRoot
try {
    & git cat-file -e "$UpstreamBase^{commit}"
    if ($LASTEXITCODE -ne 0) {
        throw "Git 历史缺少上游基线：$UpstreamBase"
    }
    & git merge-base --is-ancestor $UpstreamBase HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "上游基线不是当前 HEAD 的祖先：$UpstreamBase"
    }

    $FirstActual = & git log --ancestry-path "$UpstreamBase..HEAD" --reverse --format=%H |
        Select-Object -First 1
    if ($FirstActual -ne $FirstDerivativeCommit) {
        throw "首个派生提交不一致：期望 $FirstDerivativeCommit，实际 $FirstActual"
    }

    $FirstActualDate = (& git show -s --format=%ad --date=short $FirstDerivativeCommit).Trim()
    if ($FirstActualDate -ne $ExpectedDerivativeDate) {
        throw "首个派生提交日期不一致：期望 $ExpectedDerivativeDate，实际 $FirstActualDate"
    }
}
finally {
    Pop-Location
}

Write-Host "上游归属声明检查通过：基线 $UpstreamBase，首个修改 $FirstDerivativeCommit。"
