# 只读核对 A012 展示状态与会话所有权审查依赖的关键源码锚点。
# 本脚本不推断设计是否正确，也不修改应用；它只保证审查覆盖的启动恢复、聚焦、
# 模式、设置、关闭和活动上下文路径没有在后续修改中静默消失。
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
        markers = @("fn build_session_state(", "mode: self.mode,", "diff_scope: Some(self.diff_mode.diff_scope.as_persisted().to_string())")
    },
    [ordered]@{
        id = "single-write-bridge"
        path = "src-app/src/app/workspace_focus.rs"
        markers = @("pub(crate) fn transition_display(", "self.mode = self.workspace_focus.legacy_mode();", "self.settings_section = self.workspace_focus.settings_section();")
    },
    [ordered]@{
        id = "active-context"
        path = "src-app/src/app/workspace_focus.rs"
        markers = @("pub(crate) struct DisplayState", "pub(crate) enum DisplayCommand", "workspace_root: PathBuf", "terminal_surface_id: Option<u64>", "reveal_workspace_id: Option<u64>")
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
Write-Output "A012 展示状态所有权检查通过：$($Results.Count) 组场景"
