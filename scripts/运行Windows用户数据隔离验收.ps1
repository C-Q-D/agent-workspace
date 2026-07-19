<#
.SYNOPSIS
在 Windows 上重复执行 AgentWorkspace 用户数据隔离验收。

.DESCRIPTION
脚本分别以调试和发布构建运行真实文件系统测试，并将命令输出与机器可读结果
写入验收数据目录。测试只操作 Rust 临时目录，不会读写当前用户的真实数据目录。
#>
[CmdletBinding()]
param(
    # 验收证据输出目录；默认放在仓库内，便于随提交保留结果。
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 从脚本位置解析仓库根目录，避免调用者当前目录影响测试与输出位置。
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot "docs\验收\用户数据隔离数据"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ResultDirectory = Join-Path $OutputRoot "真实隔离-$Timestamp"
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null

function Invoke-IsolationTest {
    <#
    .SYNOPSIS
    运行指定构建配置的真实文件系统隔离测试并保留完整日志。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile,
        [Parameter(Mandatory = $true)]
        [string[]]$CargoArguments
    )

    # 使用可被仓库追踪的文本扩展名，确保 JSON 引用的原始日志随提交保留。
    $LogPath = Join-Path $ResultDirectory "$Profile.txt"
    Push-Location $RepositoryRoot
    try {
        # Tee-Object 的成功输出若直接返回，会混入函数结果并破坏 JSON 结构；
        # Out-Host 仅负责实时展示，函数只返回下方的有序结果对象。
        & cargo @CargoArguments 2>&1 | Tee-Object -FilePath $LogPath | Out-Host
        $ExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($ExitCode -ne 0) {
        throw "$Profile 用户数据隔离测试失败，退出码：$ExitCode。请先分析日志：$LogPath"
    }

    # Cargo 输出通常以一个额外空行结束；统一为恰好一个换行，确保验收证据
    # 能通过仓库的 diff 检查，且不同 PowerShell 版本生成一致文本。
    $NormalizedLog = (Get-Content -LiteralPath $LogPath -Raw).TrimEnd("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText(
        $LogPath,
        $NormalizedLog,
        [System.Text.UTF8Encoding]::new($false)
    )

    return [ordered]@{
        profile = $Profile
        passed = $true
        log = (Resolve-Path -LiteralPath $LogPath).Path
    }
}

$TestName = "agent_workspace_storage_writes_real_files_without_touching_paneflow_data"
$DebugResult = Invoke-IsolationTest -Profile "debug" -CargoArguments @(
    "test", "-p", "paneflow-config", $TestName, "--", "--nocapture"
)
$ReleaseResult = Invoke-IsolationTest -Profile "release" -CargoArguments @(
    "test", "-p", "paneflow-config", "--release", $TestName, "--", "--nocapture"
)

# 结果只记录可复现信息；临时主目录由测试进程自动删除，避免遗留伪用户数据。
$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    repository = $RepositoryRoot
    test = $TestName
    debug = $DebugResult
    release = $ReleaseResult
    legacyPaneflowDataUntouched = $true
    result = "passed"
}
$ResultPath = Join-Path $ResultDirectory "运行结果.json"
$Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8

Write-Host "用户数据隔离验收通过。结果：$ResultPath"
