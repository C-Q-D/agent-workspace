//! 聚焦工作区上下文。
//!
//! 本模块把应用级放大状态、稳定会话 ID、文件引用目标终端以及恢复矩阵时的定位
//! 目标收敛为一个进程内状态对象。稳定目录始终从 ID 对应的 `WindowSession`
//! 派生；本模块不复制 root，也不负责 UI、文件扫描或进程生命周期。

use std::path::{Path, PathBuf};

use crate::{PaneFlowApp, SettingsSection};

/// 右侧 Context 的唯一子表面。
///
/// 这些子表面只能挂在 `Focused` 下，不能扩展为新的顶层 `DisplaySurface`；这样
/// Grid、Review 和 Settings 都能在状态层明确表达“没有活动右栏资源”。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FocusedContextKind {
    /// 文件树与文件/目录引用上下文。
    Files,
    /// 轻量只读文本编辑上下文。
    Editor,
    /// Markdown 预览上下文。
    MarkdownPreview,
}

/// 一个异步 Context 请求的稳定身份。
///
/// `workspace_root` 只存在于请求快照中，不复制到 `WindowSession` 或展示状态；调用方
/// 必须从当前稳定会话取得它。四个字段同时匹配才允许后台结果落入 UI，避免相同目录
/// 被多个窗口复用时旧任务串台。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedContextKey {
    /// 创建工作区时分配的稳定会话 ID。
    pub(crate) workspace_id: u64,
    /// 本次读取或渲染所属的稳定工作区根目录快照。
    pub(crate) workspace_root: PathBuf,
    /// Context 生命周期代数；每次绑定、切换或释放都会递增。
    pub(crate) generation: u64,
    /// 请求所属的右侧 Context 子表面。
    pub(crate) kind: FocusedContextKind,
}

/// Focused 内唯一右侧 Context 的纯状态模型。
///
/// 该模型不执行文件扫描、Git、PTY 或 UI 副作用。`PaneFlowApp` 的展示转换统一调用
/// 它来分配代数与失效旧请求；生产资源（文件树、编辑器实体和 watcher）必须以当前
/// key 为门禁，而不能另建一份模式状态。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct FocusedContextState {
    /// 当前聚焦的稳定工作区 ID；Grid/Review/Settings 或无活动 Context 时为空。
    focused_workspace_id: Option<u64>,
    /// 单调递增的 Context 代数；溢出时按 Rust 定义回绕，匹配现有会话计数策略。
    generation: u64,
    /// 当前唯一的右侧子表面；`None` 表示当前 Focused 暂未挂载右栏资源。
    active_kind: Option<FocusedContextKind>,
}

impl FocusedContextState {
    /// 进入一个 Focused workspace，并默认绑定 Files Context。
    pub(crate) fn focus_workspace(&mut self, workspace_id: u64) {
        self.focused_workspace_id = Some(workspace_id);
        self.generation = self.generation.wrapping_add(1);
        self.active_kind = Some(FocusedContextKind::Files);
    }

    /// 在仍处于 Focused 时切换唯一 Context 子表面。
    pub(crate) fn switch_kind(&mut self, kind: FocusedContextKind) -> bool {
        if self.focused_workspace_id.is_none() {
            return false;
        }
        self.generation = self.generation.wrapping_add(1);
        self.active_kind = Some(kind);
        true
    }

    /// 释放当前右栏资源但保留 Focused workspace 身份，供关闭文件栏或切换 Settings 使用。
    pub(crate) fn release_kind(&mut self) {
        // 即使当前已经没有子表面也要推进代数：进入 Review/Settings 的生命周期边界
        // 本身就是一次失效事件，保证此前已经发出的后台结果不会在回到 Focused 后复活。
        self.active_kind = None;
        self.generation = self.generation.wrapping_add(1);
    }

    /// 彻底离开 Focused，释放 workspace 身份与所有右栏资源。
    pub(crate) fn clear_to_grid(&mut self) {
        self.focused_workspace_id = None;
        self.active_kind = None;
        self.generation = self.generation.wrapping_add(1);
    }

    /// 返回当前稳定 workspace ID。
    pub(crate) fn workspace_id(&self) -> Option<u64> {
        self.focused_workspace_id
    }

    /// 返回当前 Context 代数，用于生成后台任务快照。
    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    /// 返回当前 Context 子表面；Grid/Review/Settings 没有活动子表面。
    pub(crate) fn kind(&self) -> Option<FocusedContextKind> {
        self.active_kind
    }

    /// 以调用方提供的稳定 root 生成完整异步 key。
    pub(crate) fn key(&self, workspace_root: &Path) -> Option<FocusedContextKey> {
        self.active_kind?;
        Some(self.key_without_root(workspace_root))
    }

