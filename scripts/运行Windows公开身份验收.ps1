<#
.SYNOPSIS
使用真实 Release 程序验收 AgentWorkspace 的 Windows 公开身份。

.DESCRIPTION
脚本在隔离的 Cargo 目标目录构建 Release 程序，并验证程序文件名、CLI 输出、
MCP/Hook 帮助、AUMID、WiX 身份与公开链接。所有命令原始输出和机器可读结果
都会保存到仓库内的中文验收目录，便于重复执行和审查。
#>
[CmdletBinding()]
param(
    # 验收证据根目录；默认使用仓库内目录，便于跟随提交保留。
    [string]$OutputRoot = "",

    # 已有最新 Release 产物时可跳过构建，仅重复执行身份检查。
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 所有路径都从脚本位置解析，避免调用者当前目录改变验收对象。
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot "docs\验收\Windows公开身份数据"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ResultDirectory = Join-Path $OutputRoot "Release-$Timestamp"
$TargetDirectory = Join-Path $RepositoryRoot "target\identity-atom"
$ReleaseDirectory = Join-Path $TargetDirectory "release"
$ExecutablePath = Join-Path $ReleaseDirectory "agent-workspace.exe"
$LegacyExecutablePath = Join-Path $ReleaseDirectory "paneflow.exe"
$CargoManifest = Get-Content -LiteralPath (Join-Path $RepositoryRoot "Cargo.toml") -Raw
$VersionMatch = [regex]::Match($CargoManifest, '(?m)^version\s*=\s*"([^"]+)"')
if (-not $VersionMatch.Success) {
    throw "无法从 Cargo.toml 解析工作区版本"
}
$ExpectedVersion = $VersionMatch.Groups[1].Value
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null

function Write-Utf8Text {
    <#
    .SYNOPSIS
    以无 BOM UTF-8 和统一换行保存可复核文本。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Text
    )

    $Normalized = $Text.TrimEnd("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $Normalized,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-TextContains {
    <#
    .SYNOPSIS
    验证公开输出包含必须出现的稳定文本。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Label 缺少预期文本：$Expected"
    }
}

function Assert-TextExcludes {
    <#
    .SYNOPSIS
    验证公开输出未重新出现上游身份。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Unexpected,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Text.Contains($Unexpected)) {
        throw "$Label 包含不应出现的文本：$Unexpected"
    }
}

function Invoke-IdentityCommand {
    <#
    .SYNOPSIS
    运行真实 Release 程序，保存输出并校验退出码。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedExitCode
    )

    $Lines = & $ExecutablePath @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
    $Text = ($Lines | Out-String).TrimEnd("`r", "`n")
    $LogPath = Join-Path $ResultDirectory "$Name.txt"
    Write-Utf8Text -Path $LogPath -Text $Text

    if ($ExitCode -ne $ExpectedExitCode) {
        throw "$Name 退出码为 $ExitCode，预期为 $ExpectedExitCode。输出：$LogPath"
    }

    return [ordered]@{
        name = $Name
        arguments = $Arguments
        exitCode = $ExitCode
        output = $Text
        log = (Resolve-Path -LiteralPath $LogPath).Path
    }
}

if (-not $SkipBuild) {
    $BuildLogPath = Join-Path $ResultDirectory "Release构建.txt"
    $PreviousTargetDirectory = $env:CARGO_TARGET_DIR
    try {
        $env:CARGO_TARGET_DIR = $TargetDirectory
        Push-Location $RepositoryRoot
        try {
            $BuildLines = & cargo build -p paneflow-app --release 2>&1
            $BuildExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if ($null -eq $PreviousTargetDirectory) {
            Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:CARGO_TARGET_DIR = $PreviousTargetDirectory
        }
    }
    Write-Utf8Text -Path $BuildLogPath -Text (($BuildLines | Out-String).TrimEnd("`r", "`n"))
    if ($BuildExitCode -ne 0) {
        throw "Release 构建失败，退出码：$BuildExitCode。请先分析：$BuildLogPath"
    }
}

if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "未找到 Release 主程序：$ExecutablePath"
}
if (Test-Path -LiteralPath $LegacyExecutablePath -PathType Leaf) {
    throw "隔离 Release 目录仍存在旧主程序：$LegacyExecutablePath"
}

