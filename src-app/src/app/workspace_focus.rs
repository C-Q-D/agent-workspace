//! 聚焦工作区上下文。
//!
//! 本模块把应用级放大状态、稳定工作区目录、文件引用目标终端以及恢复矩阵时的
//! 定位目标收敛为一个进程内状态对象。它不负责 UI、文件扫描或进程生命周期，
//! 只维护这些消费者共同依赖的不变量，避免切换工作区时分别更新多个松散字段。

use std::path::{Path, PathBuf};

/// 当前被应用级放大的稳定工作区上下文。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedWorkspaceContext {
    /// 创建工作区时分配的稳定 ID；重命名和索引变化不会改变它。
    workspace_id: u64,
    /// 工作区创建时绑定的稳定目录；不跟随终端内部临时 `cd`。
    workspace_root: PathBuf,
    /// 文件引用应注入的真实终端 Surface；面板尚未绑定时为空。
    terminal_surface_id: Option<u64>,
}

/// 应用级聚焦状态的唯一写入边界。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct WorkspaceFocusState {
    /// 当前聚焦上下文；为空表示正在显示终端矩阵。
    focused: Option<FocusedWorkspaceContext>,
    /// 从聚焦态恢复后，矩阵下一帧需要滚动或翻页显示的稳定工作区 ID。
    reveal_workspace_id: Option<u64>,
}

impl WorkspaceFocusState {
    /// 进入或重定向聚焦工作区。
    ///
    /// 切换到另一个稳定 ID 时必须清除旧终端 Surface，防止把 B 工作区的文件引用
    /// 注入 A 的 CLI。重复对齐同一工作区时保留 Surface，避免无意义地丢失绑定。
    pub(crate) fn focus(&mut self, workspace_id: u64, workspace_root: impl Into<PathBuf>) {
        let workspace_root = workspace_root.into();
        let terminal_surface_id = self
            .focused
            .as_ref()
            .filter(|context| context.workspace_id == workspace_id)
            .and_then(|context| context.terminal_surface_id);
        self.focused = Some(FocusedWorkspaceContext {
            workspace_id,
            workspace_root,
            terminal_surface_id,
        });
        self.reveal_workspace_id = None;
    }

    /// 退出聚焦态并记录矩阵应重新显示的稳定工作区。
    ///
    /// 返回 `false` 表示调用前已经处于矩阵态，调用方无需触发额外关闭或重绘。
    pub(crate) fn restore_grid(&mut self) -> bool {
        let Some(context) = self.focused.take() else {
            return false;
        };
        self.reveal_workspace_id = Some(context.workspace_id);
        true
    }

    /// 工作区集合变化且已无活动项时清空聚焦与恢复目标。
    pub(crate) fn clear(&mut self) {
        self.focused = None;
        self.reveal_workspace_id = None;
    }

    /// 返回当前是否处于应用级聚焦态。
    pub(crate) fn is_focused(&self) -> bool {
        self.focused.is_some()
    }

    /// 返回当前聚焦工作区的稳定 ID。
    pub(crate) fn workspace_id(&self) -> Option<u64> {
        self.focused.as_ref().map(|context| context.workspace_id)
    }

    /// 返回当前聚焦工作区的稳定绑定目录。
    pub(crate) fn workspace_root(&self) -> Option<&Path> {
        self.focused
            .as_ref()
            .map(|context| context.workspace_root.as_path())
    }

    /// 返回文件引用当前绑定的终端 Surface。
    pub(crate) fn terminal_surface_id(&self) -> Option<u64> {
        self.focused
            .as_ref()
            .and_then(|context| context.terminal_surface_id)
    }

    /// 更新当前聚焦工作区的终端 Surface；矩阵态下忽略陈旧事件。
    pub(crate) fn set_terminal_surface_id(&mut self, surface_id: Option<u64>) {
        if let Some(context) = &mut self.focused {
            context.terminal_surface_id = surface_id;
        }
    }

    /// 取出一次性的矩阵恢复目标，保证后续普通重绘不会反复翻页。
    pub(crate) fn take_reveal_workspace_id(&mut self) -> Option<u64> {
        self.reveal_workspace_id.take()
    }
}

#[cfg(test)]
mod tests {
    use super::WorkspaceFocusState;
    use paneflow_config::schema::AppMode;
    use std::path::Path;