    /// 判断一个后台结果是否仍属于当前 Context。
    ///
    /// root 单独由调用方再次提供，避免展示状态复制会话目录；ID、root、generation、kind
    /// 任一变化都会拒绝旧结果。
    pub(crate) fn accepts(&self, key: &FocusedContextKey, workspace_root: &Path) -> bool {
        self.key(workspace_root).as_ref() == Some(key)
    }

    fn key_without_root(&self, workspace_root: &Path) -> FocusedContextKey {
        FocusedContextKey {
            workspace_id: self
                .focused_workspace_id
                .expect("活动 Context 必须有 workspace ID"),
            workspace_root: workspace_root.to_path_buf(),
            generation: self.generation,
            kind: self.active_kind.expect("活动 Context 必须有子表面"),
        }
    }
}

/// 当前被应用级放大的稳定工作区上下文。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedWorkspaceContext {
    /// 创建工作区时分配的稳定 ID；重命名和索引变化不会改变它。
    workspace_id: u64,
    /// 文件引用应注入的真实终端 Surface；面板尚未绑定时为空。
    terminal_surface_id: Option<u64>,
}

/// 不包含设置覆盖页的工作区展示状态。
///
/// Review 直接携带聚焦上下文，因此类型内部不存在“Review 但没有放大工作区”。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
enum WorkspaceDisplayState {
    /// 动态终端矩阵。
    #[default]
    Grid,
    /// 单个工作区放大，文件引用上下文可用。
    Focused(FocusedWorkspaceContext),
    /// 单个工作区的只读 Git 审查。
    Review(FocusedWorkspaceContext),
}

/// 当前唯一可见的应用级展示状态。
///
/// A016 先建立模型，A017 已建立集中命令；Settings 的 UI 调用方会在 A019 接入，
/// 因此当前允许该分支暂时只由模型测试构造。
#[allow(dead_code)]
#[derive(Clone, Debug, PartialEq, Eq)]
enum VisibleDisplayState {
    /// 矩阵、聚焦或审查中的一个工作区表面。
    Workspace(WorkspaceDisplayState),
    /// 设置页是互斥的可见表面，同时保存关闭后要恢复的确定状态。
    Settings {
        /// 当前设置分区。
        section: SettingsSection,
        /// 关闭设置后恢复的工作区表面；它不能再次是 Settings。
        return_to: WorkspaceDisplayState,
    },
}

/// 用于只读判断当前渲染分支的稳定枚举。
///
/// A018～A019 会逐步把渲染读取迁入该投影。
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DisplaySurface {
    /// 动态终端矩阵。
    Grid,
    /// 单工作区放大。
    Focused,
    /// 当前工作区只读审查。
    Review,
    /// 设置页。
    Settings,
}

/// 所有展示状态写入都必须表达为一个命令。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum DisplayCommand {
    /// 放大或切换到稳定工作区；Review 中切换时继续停留在 Review。
    FocusWorkspace {
        /// 目标工作区稳定 ID。
        workspace_id: u64,
    },
    /// 主动返回动态终端矩阵。
    RestoreGrid,
    /// 进入当前放大工作区的只读 Git 审查。
    EnterReview,
    /// 从 Review 返回同一工作区的放大终端。
    ExitReview,
    /// 打开设置或切换设置分区。
    OpenSettings(SettingsSection),
    /// 关闭设置并恢复打开前的工作区表面。
    CloseSettings,
    /// 最后一个工作区消失时清空活动展示上下文。
    ClearWorkspace,
}

/// 一次受控展示转换是否实际改变了状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DisplayTransition {
    /// 状态发生变化，调用方需要处理相应副作用并重绘。
    Changed,
    /// 命令与当前状态等价，不需要重复执行副作用。
    Unchanged,
}

/// 展示状态转换被拒绝的确定原因。
///
/// A017 的集中转换命令通过该错误返回稳定的拒绝原因。
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DisplayTransitionError {
    /// Review 只能从一个已放大的稳定工作区进入。
    ReviewRequiresFocusedWorkspace,
    /// 当前并不在 Review，不能执行退出 Review。
    ReviewNotOpen,
    /// 当前并未打开设置页，不能执行关闭设置。
    SettingsNotOpen,
    /// Settings 是互斥覆盖页，必须先关闭才能进入或退出不可见的 Review。
    SettingsMustCloseFirst,
    /// 应用级入口引用了不存在的稳定工作区 ID；状态保持不变。
    UnknownWorkspace,
    /// 右侧 Editor 有未保存正文，展示转换必须先保存，避免静默丢失用户修改。
    UnsavedEditorChanges,
}

