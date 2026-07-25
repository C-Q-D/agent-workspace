# 只读核对 AgentWorkspace 公开入口与产品面清单依赖的关键源码锚点。
# 本脚本不启动应用、不修改配置，也不以模块存在推断用户可达性；它只防止审查文档引用的
# 启动、Action、设置、模式、bootstrap 和 Windows 打包事实在后续修改中静默失效。
[CmdletBinding()]
param(
    # 可选 JSON 输出路径；未提供时只把结果写到标准输出。
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

# 每个契约项都绑定一个真实文件和若干源码标记。分类仅表示 A010 审查结论，不代表后续
# A014 的最终处置决定。
$Contracts = @(
    [ordered]@{
        id = "startup"
        category = "AgentWorkspace核心"
        path = "src-app/src/main.rs"
        markers = @("fn main()", "PaneFlowApp::new(cx)", 'app_id: Some("agent-workspace".into())')
    },
    [ordered]@{
        id = "app-module-registry"
        category = "仅测试或内部"
        path = "src-app/src/app/mod.rs"
        markers = @("pub mod bootstrap;", "pub mod workspace_ops;", "pub mod diff_view_actions;")
    },
    [ordered]@{
        id = "action-registry"
        category = "混合"
        path = "src-app/src/app/actions.rs"
        markers = @("SplitHorizontally", "OpenDiffView", "OpenAgentsThreadMenu", "ToggleRosettaSurface")
    },
    [ordered]@{
        id = "windows-titlebar-menus"
        category = "混合"
        path = "src-app/src/app/profile_menu.rs"
        markers = @("render_title_bar_files_menu", "render_title_bar_help_menu", '"Settings"', '"Automations"')
    },
    [ordered]@{
        id = "sidebar-navigation"
        category = "AgentWorkspace核心"
        path = "src-app/src/app/sidebar_actions_menu.rs"
        markers = @('"Review"', "enter_cli_mode", "enter_diff_mode", '"Settings".into()')
    },
    [ordered]@{
        id = "settings-sections"
        category = "混合"
        path = "src-app/src/settings/chrome.rs"
        markers = @(
            'label: "General"',
            'label: "Themes"',
            'label: "Keyboard Shortcuts"',
            'label: "Terminal"',
            'label: "Notifications"',
            'label: "AI Agent"',
            'label: "MCP Servers"',
            'label: "Workspaces"'
        )
    },
    [ordered]@{
        id = "public-mode-restore"
        category = "AgentWorkspace核心"
        path = "src-app/src/app/bootstrap.rs"
        markers = @(
            "fn restored_public_mode(",
            "paneflow_config::schema::AppMode::Diff",
            "paneflow_config::schema::AppMode::Agents",
            "paneflow_config::schema::AppMode::Cli"
        )
    },
    [ordered]@{
        id = "scriptable-cli"
        category = "混合"
        path = "src-app/src/cli/mod.rs"
        markers = @('name = "agent-workspace"', "enum Commands", "Commands::Read", "Commands::Send")
    },
    [ordered]@{
        id = "windows-msi"
        category = "AgentWorkspace核心"
        path = "packaging/wix/main.wxs"
        markers = @("Name='AgentWorkspace'", "Name='agent-workspace.exe'", "HelperBinaries")
    },
    [ordered]@{
        id = "windows-portable"
        category = "AgentWorkspace核心"
        path = "scripts/生成Windows便携包.ps1"
        markers = @('$PackageRoot = "AgentWorkspace-$Version-windows-x64"', '"agent-workspace.exe"', '$HelperNames')
    }
)

$Results = foreach ($Contract in $Contracts) {
    $FullPath = Join-Path $RepositoryRoot $Contract.path
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "公开产品面契约文件不存在：$($Contract.path)"
    }

    $Lines = Get-Content -LiteralPath $FullPath
    $Evidence = foreach ($Marker in $Contract.markers) {
        # 使用 Ordinal 包含判断避免正则转义和系统区域设置影响，返回第一个命中行。
        $MatchIndex = -1
        for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
            if ($Lines[$Index].IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) {
                $MatchIndex = $Index
                break
            }
        }
        if ($MatchIndex -lt 0) {
            throw "公开产品面源码锚点缺失：$($Contract.path) -> $Marker"
        }
        [ordered]@{
            marker = $Marker
            line = $MatchIndex + 1
        }
    }

    [ordered]@{
        id = $Contract.id
        category = $Contract.category
        path = $Contract.path
        evidence = @($Evidence)
    }
}

$Report = [ordered]@{
    schemaVersion = 1
    repositoryRoot = $RepositoryRoot
    contractCount = $Results.Count
    result = "passed"
    contracts = @($Results)
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
Write-Output "A010 公开产品面清单检查通过：$($Results.Count) 组契约"
