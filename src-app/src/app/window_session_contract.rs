//! WindowSession 与 ActiveContext 所有权契约测试。
//!
//! A021 只固定现有行为和后续目标态，不提前创建生产聚合对象。可通过的特征测试
//! 证明当前创建、聚焦、切换、关闭、恢复和非 Git 初始化规则；两条显式忽略的
//! 红灯分别交给 A022 与 A024 消除，避免把尚未实现的目标态带入普通 CI。

use super::workspace_focus::{DisplayState, DisplaySurface};
use super::workspace_lifecycle::WorkspaceLifecycle;
use crate::SettingsSection;
use crate::workspace::{WindowSession, WindowSessionIdentityError, ensure_local_repository};
use std::path::Path;

/// 创建入口生成的生命周期回执必须把一个稳定 ID 与一个稳定目录绑定。
#[test]
fn created_session_keeps_one_stable_identity_and_workspace_root() {
    let registration = WorkspaceLifecycle::registration(41, 3, r"C:\work\project-a".to_string());

    assert_eq!(registration.workspace_id, 41);
    assert_eq!(registration.workspace_root, r"C:\work\project-a");
    assert_eq!(
        registration.index, 3,
        "列表索引只能用于同步响应，不能替代稳定 ID"
    );
}

/// Focused、Review 与 Settings 只是同一会话的视图，切换视图不能重写其身份或目录。
#[test]
fn view_switches_preserve_session_identity_and_workspace_root() {
    let mut state = DisplayState::default();
    state.focus(41, r"C:\repo-a");
    state.set_terminal_surface_id(Some(4101));

    state.enter_review().expect("聚焦会话应能进入 Review");
    assert_eq!(state.surface(), DisplaySurface::Review);
    assert_eq!(state.workspace_id(), Some(41));
    assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-a")));
    assert_eq!(state.terminal_surface_id(), Some(4101));

    state.open_settings(SettingsSection::General);
    assert_eq!(state.surface(), DisplaySurface::Settings);
    assert_eq!(state.workspace_id(), Some(41));
    assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-a")));
    assert_eq!(state.terminal_surface_id(), Some(4101));

    assert!(state.close_settings());
    state.exit_review().expect("Review 应返回同一聚焦会话");
    assert_eq!(state.surface(), DisplaySurface::Focused);
    assert_eq!(state.workspace_id(), Some(41));
    assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-a")));
    assert_eq!(state.terminal_surface_id(), Some(4101));
}

/// 聚焦切换只能保留一个活动上下文；关闭最后一个会话后必须完全释放。
#[test]
fn focus_switch_and_close_leave_at_most_one_active_context() {
    let mut state = DisplayState::default();
    state.focus(41, r"C:\repo-a");
    state.set_terminal_surface_id(Some(4101));

    state.focus(72, r"C:\repo-b");
    assert_eq!(state.workspace_id(), Some(72));
    assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-b")));
    assert_eq!(
        state.terminal_surface_id(),
        None,
        "切换稳定会话后不得保留上一终端的 Surface"
    );

    state.clear();
    assert_eq!(state.surface(), DisplaySurface::Grid);
    assert_eq!(state.workspace_id(), None);
    assert_eq!(state.workspace_root(), None);
    assert_eq!(state.terminal_surface_id(), None);
}

/// 会话恢复只能接受原有目录，并保留标题；不能用进程当前目录悄悄修复身份。
#[test]
fn restored_session_preserves_persisted_root_and_rejects_missing_root() {
    let existing = tempfile::tempdir().expect("应能创建真实恢复目录");
    let root = existing.path().to_string_lossy().into_owned();
    let restored = WorkspaceLifecycle::plan_restored_root("Workspace A", &root)
        .expect("存在的真实目录应能恢复");

    assert_eq!(restored.title, "Workspace A");
    assert_eq!(restored.workspace_root, existing.path());

    let missing = existing.path().join("missing");
    assert!(
        WorkspaceLifecycle::plan_restored_root("Missing", &missing.to_string_lossy()).is_none(),
        "缺失目录必须跳过，不能伪造新的 workspaceRoot"
    );
}

/// 非 Git 目录通过真实 Git 命令初始化；重复准备复用同一个仓库而不创建嵌套身份。
#[test]
fn non_git_session_root_is_initialized_once_and_reused() {
    let root = tempfile::tempdir().expect("应能创建真实非 Git 目录");
    // Git 元数据解析会返回 Windows 规范化路径（可能带 `\\?\` 前缀），因此期望值
    // 也走同一文件系统规范化；仍比较完整目录身份，不做字符串模糊匹配。
    let canonical_root = root.path().canonicalize().expect("应能规范化真实临时目录");

    let first = ensure_local_repository(root.path()).expect("首次准备应初始化本地 Git 仓库");
    let second = ensure_local_repository(root.path()).expect("重复准备应复用同一个 Git 仓库");

    assert_eq!(first.worktree_root, canonical_root);
    assert_eq!(second.worktree_root, canonical_root);
    assert_eq!(first.git_dir, second.git_dir);
    assert!(root.path().join(".git").is_dir());
}

