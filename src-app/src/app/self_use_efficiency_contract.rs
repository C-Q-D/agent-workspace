//! 自用效率功能所有权契约测试。
//!
//! 本文件只在测试构建中存在，用纯值模型固定 E005 以后轻量编辑、文件上下文、
//! Markdown 预览和异步加载必须遵守的边界。它不创建第二个生产状态源；只读 Editor
//! 的实际资源仍以 `WindowSession`、`DisplayState` 和活动上下文派生规则为准。

/// 右侧上下文面板可以显示的互斥内容。
///
/// 该枚举只描述所有权契约，不代表完整编辑行为。E005 以后新增功能时，只能在当前
/// 聚焦会话内切换这些内容，不能把它们提升为顶层 `DisplaySurface`。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FocusedContextKind {
    /// 文件树和文件/目录引用上下文。
    Files,
    /// 轻量文本编辑上下文。
    Editor,
    /// Markdown 预览上下文。
    MarkdownPreview,
}

/// 一个异步上下文请求的三元身份。
///
/// 异步文件读取、语法高亮、Markdown 渲染或 Diff 往返都必须携带这三个字段：
/// 稳定工作区 ID、防陈旧 generation、以及请求所属的右栏上下文类型。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct AsyncContextKey {
    /// 当前聚焦的稳定 `WindowSession` ID。
    workspace_id: u64,
    /// 进入或切换上下文时递增的代数，用于丢弃旧异步结果。
    generation: u64,
    /// 异步结果所属的右侧上下文类型。
    kind: FocusedContextKind,
}

/// 后续自用效率功能共享的最小上下文所有权模型。
///
/// 该类型故意不出现在生产代码中。它用于证明目标约束：Grid 没有右栏资源；
/// Focused 最多一个右栏上下文；切换工作区会递增 generation 并释放旧资源；
/// 异步结果只有三元身份全部匹配时才能落地。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct SelfUseContextContract {
    /// 当前聚焦工作区；`None` 表示 Grid/Settings 等没有活动上下文的表面。
    focused_workspace_id: Option<u64>,
    /// 当前上下文代数；每次绑定或释放工作区都会递增。
    generation: u64,
    /// 当前唯一右侧上下文；`None` 表示 Grid 或尚未打开右侧内容。
    active_kind: Option<FocusedContextKind>,
}

impl SelfUseContextContract {
    /// 进入一个聚焦工作区，并默认显示 Files 上下文。
    ///
    /// 即使再次聚焦同一个 ID，也会创建新 generation；这样后续异步任务可按用户
    /// 明确动作精确失效，而不是依赖文件路径或列表索引猜测。
    fn focus_workspace(&mut self, workspace_id: u64) -> AsyncContextKey {
        self.focused_workspace_id = Some(workspace_id);
        self.generation = self.generation.wrapping_add(1);
        self.active_kind = Some(FocusedContextKind::Files);
        self.current_key().expect("聚焦后必须存在上下文 key")
    }

    /// 切换右侧上下文类型，并返回新异步身份。
    ///
    /// 未聚焦时不能切换；调用方应先回到 Focused 表面。该边界保证 Grid 不会因为
    /// 用户曾经打开过 Editor 而持有任何文件、语法高亮或 Markdown 资源。
    fn switch_context(&mut self, kind: FocusedContextKind) -> Option<AsyncContextKey> {
        self.focused_workspace_id?;
        self.generation = self.generation.wrapping_add(1);
        self.active_kind = Some(kind);
        self.current_key()
    }

    /// 回到 Grid 或关闭最后一个工作区时释放全部上下文资源。
    fn clear_to_grid(&mut self) {
        self.focused_workspace_id = None;
        self.generation = self.generation.wrapping_add(1);
        self.active_kind = None;
    }

    /// 返回当前唯一异步身份。
    fn current_key(&self) -> Option<AsyncContextKey> {
        Some(AsyncContextKey {
            workspace_id: self.focused_workspace_id?,
            generation: self.generation,
            kind: self.active_kind?,
        })
    }

    /// 返回当前上下文资源数量。
    ///
    /// 结果只能是 0 或 1；任何大于 1 的设计都会说明右侧 Files、Editor、Preview
    /// 被并行常驻，违背 16GB 用户预算和“Focused 单上下文”约束。
    fn active_resource_count(&self) -> usize {
        usize::from(self.focused_workspace_id.is_some() && self.active_kind.is_some())
    }