/// 应用级展示状态的单一模型。
///
/// 矩阵、聚焦、Review 与 Settings 只通过本模型读取和转换，不维护平行模式字段。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DisplayState {
    /// 当前唯一可见表面；内部枚举私有，外部无法拼装非法组合。
    visible: VisibleDisplayState,
    /// 从聚焦态恢复后，矩阵下一帧需要滚动或翻页显示的稳定工作区 ID。
    reveal_workspace_id: Option<u64>,
    /// Focused 内唯一的右侧 Context；非 Focused 表面只保留无活动资源的状态。
    focused_context: FocusedContextState,
}

impl Default for DisplayState {
    fn default() -> Self {
        Self {
            visible: VisibleDisplayState::Workspace(WorkspaceDisplayState::Grid),
            reveal_workspace_id: None,
            focused_context: FocusedContextState::default(),
        }
    }
}

// 部分便利方法只用于状态单元测试；生产路径统一使用 `transition` 命令表。
#[allow(dead_code)]
impl DisplayState {
    /// 返回设置覆盖页之下的工作区状态。
    fn workspace_state(&self) -> &WorkspaceDisplayState {
        match &self.visible {
            VisibleDisplayState::Workspace(state) => state,
            VisibleDisplayState::Settings { return_to, .. } => return_to,
        }
    }

    /// 返回设置覆盖页之下的可变工作区状态。
    fn workspace_state_mut(&mut self) -> &mut WorkspaceDisplayState {
        match &mut self.visible {
            VisibleDisplayState::Workspace(state) => state,
            VisibleDisplayState::Settings { return_to, .. } => return_to,
        }
    }

    /// 返回聚焦或 Review 携带的稳定工作区上下文。
    fn focused_context(&self) -> Option<&FocusedWorkspaceContext> {
        match self.workspace_state() {
            WorkspaceDisplayState::Grid => None,
            WorkspaceDisplayState::Focused(context) | WorkspaceDisplayState::Review(context) => {
                Some(context)
            }
        }
    }

    /// 返回聚焦或 Review 携带的可变稳定工作区上下文。
    fn focused_context_mut(&mut self) -> Option<&mut FocusedWorkspaceContext> {
        match self.workspace_state_mut() {
            WorkspaceDisplayState::Grid => None,
            WorkspaceDisplayState::Focused(context) | WorkspaceDisplayState::Review(context) => {
                Some(context)
            }
        }
    }