/// A022 的目标态已经成为真实类型契约：聚合根公开稳定身份、目录和终端生命周期查询。
#[test]
fn window_session_must_be_a_single_production_aggregate() {
    let _root_accessor: fn(&WindowSession) -> &Path = WindowSession::workspace_root;
    let _terminal_lifecycle: fn(
        &WindowSession,
        &gpui::App,
    ) -> crate::terminal::TerminalLifecycleStatus = WindowSession::terminal_status;

    assert!(
        std::mem::needs_drop::<WindowSession>(),
        "WindowSession 必须唯一持有需要释放的布局/终端实体，不能退化为复制型快照"
    );
}

/// 非零 ID 与非空 root 是所有构造入口共享的身份门禁。
#[test]
fn window_session_identity_rejects_detached_id_and_empty_root() {
    assert_eq!(
        WindowSession::validate_identity(0, r"C:\repo-a"),
        Err(WindowSessionIdentityError::MissingId)
    );
    assert_eq!(
        WindowSession::validate_identity(41, "  "),
        Err(WindowSessionIdentityError::MissingWorkspaceRoot)
    );
    assert_eq!(WindowSession::validate_identity(41, r"C:\repo-a"), Ok(()));
}

/// 相同 ID 不能被重复绑定到另一目录；不同 ID 可以共享 root 以支持同仓库多 CLI。
#[test]
fn window_session_identity_rejects_root_rebinding_but_allows_shared_repo() {
    assert_eq!(
        WindowSession::validate_rebinding(41, r"C:\repo-a", 41, r"C:\repo-b"),
        Err(WindowSessionIdentityError::WorkspaceRootMismatch)
    );
    assert_eq!(
        WindowSession::validate_rebinding(41, r"C:\repo-a", 72, r"C:\repo-a"),
        Ok(())
    );
}

/// 模板布局可以改变子终端 cwd，但不能改写窗口创建时绑定的稳定 root。
#[test]
fn terminal_layout_replacement_does_not_rebind_workspace_root() {
    let settings_source = include_str!("../settings/tabs/workspaces.rs");

    assert!(
        settings_source.contains("workspace.replace_terminal_layout(tree);"),
        "模板应用必须通过 WindowSession 的布局替换入口"
    );
    assert!(
        !settings_source.contains("workspace.cwd = first_cwd.display().to_string();"),
        "子终端 cwd 不得成为新的稳定 workspaceRoot"
    );
}

/// 新建、最后窗格补建和显式关闭必须分别经过统一创建与消费式关闭入口。
#[test]
fn create_restart_and_close_use_window_session_lifecycle_entries() {
    let lifecycle_source = include_str!("workspace_lifecycle.rs");
    let operations_source = include_str!("workspace_ops/mod.rs");
    let events_source = include_str!("event_handlers.rs");

    assert!(lifecycle_source.contains("fn create_default_terminal_pane("));
    assert!(
        operations_source
            .matches("create_default_terminal_pane(")
            .count()
            >= 2,
        "显式创建与最后窗格补建必须共用默认终端工厂"
    );
    assert!(events_source.contains("create_default_terminal_pane(ws_id, cwd, cx)"));
    assert!(operations_source.contains("let worktrees = workspace.close();"));
    assert!(operations_source.contains("ws.insert_restored_pane(new_pane.clone(), window, cx);"));
    assert!(
        !operations_source.contains("ws.root = Some(LayoutTree::Leaf(new_pane.clone()));"),
        "撤销关闭也不得绕过 WindowSession 直接改写布局根节点"
    );
}

/// A024 的目标态红灯：活动文件/Git 上下文必须从会话派生，不能再保存第二份 root。
///
/// A024 完成后应以真实 ActiveContext API 替换源码检查并移除忽略。
#[test]
#[ignore = "A024 将让 ActiveContext 只从当前聚焦 WindowSession 派生"]
fn active_context_must_not_own_a_duplicate_workspace_root() {
    let focus_source = include_str!("workspace_focus.rs");

    assert!(
        !focus_source.contains("struct FocusedWorkspaceContext {\n    /// 创建工作区时分配的稳定 ID；重命名和索引变化不会改变它。\n    workspace_id: u64,\n    /// 工作区创建时绑定的稳定目录；不跟随终端内部临时 `cd`。\n    workspace_root: PathBuf,"),
        "当前 FocusedWorkspaceContext 仍复制 workspaceRoot；A024 必须改为按 WindowSession ID 派生"
    );
}