    /// 判断异步结果是否仍允许落地。
    fn accepts_async_result(&self, key: AsyncContextKey) -> bool {
        self.current_key() == Some(key)
    }
}

#[cfg(test)]
mod tests {
    use super::{FocusedContextKind, SelfUseContextContract};

    /// Grid 态必须是零上下文资源；右侧文件树、编辑器和预览都不能常驻。
    #[test]
    fn grid_owns_zero_context_resources() {
        let state = SelfUseContextContract::default();

        assert_eq!(state.active_resource_count(), 0);
        assert_eq!(state.current_key(), None);
    }

    /// Focused 态最多持有一个右侧上下文，Files、Editor、Preview 互斥切换。
    #[test]
    fn focused_workspace_owns_exactly_one_context_kind() {
        let mut state = SelfUseContextContract::default();

        let files = state.focus_workspace(41);
        assert_eq!(files.kind, FocusedContextKind::Files);
        assert_eq!(state.active_resource_count(), 1);

        let editor = state
            .switch_context(FocusedContextKind::Editor)
            .expect("聚焦态应允许切换到 Editor 上下文");
        assert_eq!(editor.workspace_id, 41);
        assert_eq!(editor.kind, FocusedContextKind::Editor);
        assert_eq!(state.active_resource_count(), 1);

        let preview = state
            .switch_context(FocusedContextKind::MarkdownPreview)
            .expect("聚焦态应允许切换到 Markdown 预览上下文");
        assert_eq!(preview.workspace_id, 41);
        assert_eq!(preview.kind, FocusedContextKind::MarkdownPreview);
        assert_eq!(state.active_resource_count(), 1);
    }

    /// 切换工作区必须使旧工作区的异步结果失效。
    #[test]
    fn switching_workspace_rejects_old_async_result() {
        let mut state = SelfUseContextContract::default();
        let old = state.focus_workspace(41);

        let current = state.focus_workspace(72);

        assert!(!state.accepts_async_result(old));
        assert!(state.accepts_async_result(current));
        assert_eq!(state.active_resource_count(), 1);
    }

    /// 同一工作区切换右侧上下文也必须使旧异步结果失效，防止文件树结果写入编辑器。
    #[test]
    fn switching_context_kind_rejects_old_async_result() {
        let mut state = SelfUseContextContract::default();
        let files = state.focus_workspace(41);

        let editor = state
            .switch_context(FocusedContextKind::Editor)
            .expect("聚焦态应允许切换到 Editor 上下文");

        assert!(!state.accepts_async_result(files));
        assert!(state.accepts_async_result(editor));
    }

    /// 回到 Grid 后必须释放上下文并拒绝所有旧异步结果。
    #[test]
    fn clearing_to_grid_rejects_every_async_result() {
        let mut state = SelfUseContextContract::default();
        let files = state.focus_workspace(41);
        let editor = state
            .switch_context(FocusedContextKind::Editor)
            .expect("聚焦态应允许切换到 Editor 上下文");

        state.clear_to_grid();

        assert_eq!(state.active_resource_count(), 0);
        assert!(!state.accepts_async_result(files));
        assert!(!state.accepts_async_result(editor));
        assert_eq!(state.current_key(), None);
    }

    /// Editor 不能成为顶层展示表面；它必须挂在 Focused 右侧上下文之下。
    #[test]
    fn editor_must_not_become_a_top_level_display_surface() {
        let focus_source = include_str!("workspace_focus.rs");

        assert!(
            !focus_source.contains("DisplaySurface::Editor"),
            "Editor 只能是 Focused 内的 Context 子状态，不能成为第五个顶层 DisplaySurface"
        );
        assert!(
            !focus_source.contains("WorkspaceDisplayState::Editor"),
            "Editor 不能与 Grid/Focused/Review 并列成为工作区展示状态"
        );
    }

    /// 代码仓库只能保留一个顶层展示状态模型，后续功能不得再造第二个 DisplayState。
    #[test]
    fn app_must_not_define_a_second_display_state_model() {
        let mod_source = include_str!("mod.rs");
        let focus_source = include_str!("workspace_focus.rs");
        let main_source = include_str!("../main.rs");

        assert!(
            mod_source.contains("pub mod workspace_focus;"),
            "展示状态模型必须继续由 workspace_focus 模块导出"
        );
        assert_eq!(
            focus_source.matches("struct DisplayState").count(),
            1,
            "workspace_focus 内只能有一个 DisplayState 定义"
        );
        assert!(
            !main_source.contains("struct DisplayState"),
            "main.rs 不得重新定义平行展示状态"
        );
    }
}