$Help = Invoke-IdentityCommand -Name "帮助" -Arguments @("--help") -ExpectedExitCode 0
$Version = Invoke-IdentityCommand -Name "版本" -Arguments @("--version") -ExpectedExitCode 0
$Unknown = Invoke-IdentityCommand -Name "未知命令" -Arguments @("searh") -ExpectedExitCode 2
$Mcp = Invoke-IdentityCommand -Name "MCP帮助" -Arguments @("mcp") -ExpectedExitCode 2
$Hooks = Invoke-IdentityCommand -Name "Hook帮助" -Arguments @("hooks", "bogus") -ExpectedExitCode 2

Assert-TextContains -Text $Help.output -Expected "AgentWorkspace" -Label "顶层帮助"
Assert-TextContains -Text $Help.output -Expected "Usage: agent-workspace" -Label "顶层帮助"
Assert-TextContains -Text $Help.output -Expected "https://github.com/C-Q-D/agent-workspace" -Label "顶层帮助"
Assert-TextExcludes -Text $Help.output -Unexpected "ArthurDEV44/paneflow" -Label "顶层帮助"
if ($Version.output.Trim() -ne "agent-workspace $ExpectedVersion") {
    throw "版本输出不符合公开身份：$($Version.output)"
}
Assert-TextContains -Text $Unknown.output -Expected "agent-workspace: unknown verb" -Label "未知命令"
Assert-TextContains -Text $Mcp.output -Expected "AgentWorkspace MCP bridge" -Label "MCP 帮助"
Assert-TextContains -Text $Mcp.output -Expected "agent-workspace mcp install" -Label "MCP 帮助"
Assert-TextContains -Text $Hooks.output -Expected "AgentWorkspace agent-notification hooks" -Label "Hook 帮助"
Assert-TextContains -Text $Hooks.output -Expected "agent-workspace hooks setup" -Label "Hook 帮助"

$WindowsIdentityPath = Join-Path $RepositoryRoot "src-app\src\windows_app_identity.rs"
$WixPath = Join-Path $RepositoryRoot "packaging\wix\main.wxs"
$ProductIdentityPath = Join-Path $RepositoryRoot "src-app\src\product_identity.rs"
$WindowsIdentitySource = Get-Content -LiteralPath $WindowsIdentityPath -Raw
$WixSource = Get-Content -LiteralPath $WixPath -Raw
$ProductIdentitySource = Get-Content -LiteralPath $ProductIdentityPath -Raw
Assert-TextContains -Text $WindowsIdentitySource -Expected "CQD.AgentWorkspace" -Label "Windows AUMID"
Assert-TextContains -Text $WixSource -Expected "CQD.AgentWorkspace" -Label "WiX AUMID"
Assert-TextContains -Text $WixSource -Expected "Name='AgentWorkspace'" -Label "WiX 产品名"
Assert-TextContains -Text $WixSource -Expected "agent-workspace.exe" -Label "WiX 主程序"
Assert-TextContains -Text $ProductIdentitySource -Expected "https://api.github.com/repos/C-Q-D/agent-workspace/releases/latest" -Label "更新 API"

$FileInfo = Get-Item -LiteralPath $ExecutablePath
$Hash = Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256
$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    repository = $RepositoryRoot
    targetDirectory = $TargetDirectory
    executable = [ordered]@{
        path = $FileInfo.FullName
        name = $FileInfo.Name
        length = $FileInfo.Length
        sha256 = $Hash.Hash.ToLowerInvariant()
        legacyExecutableAbsent = $true
    }
    commands = @($Help, $Version, $Unknown, $Mcp, $Hooks)
    windowsIdentity = [ordered]@{
        aumid = "CQD.AgentWorkspace"
        wixProductName = "AgentWorkspace"
        wixExecutable = "agent-workspace.exe"
    }
    publicRepository = "https://github.com/C-Q-D/agent-workspace"
    latestReleaseApi = "https://api.github.com/repos/C-Q-D/agent-workspace/releases/latest"
    result = "passed"
}
$ResultPath = Join-Path $ResultDirectory "运行结果.json"
$ResultJson = $Result | ConvertTo-Json -Depth 8
Write-Utf8Text -Path $ResultPath -Text $ResultJson

Write-Host "Windows 公开身份验收通过。结果：$ResultPath"