    /// 执行唯一的展示状态写入命令。
    ///
    /// 该函数只改变纯状态，不执行文件扫描、Git、PTY 或 UI 副作用。调用方可以先
    /// 根据返回值决定是否执行外部动作；非法转换保留原状态并返回可测试错误。
    pub(crate) fn transition(
        &mut self,
        command: DisplayCommand,
    ) -> Result<DisplayTransition, DisplayTransitionError> {
        match command {
            DisplayCommand::FocusWorkspace { workspace_id } => {
                let was_review = matches!(self.workspace_state(), WorkspaceDisplayState::Review(_));
                let settings_open = matches!(self.visible, VisibleDisplayState::Settings { .. });
                let previous_workspace_id = self.workspace_id();
                let terminal_surface_id = self
                    .focused_context()
                    .filter(|context| context.workspace_id == workspace_id)
                    .and_then(|context| context.terminal_surface_id);
                let context = FocusedWorkspaceContext {
                    workspace_id,
                    terminal_surface_id,
                };
                let next = if matches!(self.workspace_state(), WorkspaceDisplayState::Review(_)) {
                    WorkspaceDisplayState::Review(context)
                } else {
                    WorkspaceDisplayState::Focused(context)
                };
                if self.workspace_state() == &next {
                    return Ok(DisplayTransition::Unchanged);
                }
                *self.workspace_state_mut() = next;
                if was_review || settings_open {
                    // Review 不持有右栏资源；切换 Review 中的 workspace 只更新审查归属，
                    // Settings 同样只更新覆盖页下的返回目标；等回到 Focused 时再由
                    // 统一入口创建新的 Files Context。
                    self.focused_context.release_kind();
                } else if previous_workspace_id != Some(workspace_id) {
                    self.focused_context.focus_workspace(workspace_id);
                }
                self.reveal_workspace_id = None;
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::RestoreGrid => {
                let workspace_id = match self.workspace_state() {
                    WorkspaceDisplayState::Grid => return Ok(DisplayTransition::Unchanged),
                    WorkspaceDisplayState::Focused(context)
                    | WorkspaceDisplayState::Review(context) => context.workspace_id,
                };
                *self.workspace_state_mut() = WorkspaceDisplayState::Grid;
                self.focused_context.clear_to_grid();
                self.reveal_workspace_id = Some(workspace_id);
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::EnterReview => {
                if matches!(self.visible, VisibleDisplayState::Settings { .. }) {
                    return Err(DisplayTransitionError::SettingsMustCloseFirst);
                }
                let next = match self.workspace_state().clone() {
                    WorkspaceDisplayState::Focused(context) => {
                        WorkspaceDisplayState::Review(context)
                    }
                    WorkspaceDisplayState::Review(_) => return Ok(DisplayTransition::Unchanged),
                    WorkspaceDisplayState::Grid => {
                        return Err(DisplayTransitionError::ReviewRequiresFocusedWorkspace);
                    }
                };
                *self.workspace_state_mut() = next;
                // Review 与右侧 Files/Editor/Preview 互斥；旧异步结果必须立即失效。
                self.focused_context.release_kind();
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::ExitReview => {
                if matches!(self.visible, VisibleDisplayState::Settings { .. }) {
                    return Err(DisplayTransitionError::SettingsMustCloseFirst);
                }
                let next = match self.workspace_state().clone() {
                    WorkspaceDisplayState::Review(context) => {
                        self.focused_context.focus_workspace(context.workspace_id);
                        WorkspaceDisplayState::Focused(context)
                    }
                    WorkspaceDisplayState::Grid | WorkspaceDisplayState::Focused(_) => {
                        return Err(DisplayTransitionError::ReviewNotOpen);
                    }
                };
                *self.workspace_state_mut() = next;
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::OpenSettings(section) => match &mut self.visible {
                VisibleDisplayState::Settings {
                    section: current, ..
                } if *current == section => Ok(DisplayTransition::Unchanged),
                VisibleDisplayState::Settings {
                    section: current, ..
                } => {
                    *current = section;
                    Ok(DisplayTransition::Changed)
                }
                VisibleDisplayState::Workspace(_) => {
                    let VisibleDisplayState::Workspace(return_to) = std::mem::replace(
                        &mut self.visible,
                        VisibleDisplayState::Workspace(WorkspaceDisplayState::Grid),
                    ) else {
                        unreachable!("替换前已经匹配 Workspace 分支");
                    };
                    self.visible = VisibleDisplayState::Settings { section, return_to };
                    // Settings 是互斥覆盖页，立刻失效 Files/Editor/Preview 的异步资源。
                    self.focused_context.release_kind();
                    Ok(DisplayTransition::Changed)
                }
            },
            DisplayCommand::CloseSettings => {
                let VisibleDisplayState::Settings { .. } = self.visible else {
                    return Err(DisplayTransitionError::SettingsNotOpen);
                };
                let VisibleDisplayState::Settings { return_to, .. } = std::mem::replace(
                    &mut self.visible,
                    VisibleDisplayState::Workspace(WorkspaceDisplayState::Grid),
                ) else {
                    unreachable!("设置分支已在替换前确认");
                };
                self.visible = VisibleDisplayState::Workspace(return_to);
                match self.workspace_state() {
                    WorkspaceDisplayState::Focused(context) => {
                        self.focused_context.focus_workspace(context.workspace_id);
                    }
                    WorkspaceDisplayState::Review(_) => self.focused_context.release_kind(),
                    WorkspaceDisplayState::Grid => self.focused_context.clear_to_grid(),
                }
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::ClearWorkspace => {
                let changed = !matches!(self.workspace_state(), WorkspaceDisplayState::Grid)
                    || self.reveal_workspace_id.is_some()
                    || self.focused_context.workspace_id().is_some()
                    || self.focused_context.kind().is_some();
                *self.workspace_state_mut() = WorkspaceDisplayState::Grid;
                self.focused_context.clear_to_grid();
                self.reveal_workspace_id = None;
                Ok(if changed {
                    DisplayTransition::Changed
                } else {
                    DisplayTransition::Unchanged
                })
            }
        }
    }

    /// 进入或重定向聚焦工作区。
    ///
    /// 切换到另一个稳定 ID 时必须清除旧终端 Surface，防止把 B 工作区的文件引用
    /// 注入 A 的 CLI。重复对齐同一工作区时保留 Surface，避免无意义地丢失绑定。
    pub(crate) fn focus(&mut self, workspace_id: u64) {
        self.transition(DisplayCommand::FocusWorkspace { workspace_id })
            .expect("聚焦命令在工作区表面和 Settings 返回状态中都合法");
    }

    /// 退出聚焦态并记录矩阵应重新显示的稳定工作区。
    ///
    /// 返回 `false` 表示调用前已经处于矩阵态，调用方无需触发额外关闭或重绘。
    pub(crate) fn restore_grid(&mut self) -> bool {
        matches!(
            self.transition(DisplayCommand::RestoreGrid),
            Ok(DisplayTransition::Changed)
        )
    }

    /// 从已放大的工作区进入只读 Review。
    ///
    /// Grid 和 Settings→Grid 都会被明确拒绝；调用失败时状态保持不变。
    pub(crate) fn enter_review(&mut self) -> Result<(), DisplayTransitionError> {
        self.transition(DisplayCommand::EnterReview).map(|_| ())
    }

    /// 从 Review 返回同一工作区的放大终端。
    pub(crate) fn exit_review(&mut self) -> Result<(), DisplayTransitionError> {
        self.transition(DisplayCommand::ExitReview).map(|_| ())
    }

    /// 打开或切换设置分区，并保存关闭后要恢复的唯一有效工作区表面。
    pub(crate) fn open_settings(&mut self, section: SettingsSection) {
        self.transition(DisplayCommand::OpenSettings(section))
            .expect("打开设置对所有工作区表面都合法");
    }

    /// 关闭设置并恢复打开前的确定工作区表面。
    ///
    /// 返回 `false` 表示设置原本未打开，调用方不需要额外重绘。
    pub(crate) fn close_settings(&mut self) -> bool {
        matches!(
            self.transition(DisplayCommand::CloseSettings),
            Ok(DisplayTransition::Changed)
        )
    }

    /// 工作区集合变化且已无活动项时清空聚焦与恢复目标。
    pub(crate) fn clear(&mut self) {
        self.transition(DisplayCommand::ClearWorkspace)
            .expect("清空工作区上下文在所有展示表面都合法");
    }

    /// 返回当前是否处于应用级聚焦态。
    pub(crate) fn is_focused(&self) -> bool {
        self.focused_context().is_some()
    }

    /// 返回当前唯一可见表面。
    pub(crate) fn surface(&self) -> DisplaySurface {
        match &self.visible {
            VisibleDisplayState::Settings { .. } => DisplaySurface::Settings,
            VisibleDisplayState::Workspace(WorkspaceDisplayState::Grid) => DisplaySurface::Grid,
            VisibleDisplayState::Workspace(WorkspaceDisplayState::Focused(_)) => {
                DisplaySurface::Focused
            }
            VisibleDisplayState::Workspace(WorkspaceDisplayState::Review(_)) => {
                DisplaySurface::Review
            }
        }
    }

    /// 返回当前是否直接显示终端矩阵或聚焦终端。
    ///
    /// Review 与 Settings 都会遮盖终端交互，因此终端专属浮层和动作必须拒绝这两种表面。
    pub(crate) fn terminal_workspace_visible(&self) -> bool {
        matches!(
            self.surface(),
            DisplaySurface::Grid | DisplaySurface::Focused
        )
    }

    /// 返回当前 Settings 分区；其他可见表面返回 `None`。
    pub(crate) fn settings_section(&self) -> Option<SettingsSection> {
        match self.visible {
            VisibleDisplayState::Settings { section, .. } => Some(section),
            VisibleDisplayState::Workspace(_) => None,
        }
    }

    /// 返回当前聚焦工作区的稳定 ID。
    pub(crate) fn workspace_id(&self) -> Option<u64> {
        self.focused_context().map(|context| context.workspace_id)
    }

    /// 为当前 Focused 文件/编辑器 Context 生成稳定异步请求 key。
    ///
    /// Review、Settings 和 Grid 均返回 `None`，调用方不能用 `active_idx` 代替该门禁。
    pub(crate) fn focused_context_key(&self, workspace_root: &Path) -> Option<FocusedContextKey> {
        (self.surface() == DisplaySurface::Focused)
            .then(|| self.focused_context.key(workspace_root))
            .flatten()
    }

    /// 判断后台结果是否仍属于当前 Focused Context。
    pub(crate) fn accepts_context_key(
        &self,
        key: &FocusedContextKey,
        workspace_root: &Path,
    ) -> bool {
        self.surface() == DisplaySurface::Focused
            && self.focused_context.accepts(key, workspace_root)
    }

    /// 切换 Focused 内唯一 Context 子表面；非 Focused 状态拒绝写入。
    pub(crate) fn activate_context_kind(&mut self, kind: FocusedContextKind) -> bool {
        self.surface() == DisplaySurface::Focused && self.focused_context.switch_kind(kind)
    }

    /// 释放 Focused 右栏资源并推进代数，供文件栏/设置/Review 生命周期调用。
    pub(crate) fn release_context_kind(&mut self) {
        self.focused_context.release_kind();
    }

    /// 返回当前 Context 代数，供诊断和精确测试使用。
    pub(crate) fn context_generation(&self) -> u64 {
        self.focused_context.generation()
    }

    /// 返回当前 Focused 子表面种类。
    pub(crate) fn context_kind(&self) -> Option<FocusedContextKind> {
        if self.surface() != DisplaySurface::Focused {
            return None;
        }
        self.focused_context.kind()
    }

    /// 返回文件引用当前绑定的终端 Surface。
    pub(crate) fn terminal_surface_id(&self) -> Option<u64> {
        self.focused_context()
            .and_then(|context| context.terminal_surface_id)
    }

    /// 更新当前聚焦工作区的终端 Surface；矩阵态下忽略陈旧事件。
    pub(crate) fn set_terminal_surface_id(&mut self, surface_id: Option<u64>) {
        if let Some(context) = self.focused_context_mut() {
            context.terminal_surface_id = surface_id;
        }
    }

    /// 取出一次性的矩阵恢复目标，保证后续普通重绘不会反复翻页。
    pub(crate) fn take_reveal_workspace_id(&mut self) -> Option<u64> {
        self.reveal_workspace_id.take()
    }
}

impl PaneFlowApp {
    /// 执行单一展示状态命令；调用方随后直接读取同一个状态对象。
    pub(crate) fn transition_display(
        &mut self,
        command: DisplayCommand,
    ) -> Result<DisplayTransition, DisplayTransitionError> {
        if let DisplayCommand::FocusWorkspace { workspace_id } = &command
            && !self
                .workspaces
                .iter()
                .any(|workspace| workspace.id == *workspace_id)
        {
            return Err(DisplayTransitionError::UnknownWorkspace);
        }
        if self.read_only_editor_has_unsaved_changes()
            && matches!(
                &command,
                DisplayCommand::RestoreGrid
                    | DisplayCommand::EnterReview
                    | DisplayCommand::OpenSettings(_)
                    | DisplayCommand::ClearWorkspace
            )
        {
            return Err(DisplayTransitionError::UnsavedEditorChanges);
        }
        if let DisplayCommand::FocusWorkspace { workspace_id } = &command
            && self.read_only_editor_has_unsaved_changes()
            && self.workspace_focus.workspace_id() != Some(*workspace_id)
        {
            return Err(DisplayTransitionError::UnsavedEditorChanges);
        }
        let previous_surface = self.workspace_focus.surface();
        let previous_workspace_id = self.workspace_focus.workspace_id();
        let transition = self.workspace_focus.transition(command);
        if transition.is_ok() {
            // 只读 Editor 是 Focused + workspace ID 的瞬时 Context；离开 Focused 或切换
            // 稳定 workspace 时必须先丢弃正文快照和 Files watcher，避免旧文件继续占用
            // 16GB 用户的内存，也避免异步结果在新工作区右栏复活。
            let surface = self.workspace_focus.surface();
            let workspace_id = self.workspace_focus.workspace_id();
            if (self.read_only_editor.is_some() || self.read_only_editor_task.is_some())
                && (surface != DisplaySurface::Focused
                    || previous_surface != DisplaySurface::Focused
                    || previous_workspace_id != workspace_id)
            {
                self.clear_read_only_editor_state();
                self.files_watcher = None;
                self.files_event_rx = None;
            }
            // 展示状态是活动上下文的唯一开关：Grid 解除 Git watcher，Focused/Review
            // 只登记稳定 ID 对应的一个仓库。即使命令幂等也重试，允许 Git 准备在
            // 上一次转换之后才异步回填 `git_dir`。
            self.reconcile_active_git_watch();
        }
        transition
    }

    /// 返回当前聚焦 ID 对应的唯一 WindowSession 所属工作区。
    ///
    /// `active_idx` 只是列表导航位置，不能作为文件/Git 上下文身份；即使短暂重排或
    /// 异步回调发生，本方法也只按稳定会话 ID 命中目标。
    pub(crate) fn active_context_workspace(&self) -> Option<&crate::workspace::Workspace> {
        let workspace_id = self.workspace_focus.workspace_id()?;
        self.workspaces
            .iter()
            .find(|workspace| workspace.id == workspace_id)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DisplayCommand, DisplayState, DisplaySurface, DisplayTransition, DisplayTransitionError,
        FocusedContextKind,
    };
    use crate::SettingsSection;
    use std::path::Path;

    /// A015 的第一条红灯在新模型中变为明确拒绝，且失败不改变原状态。
    #[test]
    fn display_state_must_not_allow_review_without_focus() {
        let mut state = DisplayState::default();

        assert_eq!(
            state.enter_review(),
            Err(DisplayTransitionError::ReviewRequiresFocusedWorkspace)
        );
        assert_eq!(state.surface(), DisplaySurface::Grid);
    }

    /// A015 的第二条红灯由互斥可见表面消除，关闭设置后恢复确定的 Review。
    #[test]
    fn display_state_must_not_allow_settings_over_review() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.enter_review().expect("聚焦态应能进入 Review");
        state.open_settings(SettingsSection::General);

        assert_eq!(state.surface(), DisplaySurface::Settings);
        assert_eq!(state.settings_section(), Some(SettingsSection::General));
        assert!(state.close_settings());
        assert_eq!(state.surface(), DisplaySurface::Review);
        assert_eq!(state.workspace_id(), Some(41));
    }

    /// 基础转换和相等性只由一个模型决定，不依赖调用顺序同步平行字段。
    #[test]
    fn display_state_has_deterministic_equality_and_basic_transitions() {
        let mut left = DisplayState::default();
        let mut right = DisplayState::default();
        assert_eq!(left, right);

        left.focus(41);
        right.focus(41);
        assert_eq!(left, right);
        assert_eq!(left.surface(), DisplaySurface::Focused);

        left.enter_review().expect("聚焦态应能进入 Review");
        assert_ne!(left, right);
        left.exit_review().expect("Review 应能返回聚焦终端");
        assert_eq!(left.surface(), right.surface());
        assert_eq!(left.workspace_id(), right.workspace_id());
        assert!(left.context_generation() > right.context_generation());

        left.open_settings(SettingsSection::Appearance);
        left.open_settings(SettingsSection::Terminal);
        assert_eq!(left.settings_section(), Some(SettingsSection::Terminal));
        assert!(left.close_settings());
        assert!(!left.close_settings());
        assert_eq!(left.surface(), right.surface());
        assert_eq!(left.workspace_id(), right.workspace_id());
    }

    /// 表驱动覆盖所有合法命令、幂等结果以及 Review 内切换工作区。
    #[test]
    fn display_transition_table_covers_legal_and_idempotent_paths() {
        let mut state = DisplayState::default();
        let cases = [
            (
                DisplayCommand::RestoreGrid,
                DisplayTransition::Unchanged,
                DisplaySurface::Grid,
            ),
            (
                DisplayCommand::FocusWorkspace { workspace_id: 41 },
                DisplayTransition::Changed,
                DisplaySurface::Focused,
            ),
            (
                DisplayCommand::FocusWorkspace { workspace_id: 41 },
                DisplayTransition::Unchanged,
                DisplaySurface::Focused,
            ),
            (
                DisplayCommand::EnterReview,
                DisplayTransition::Changed,
                DisplaySurface::Review,
            ),
            (
                DisplayCommand::EnterReview,
                DisplayTransition::Unchanged,
                DisplaySurface::Review,
            ),
            (
                DisplayCommand::FocusWorkspace { workspace_id: 72 },
                DisplayTransition::Changed,
                DisplaySurface::Review,
            ),
            (
                DisplayCommand::ExitReview,
                DisplayTransition::Changed,
                DisplaySurface::Focused,
            ),
            (
                DisplayCommand::OpenSettings(SettingsSection::General),
                DisplayTransition::Changed,
                DisplaySurface::Settings,
            ),
            (
                DisplayCommand::OpenSettings(SettingsSection::General),
                DisplayTransition::Unchanged,
                DisplaySurface::Settings,
            ),
            (
                DisplayCommand::OpenSettings(SettingsSection::Terminal),
                DisplayTransition::Changed,
                DisplaySurface::Settings,
            ),
            (
                DisplayCommand::CloseSettings,
                DisplayTransition::Changed,
                DisplaySurface::Focused,
            ),
            (
                DisplayCommand::RestoreGrid,
                DisplayTransition::Changed,
                DisplaySurface::Grid,
            ),
        ];

        for (command, expected_result, expected_surface) in cases {
            assert_eq!(state.transition(command), Ok(expected_result));
            assert_eq!(state.surface(), expected_surface);
        }
        assert_eq!(state.take_reveal_workspace_id(), Some(72));
    }

    /// 非法命令必须返回稳定错误并完整保留调用前状态。
    #[test]
    fn display_transition_table_rejects_illegal_paths_without_mutation() {
        let mut state = DisplayState::default();

        for (command, expected_error) in [
            (
                DisplayCommand::EnterReview,
                DisplayTransitionError::ReviewRequiresFocusedWorkspace,
            ),
            (
                DisplayCommand::ExitReview,
                DisplayTransitionError::ReviewNotOpen,
            ),
            (
                DisplayCommand::CloseSettings,
                DisplayTransitionError::SettingsNotOpen,
            ),
        ] {
            let before = state.clone();
            assert_eq!(state.transition(command), Err(expected_error));
            assert_eq!(state, before);
        }

        state
            .transition(DisplayCommand::OpenSettings(SettingsSection::General))
            .expect("Grid 应能打开设置");
        for command in [DisplayCommand::EnterReview, DisplayCommand::ExitReview] {
            let before = state.clone();
            assert_eq!(
                state.transition(command),
                Err(DisplayTransitionError::SettingsMustCloseFirst)
            );
            assert_eq!(state, before);
        }
    }

    /// 设置可见时，外部生命周期仍可安全切换底层工作区，关闭后显露最新目标。
    #[test]
    fn workspace_lifecycle_can_retarget_under_settings_without_closing_overlay() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.open_settings(SettingsSection::General);

        assert_eq!(
            state.transition(DisplayCommand::FocusWorkspace { workspace_id: 72 }),
            Ok(DisplayTransition::Changed)
        );
        assert_eq!(state.surface(), DisplaySurface::Settings);
        assert_eq!(state.workspace_id(), Some(72));
        assert!(state.close_settings());
        assert_eq!(state.surface(), DisplaySurface::Focused);
        assert_eq!(state.workspace_id(), Some(72));
    }

    /// 工作区生命周期清空命令可在设置页内更新返回状态，但不抢走可见设置页。
    #[test]
    fn clearing_workspace_under_settings_keeps_overlay_and_returns_to_grid() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.open_settings(SettingsSection::General);

        assert_eq!(
            state.transition(DisplayCommand::ClearWorkspace),
            Ok(DisplayTransition::Changed)
        );
        assert_eq!(state.surface(), DisplaySurface::Settings);
        assert!(state.close_settings());
        assert_eq!(state.surface(), DisplaySurface::Grid);
        assert_eq!(state.workspace_id(), None);
    }

    #[test]
    fn switching_workspace_replaces_identity_and_drops_stale_surface() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.set_terminal_surface_id(Some(4101));

        state.focus(72);

        assert_eq!(state.workspace_id(), Some(72));
        assert_eq!(state.terminal_surface_id(), None);
    }

    #[test]
    fn reconciling_same_workspace_preserves_surface_binding() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.set_terminal_surface_id(Some(4101));

        state.focus(41);

        assert_eq!(state.workspace_id(), Some(41));
        assert_eq!(state.terminal_surface_id(), Some(4101));
    }