    /// 旧展示字段组合是否满足当前公开产品的不变量。
    ///
    /// 这个辅助函数只描述 A012 已确认的规则，不参与生产状态转换。A016 引入单一
    /// 展示状态后，下面的待修测试应改为直接验证新类型无法构造这些组合。
    fn legacy_display_fields_are_consistent(
        mode: AppMode,
        settings_open: bool,
        focus: &WorkspaceFocusState,
        active_workspace_id: Option<u64>,
    ) -> bool {
        if settings_open {
            return mode == AppMode::Cli;
        }

        match mode {
            AppMode::Cli => true,
            AppMode::Diff => focus.workspace_id() == active_workspace_id,
            // Agents 已退出 v1 公开产品面，因此不属于可构造的公开展示状态。
            AppMode::Agents => false,
        }
    }

    /// 旧字段能够独立组成“Review 可见但没有放大工作区”的非法状态。
    #[test]
    fn legacy_fields_expose_review_without_focused_workspace_gap() {
        let focus = WorkspaceFocusState::default();

        assert!(!legacy_display_fields_are_consistent(
            AppMode::Diff,
            false,
            &focus,
            Some(41),
        ));
    }

    /// 旧字段能够同时表达设置覆盖层和仍在后台存活的 Review 主模式。
    #[test]
    fn legacy_fields_expose_settings_over_review_gap() {
        let mut focus = WorkspaceFocusState::default();
        focus.focus(41, r"C:\repo-a");

        assert!(!legacy_display_fields_are_consistent(
            AppMode::Diff,
            true,
            &focus,
            Some(41),
        ));
    }

    /// A016 的红灯：当前类型系统无法阻止 Review 与空聚焦上下文同时存在。
    ///
    /// 本原子只建立失败证据，因此先忽略该目标态断言，避免把已知红灯带入普通
    /// CI。A016 必须用单一展示状态替换此测试，并移除忽略标记。
    #[test]
    #[ignore = "A016 将引入不能构造该非法组合的单一展示状态"]
    fn display_state_must_not_allow_review_without_focus() {
        let focus = WorkspaceFocusState::default();

        assert!(
            legacy_display_fields_are_consistent(AppMode::Diff, false, &focus, Some(41)),
            "旧 AppMode 与 WorkspaceFocusState 可独立写入，Review 因而能缺少聚焦上下文"
        );
    }

    /// A016 的第二个红灯：设置页不应与 Review 同时成为两个可写展示事实。
    #[test]
    #[ignore = "A016 将把设置页建模为互斥的单一展示状态"]
    fn display_state_must_not_allow_settings_over_review() {
        let mut focus = WorkspaceFocusState::default();
        focus.focus(41, r"C:\repo-a");

        assert!(
            legacy_display_fields_are_consistent(AppMode::Diff, true, &focus, Some(41)),
            "旧 settings_section 覆盖 Review 渲染，但不会退出底层 Review 状态"
        );
    }

    #[test]
    fn switching_workspace_replaces_root_and_drops_stale_surface() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        state.set_terminal_surface_id(Some(4101));

        state.focus(72, r"C:\repo-b");

        assert_eq!(state.workspace_id(), Some(72));
        assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-b")));
        assert_eq!(state.terminal_surface_id(), None);
    }

    #[test]
    fn reconciling_same_workspace_preserves_surface_binding() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        state.set_terminal_surface_id(Some(4101));

        state.focus(41, r"C:\repo-a-renamed");

        assert_eq!(
            state.workspace_root(),
            Some(Path::new(r"C:\repo-a-renamed"))
        );
        assert_eq!(state.terminal_surface_id(), Some(4101));
    }

    #[test]
    fn restoring_grid_is_explicit_and_reveal_is_one_shot() {
        let mut state = WorkspaceFocusState::default();
        assert!(!state.restore_grid());

        state.focus(41, r"C:\repo-a");
        assert!(state.restore_grid());
        assert!(!state.is_focused());
        assert_eq!(state.take_reveal_workspace_id(), Some(41));
        assert_eq!(state.take_reveal_workspace_id(), None);
    }

    /// 用户恢复矩阵后若立即从左栏选择其他工作区，新聚焦必须取消旧矩阵定位请求。
    #[test]
    fn refocusing_after_restore_cancels_stale_grid_reveal() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        assert!(state.restore_grid());

        state.focus(72, r"C:\repo-b");

        assert_eq!(state.workspace_id(), Some(72));
        assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-b")));
        assert_eq!(state.take_reveal_workspace_id(), None);
    }

    /// 最后一个工作区关闭或恢复结果为空时，清理操作必须释放全部活动上下文。
    #[test]
    fn clearing_focused_workspace_drops_all_active_context() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        state.set_terminal_surface_id(Some(4101));

        state.clear();

        assert!(!state.is_focused());
        assert_eq!(state.workspace_id(), None);
        assert_eq!(state.workspace_root(), None);
        assert_eq!(state.terminal_surface_id(), None);
        assert_eq!(state.take_reveal_workspace_id(), None);
    }
}
