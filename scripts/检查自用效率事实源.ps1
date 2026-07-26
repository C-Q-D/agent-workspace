<#
文件职责：检查自用效率优先路线的事实源是否已经完成 E001 切换。
主要内容：以只读方式核对代码仓库入口、当前状态、外层工作台和阶段记录，避免后续 AI
继续把旧 Windows v1 的 A027 或“E001 尚未开始”当作当前开发入口。
重要约束：本脚本不得修改任何文件；旧 v1 计划只做哈希核对，确保 E001 不污染历史计划。
#>

[CmdletBinding()]
param(
    # 允许调用方在其他工作目录运行脚本；默认根据脚本所在目录反推 app 仓库根目录。
    [string]$AppRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 会在参数绑定阶段先计算默认值，此时 $PSScriptRoot 可能尚未可用；
# 因此默认 app 根目录必须在脚本主体里计算，避免只读检查脚本自身成为不可重复红灯。
if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $AppRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

# 该哈希固定 E001 开始时旧 Windows v1 原子计划的字节内容，防止事实源切换时误改历史计划。
$ExpectedLegacyPlanSha256 = 'ABCE332AA6FC9DE1A4168499551BD980A9FCF5677858A1592AB8C8CA9126F23D'

# 脚本只读检查跨越 app 仓库和外层项目工作台；这里集中计算路径，避免每个检查项重复拼路径。
$AgentWorkspaceRoot = (Resolve-Path -LiteralPath (Join-Path $AppRoot '..')).Path
$RepoPlan = Join-Path $AppRoot 'docs/规划/自用效率优先完整代码原子任务方案.md'
$OuterPlan = Join-Path $AgentWorkspaceRoot 'docs/ai-project/自用效率优先完整代码原子任务方案.md'
$LegacyPlan = Join-Path $AgentWorkspaceRoot 'docs/ai-project/v1完整代码原子任务方案.md'

# 每个事实源都有不同职责，因此采用显式必含文本检查；这比模糊搜索“E001”更能防止误判。
$Sources = @(
    [pscustomobject]@{
        Name = 'app/AGENTS.md'
        Path = Join-Path $AppRoot 'AGENTS.md'
        Required = @(
            'docs/规划/自用效率优先完整代码原子任务方案.md',
            'E001 已完成',
            '下一原子为 E002',
            '旧发布计划停在 A027'
        )
        Forbidden = @(
            '当前自用效率路线尚未开始 E001',
            '后续真正开发应从 E001 执行',
            '下一原子为 A027'
        )
    },
    [pscustomobject]@{
        Name = 'app/docs/当前开发状态.md'
        Path = Join-Path $AppRoot 'docs/当前开发状态.md'
        Required = @(
            'E001 已完成',
            '下一原子：E002 复验 A026 代码与测试基线',
            'docs\规划\自用效率优先完整代码原子任务方案.md',
            'E001～E139'
        )
        Forbidden = @(
            'E001 尚未开始',
            '下一原子：E001',
            '下一项为 E001'
        )
    },
    [pscustomobject]@{
        Name = '外层项目工作台'
        Path = Join-Path $AgentWorkspaceRoot 'docs/ai-project/项目工作台.md'
        Required = @(
            'E001 已完成',
            '下一项为 E002',
            '旧发布计划完整保留并暂停在 A027',
            '自用效率优先完整代码原子任务方案.md'
        )
        Forbidden = @(
            '首项 E001 尚未开始',
            '从 E001 执行',
            '下一项为 E001'
        )
    },
    [pscustomobject]@{
        Name = '外层项目阶段记录'
        Path = Join-Path $AgentWorkspaceRoot 'docs/ai-project/项目阶段记录.md'
        Required = @(
            'E001 已完成',
            '下一项 E002',
            '旧 A027 公开入口回归暂停',
            '自用效率优先完整代码原子任务方案.md'
        )
        Forbidden = @(
            '新路线 E001 尚未开始',
            '尚未开始 E001',
            '下一检查点：E001—E003'
        )
    },
    [pscustomobject]@{
        Name = '仓库内原子计划副本'
        Path = $RepoPlan
        Required = @(
            '首个未开始原子：`E002`',
            'E001：已完成',
            '原 Windows 开源 v1 计划',
            'E001～E139'
        )
        Forbidden = @(
            '首个未开始原子：`E001`'
        )
    }
)

$Failures = New-Object System.Collections.Generic.List[string]

foreach ($Source in $Sources) {
    if (-not (Test-Path -LiteralPath $Source.Path)) {
        $Failures.Add("缺少事实源：$($Source.Name) -> $($Source.Path)")
        continue
    }

    $Content = Get-Content -LiteralPath $Source.Path -Raw -Encoding UTF8

    foreach ($Pattern in $Source.Required) {
        if (-not $Content.Contains($Pattern)) {
            $Failures.Add("[$($Source.Name)] 缺少必需事实：$Pattern")
        }
    }

    foreach ($Pattern in $Source.Forbidden) {
        if ($Content.Contains($Pattern)) {
            $Failures.Add("[$($Source.Name)] 仍包含过期事实：$Pattern")
        }
    }
}

if (-not (Test-Path -LiteralPath $OuterPlan)) {
    $Failures.Add("缺少外层计划副本：$OuterPlan")
}

if (-not (Test-Path -LiteralPath $LegacyPlan)) {
    $Failures.Add("缺少旧 v1 计划：$LegacyPlan")
} else {
    $ActualLegacyPlanSha256 = (Get-FileHash -LiteralPath $LegacyPlan -Algorithm SHA256).Hash
    if ($ActualLegacyPlanSha256 -ne $ExpectedLegacyPlanSha256) {
        $Failures.Add("旧 v1 计划哈希变化：期望 $ExpectedLegacyPlanSha256，实际 $ActualLegacyPlanSha256")
    }
}

if ($Failures.Count -gt 0) {
    Write-Host '自用效率事实源检查失败：' -ForegroundColor Red
    foreach ($Failure in $Failures) {
        Write-Host " - $Failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host '自用效率事实源检查通过。' -ForegroundColor Green
Write-Host "仓库计划：$RepoPlan"
Write-Host "外层计划：$OuterPlan"
Write-Host "旧 v1 计划 SHA256：$ExpectedLegacyPlanSha256"