    #[test]
    fn restoring_grid_is_explicit_and_reveal_is_one_shot() {
        let mut state = DisplayState::default();
        assert!(!state.restore_grid());

        state.focus(41);
        assert!(state.restore_grid());
        assert!(!state.is_focused());
        assert_eq!(state.take_reveal_workspace_id(), Some(41));
        assert_eq!(state.take_reveal_workspace_id(), None);
    }

    /// 用户恢复矩阵后若立即从左栏选择其他工作区，新聚焦必须取消旧矩阵定位请求。
    #[test]
    fn refocusing_after_restore_cancels_stale_grid_reveal() {
        let mut state = DisplayState::default();
        state.focus(41);
        assert!(state.restore_grid());

        state.focus(72);

        assert_eq!(state.workspace_id(), Some(72));
        assert_eq!(state.take_reveal_workspace_id(), None);
    }

    /// 最后一个工作区关闭或恢复结果为空时，清理操作必须释放全部活动上下文。
    #[test]
    fn clearing_focused_workspace_drops_all_active_context() {
        let mut state = DisplayState::default();
        state.focus(41);
        state.set_terminal_surface_id(Some(4101));

        state.clear();

        assert!(!state.is_focused());
        assert_eq!(state.workspace_id(), None);
        assert_eq!(state.terminal_surface_id(), None);
        assert_eq!(state.take_reveal_workspace_id(), None);
    }

