//! 工作区创建与会话恢复共享的生命周期边界。
//!
//! 本模块先集中稳定 `workspaceRoot` 的恢复规划；后续 Git 准备、watcher 登记和
//! 持久化回执也由同一接缝承载。这里的纯规划接口不创建 PTY、不访问 GPUI 实体，
//! 因此会话输入边界可以用真实文件系统独立验证。

use std::path::PathBuf;

use gpui::{AppContext, Context, Entity};

use crate::PaneFlowApp;
use crate::pane::{Pane, TabContent};
use crate::terminal::TerminalView;

/// 一个已经通过恢复入口校验的稳定工作区根目录。
///
/// 标题和根目录成对返回，防止调用方在跳过失效条目后继续使用原会话的其他字段，
/// 或把目录替换成进程当前目录而悄悄改变窗口身份。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RestoredWorkspaceRoot {
    /// 会话中持久化的窗口标题，不根据进程启动目录重新推导。
    pub(crate) title: String,
    /// 会话中持久化且当前仍然存在的目录。
    pub(crate) workspace_root: PathBuf,
}

/// 已经加入应用工作区列表、可以登记后续生命周期的一次稳定回执。
///
/// 显式创建会在可选布局校验成功后提交回执；会话恢复会在应用结构体完成构造后
/// 提交回执。两条入口因此共享 Git 准备和 watcher 登记，而不共享各自的界面副作用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkspaceLifecycleRegistration {
    /// 用于异步结果回填的稳定工作区 ID。
    pub(crate) workspace_id: u64,
    /// 工作区在完成内存构造时的索引，仅用于同步创建响应，异步任务不得依赖它。
    pub(crate) index: usize,
    /// 创建时绑定且不会随终端 `cd` 漂移的根目录。
    pub(crate) workspace_root: String,
}

/// 工作区生命周期的单一应用层入口。
///
/// 该类型不保存运行时状态；它把跨显式创建和会话恢复的规则组织成小接口，隐藏
/// 根目录校验、稳定身份回执与异步 Git 登记的具体顺序。
pub(crate) struct WorkspaceLifecycle;

impl WorkspaceLifecycle {
    /// 把一条持久化工作区记录规划为可恢复的稳定根目录。
    ///
    /// 只有仍存在的目录可以恢复。缺失路径、普通文件或不可读取为目录的路径均返回
    /// `None`，由上层只跳过该窗口；禁止回退到进程当前目录，因为那会让文件树、
    /// 路径引用和 Git 审查悄悄绑定到另一个仓库。
    pub(crate) fn plan_restored_root(
        title: &str,
        persisted_root: &str,
    ) -> Option<RestoredWorkspaceRoot> {
        let workspace_root = PathBuf::from(persisted_root);
        if !workspace_root.is_dir() {
            log::warn!(
                "session restore: workspace root {} is unavailable; skipping this workspace",
                workspace_root.display()
            );
            return None;
        }

        Some(RestoredWorkspaceRoot {
            title: title.to_string(),
            workspace_root,
        })
    }

    /// 为已经加入列表的工作区生成统一生命周期回执。
    pub(crate) fn registration(
        workspace_id: u64,
        index: usize,
        workspace_root: String,
    ) -> WorkspaceLifecycleRegistration {
        WorkspaceLifecycleRegistration {
            workspace_id,
            index,
            workspace_root,
        }
    }

    /// 创建单终端窗格并统一订阅终端与窗格事件。
    ///
    /// 显式创建和无布局的会话恢复都使用该入口，避免某条入口漏掉 CWD、退出或
    /// 最后标签关闭事件。该方法只构造内存实体，不启动 Git 或写入会话文件。
    pub(crate) fn create_terminal_pane(
        terminal: Entity<TerminalView>,
        workspace_id: u64,
        cx: &mut Context<PaneFlowApp>,
    ) -> Entity<Pane> {
        cx.subscribe(&terminal, PaneFlowApp::handle_terminal_event)
            .detach();
        let pane = cx.new(|cx| Pane::new(terminal, workspace_id, cx));
        cx.subscribe(&pane, PaneFlowApp::handle_pane_event).detach();
        pane
    }

    /// 从恢复后的多个标签创建窗格并统一订阅其中的真实终端。
    ///
    /// Markdown 和 Diff 标签没有终端事件；只订阅 `Terminal` 变体，随后统一订阅
    /// 窗格事件。调用方必须保证 `tabs` 非空。
    pub(crate) fn create_restored_pane(
        tabs: Vec<TabContent>,
        selected_idx: usize,
        workspace_id: u64,
        cx: &mut Context<PaneFlowApp>,
    ) -> Entity<Pane> {
        for terminal in tabs.iter().filter_map(TabContent::as_terminal) {
            cx.subscribe(terminal, PaneFlowApp::handle_terminal_event)
                .detach();
        }
        let pane = cx.new(|cx| Pane::new_with_tabs(tabs, selected_idx, workspace_id, cx));
        cx.subscribe(&pane, PaneFlowApp::handle_pane_event).detach();
        pane
    }

