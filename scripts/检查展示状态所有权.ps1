# 只读核对 A020 单一展示状态及历史会话迁移依赖的关键源码锚点。
# 本脚本不修改应用；它同时保证新入口存在、旧双写入口消失。
[CmdletBinding()]
param(
    # 可选 JSON 输出路径；未提供时只把结果写到标准输出。
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

# 每个场景绑定真实文件和实现锚点。锚点使用符号与关键语句，而不是脆弱的固定行号。
$Contracts = @(
    [ordered]@{
        id = "startup-restore"
        path = "src-app/src/app/bootstrap.rs"
        markers = @("fn restored_public_mode(", "fn restored_display_state(", "let restored_display_state =", "workspace_focus: restored_display_state")
    },
    [ordered]@{
        id = "grid-to-focus"
        path = "src-app/src/app/workspace_ops/mod.rs"
        markers = @("pub(crate) fn maximize_workspace_at(", ".transition_display(DisplayCommand::FocusWorkspace", "pub(crate) fn restore_workspace_grid(", ".transition_display(DisplayCommand::RestoreGrid)")
    },
    [ordered]@{
        id = "focused-switch"
        path = "src-app/src/app/workspace_ops/mod.rs"
        markers = @("fn begin_workspace_activation(", "self.active_idx = idx;", "if self.workspace_focus.workspace_id().is_some()")
    },
    [ordered]@{
        id = "diff-enter-exit"
        path = "src-app/src/app/diff_view_actions.rs"
        markers = @("pub(crate) fn enter_diff_mode(", ".transition_display(DisplayCommand::EnterReview)", "pub(crate) fn enter_cli_mode(", ".transition_display(DisplayCommand::ExitReview)")
    },
    [ordered]@{
        id = "settings-overlay"
        path = "src-app/src/app/settings.rs"
        markers = @("pub(crate) fn open_settings_window(", ".transition_display(DisplayCommand::OpenSettings", "pub(crate) fn close_settings(", ".transition_display(DisplayCommand::CloseSettings)")
    },
    [ordered]@{
        id = "close-focused-workspace"
        path = "src-app/src/app/workspace_ops/mod.rs"
        markers = @("pub(crate) fn reconcile_maximized_workspace_after_change(", ".transition_display(DisplayCommand::ClearWorkspace)", "self.close_files_sidebar(cx);")
    },
    [ordered]@{
        id = "session-save"
        path = "src-app/src/app/session.rs"
        markers = @("fn build_session_state(", "mode: paneflow_config::schema::AppMode::Cli,", "diff_scope: Some(self.diff_mode.diff_scope.as_persisted().to_string())")
    },
    [ordered]@{
        id = "single-display-state"
        path = "src-app/src/app/workspace_focus.rs"
        markers = @("pub(crate) fn transition_display(", "self.workspace_focus.transition(command)", "pub(crate) fn terminal_workspace_visible(")
    },
    [ordered]@{
        id = "active-context"
        path = "src-app/src/app/workspace_focus.rs"
        markers = @("pub(crate) struct DisplayState", "pub(crate) enum DisplayCommand", "workspace_root: PathBuf", "terminal_surface_id: Option<u64>", "reveal_workspace_id: Option<u64>")
    }
)

# A020 的退出条件不仅要求新入口存在，还要求旧双写事实源彻底消失。
# 使用精确源码片段避免把 Diff 内部 ViewMode 或兼容 JSON 字段误判为展示双写。
$ForbiddenMarkers = @(
    [ordered]@{
        id = "app-mode-field"
        path = "src-app/src/main.rs"
        marker = "pub(crate) mode: paneflow_config::schema::AppMode"
    },
    [ordered]@{
        id = "settings-section-field"
        path = "src-app/src/main.rs"
        marker = "settings_section: Option<SettingsSection>"
    },
    [ordered]@{
        id = "legacy-mode-projection"
        path = "src-app/src/app/workspace_focus.rs"
        marker = "pub(crate) fn legacy_mode("
    },
    [ordered]@{
        id = "mode-double-write"
        path = "src-app/src/app/workspace_focus.rs"
        marker = "self.mode = self.workspace_focus.legacy_mode();"
    },
    [ordered]@{
        id = "settings-double-write"
        path = "src-app/src/app/workspace_focus.rs"
        marker = "self.settings_section = self.workspace_focus.settings_section();"
    },
    [ordered]@{
        id = "session-mode-double-read"
        path = "src-app/src/app/session.rs"
        marker = "mode: self.mode,"
    }
)

$Results = foreach ($Contract in $Contracts) {
    $FullPath = Join-Path $RepositoryRoot $Contract.path
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "展示状态所有权契约文件不存在：$($Contract.path)"
    }

    $Lines = Get-Content -LiteralPath $FullPath
    $Evidence = foreach ($Marker in $Contract.markers) {
        $MatchIndex = -1
        for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
            if ($Lines[$Index].IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) {
                $MatchIndex = $Index
                break
            }
        }
        if ($MatchIndex -lt 0) {
            throw "展示状态所有权源码锚点缺失：$($Contract.path) -> $Marker"
        }
        [ordered]@{
            marker = $Marker
            line = $MatchIndex + 1
        }
    }

    [ordered]@{
        id = $Contract.id
        path = $Contract.path
        evidence = @($Evidence)
    }
}

$ForbiddenResults = foreach ($Forbidden in $ForbiddenMarkers) {
    $FullPath = Join-Path $RepositoryRoot $Forbidden.path
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "展示状态所有权禁用项文件不存在：$($Forbidden.path)"
    }
    $Content = Get-Content -LiteralPath $FullPath -Raw
    if ($Content.IndexOf($Forbidden.marker, [StringComparison]::Ordinal) -ge 0) {
        throw "展示状态旧双写仍存在：$($Forbidden.path) -> $($Forbidden.marker)"
    }
    [ordered]@{
        id = $Forbidden.id
        path = $Forbidden.path
        forbidden = $Forbidden.marker
    }
}

$Report = [ordered]@{
    schemaVersion = 1
    repositoryRoot = $RepositoryRoot
    contractCount = $Results.Count
    forbiddenCount = $ForbiddenResults.Count
    result = "passed"
    contracts = @($Results)
    forbidden = @($ForbiddenResults)
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
Write-Output "A020 单一展示状态检查通过：$($Results.Count) 组场景，$($ForbiddenResults.Count) 个旧入口已消失"