    /// Context key 必须随工作区、子表面和生命周期代数一起变化，任何旧 key 都不能
    /// 在 Review、Settings 或切换到同根目录的另一个工作区后重新写入结果。
    #[test]
    fn focused_context_key_rejects_stale_workspace_and_lifecycle_results() {
        let root = Path::new("C:/workspace/repo");
        let mut state = DisplayState::default();
        state.focus(41);

        let files_key = state
            .focused_context_key(root)
            .expect("Focused 默认应绑定 Files Context");
        assert_eq!(files_key.workspace_id, 41);
        assert_eq!(files_key.kind, FocusedContextKind::Files);
        assert!(state.accepts_context_key(&files_key, root));

        assert!(state.activate_context_kind(FocusedContextKind::Editor));
        let editor_key = state
            .focused_context_key(root)
            .expect("Focused Editor 应生成 key");
        assert_ne!(editor_key, files_key);
        assert!(!state.accepts_context_key(&files_key, root));

        state.enter_review().expect("Focused 应能进入 Review");
        assert!(state.focused_context_key(root).is_none());
        assert!(!state.accepts_context_key(&editor_key, root));

        state.exit_review().expect("Review 应能回到 Focused");
        let resumed_key = state
            .focused_context_key(root)
            .expect("返回 Focused 后应创建新 Files key");
        assert_eq!(resumed_key.workspace_id, 41);
        assert_ne!(resumed_key.generation, editor_key.generation);
        assert!(!state.accepts_context_key(&editor_key, root));

        state.open_settings(SettingsSection::General);
        assert!(state.focused_context_key(root).is_none());
        state.close_settings();
        let after_settings_key = state
            .focused_context_key(root)
            .expect("关闭 Settings 返回 Focused 后应重建 key");
        assert_ne!(after_settings_key.generation, resumed_key.generation);

        state.focus(72);
        assert!(!state.accepts_context_key(&after_settings_key, root));
    }
}
