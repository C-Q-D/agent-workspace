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
    use std::path::Path;

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
}