    /// 把会话中的活动索引映射到过滤后的工作区列表。
    ///
    /// 活动条目有效时精确恢复；若它失效，优先选择它之前最近的有效条目，否则选择
    /// 第一个有效条目。这样跳过任意失效窗口都不会把焦点错误偏移到另一条记录。
    pub(crate) fn restored_active_index(
        persisted_active: usize,
        restored_session_indices: &[usize],
    ) -> usize {
        restored_session_indices
            .iter()
            .position(|index| *index == persisted_active)
            .or_else(|| {
                restored_session_indices
                    .iter()
                    .rposition(|index| *index < persisted_active)
            })
            .unwrap_or(0)
    }
}

impl PaneFlowApp {
    /// 为一批已经确认保留的工作区登记共享后台生命周期。
    ///
    /// 这里只启动 Git 准备；成功后的仓库元数据、统计、watcher 和会话保存由既有
    /// 稳定 ID 回填流程完成。调用方各自保留界面通知、Diff 协调等入口专属行为。
    pub(crate) fn register_workspace_lifecycles(
        &mut self,
        registrations: &[WorkspaceLifecycleRegistration],
        cx: &mut Context<Self>,
    ) {
        for registration in registrations {
            self.spawn_workspace_git_preparation(
                registration.workspace_id,
                registration.workspace_root.clone(),
                cx,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::WorkspaceLifecycle;

    /// 有效目录必须保持原始标题和根目录，不能重新解释为启动目录。
    #[test]
    fn restored_root_preserves_existing_directory_identity() {
        let dir = tempfile::tempdir().expect("应能创建真实工作区目录");
        let root = dir.path().to_string_lossy().into_owned();

        let plan = WorkspaceLifecycle::plan_restored_root("Workspace A", &root)
            .expect("有效目录应生成恢复计划");

        assert_eq!(plan.title, "Workspace A");
        assert_eq!(plan.workspace_root, dir.path());
    }

    /// 缺失目录和普通文件都不能被替换为任意可用目录。
    #[test]
    fn restored_root_skips_missing_and_non_directory_paths() {
        let dir = tempfile::tempdir().expect("应能创建真实临时目录");
        let missing = dir.path().join("missing");
        let file = dir.path().join("not-a-workspace.txt");
        std::fs::write(&file, "真实文件").expect("应能创建普通文件边界");

        assert!(
            WorkspaceLifecycle::plan_restored_root("Missing", &missing.to_string_lossy()).is_none()
        );
        assert!(WorkspaceLifecycle::plan_restored_root("File", &file.to_string_lossy()).is_none());
    }

    /// 文件系统根目录如果确实被用户保存，仍是合法且稳定的工作区身份。
    #[test]
    fn restored_root_does_not_repair_numbered_title_to_process_cwd() {
        let root = std::env::current_dir()
            .expect("应能读取当前目录")
            .ancestors()
            .last()
            .expect("当前目录应具有文件系统根")
            .to_path_buf();

        let plan = WorkspaceLifecycle::plan_restored_root("Terminal 1", &root.to_string_lossy())
            .expect("真实根目录仍应可恢复");

        assert_eq!(plan.title, "Terminal 1");
        assert_eq!(plan.workspace_root, root);
    }

    /// 跳过失效条目后活动索引仍应指向同一会话条目或最近的前一条。
    #[test]
    fn restored_active_index_tracks_filtered_session_entries() {
        assert_eq!(
            WorkspaceLifecycle::restored_active_index(4, &[0, 2, 4, 5]),
            2
        );
        assert_eq!(
            WorkspaceLifecycle::restored_active_index(3, &[0, 2, 4, 5]),
            1
        );
        assert_eq!(WorkspaceLifecycle::restored_active_index(0, &[2, 4]), 0);
        assert_eq!(WorkspaceLifecycle::restored_active_index(2, &[]), 0);
    }

    /// 生命周期回执必须完整保留稳定 ID、同步索引与根目录。
    #[test]
    fn lifecycle_registration_keeps_stable_identity() {
        let registration = WorkspaceLifecycle::registration(42, 3, r"C:\work\project".to_string());

        assert_eq!(registration.workspace_id, 42);
        assert_eq!(registration.index, 3);
        assert_eq!(registration.workspace_root, r"C:\work\project");
    }
}
