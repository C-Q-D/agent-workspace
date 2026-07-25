//! 聚焦工作区上下文。
//!
//! 本模块把应用级放大状态、稳定工作区目录、文件引用目标终端以及恢复矩阵时的
//! 定位目标收敛为一个进程内状态对象。它不负责 UI、文件扫描或进程生命周期，
//! 只维护这些消费者共同依赖的不变量，避免切换工作区时分别更新多个松散字段。

use crate::{PaneFlowApp, SettingsSection};
use paneflow_config::schema::AppMode;
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
        /// 目标工作区创建时绑定的稳定目录。
        workspace_root: PathBuf,
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
}

/// 应用级展示状态的单一模型。
///
/// 现有矩阵与放大调用方暂时继续使用 [`WorkspaceFocusState`] 别名，但它们实际写入
/// 的已经是本模型。`AppMode` 和 `settings_section` 的旧调用方会在 A017～A019
/// 逐步迁移；兼容期间只能通过只读投影观察本模型，不能直接修改其内部枚举。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DisplayState {
    /// 当前唯一可见表面；内部枚举私有，外部无法拼装非法组合。
    visible: VisibleDisplayState,
    /// 从聚焦态恢复后，矩阵下一帧需要滚动或翻页显示的稳定工作区 ID。
    reveal_workspace_id: Option<u64>,
}

impl Default for DisplayState {
    fn default() -> Self {
        Self {
            visible: VisibleDisplayState::Workspace(WorkspaceDisplayState::Grid),
            reveal_workspace_id: None,
        }
    }
}

/// A016 迁移期兼容名称；旧聚焦调用方实际持有并写入 [`DisplayState`]。
pub(crate) type WorkspaceFocusState = DisplayState;

// A017 已集中全部纯状态写入；Review、Settings 和只读投影会在 A018～A019
// 接入生产调用方，因此部分兼容方法当前允许暂时只由测试使用。
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
            DisplayCommand::FocusWorkspace {
                workspace_id,
                workspace_root,
            } => {
                let terminal_surface_id = self
                    .focused_context()
                    .filter(|context| context.workspace_id == workspace_id)
                    .and_then(|context| context.terminal_surface_id);
                let context = FocusedWorkspaceContext {
                    workspace_id,
                    workspace_root,
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
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::ExitReview => {
                if matches!(self.visible, VisibleDisplayState::Settings { .. }) {
                    return Err(DisplayTransitionError::SettingsMustCloseFirst);
                }
                let next = match self.workspace_state().clone() {
                    WorkspaceDisplayState::Review(context) => {
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
                Ok(DisplayTransition::Changed)
            }
            DisplayCommand::ClearWorkspace => {
                let changed = !matches!(self.workspace_state(), WorkspaceDisplayState::Grid)
                    || self.reveal_workspace_id.is_some();
                *self.workspace_state_mut() = WorkspaceDisplayState::Grid;
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
    pub(crate) fn focus(&mut self, workspace_id: u64, workspace_root: impl Into<PathBuf>) {
        self.transition(DisplayCommand::FocusWorkspace {
            workspace_id,
            workspace_root: workspace_root.into(),
        })
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

    /// 为尚未迁移的 `AppMode` 读取方提供只读投影。
    pub(crate) fn legacy_mode(&self) -> AppMode {
        match self.workspace_state() {
            WorkspaceDisplayState::Review(_) => AppMode::Diff,
            WorkspaceDisplayState::Grid | WorkspaceDisplayState::Focused(_) => AppMode::Cli,
        }
    }

    /// 为尚未迁移的设置读取方提供只读投影。
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

    /// 返回当前聚焦工作区的稳定绑定目录。
    pub(crate) fn workspace_root(&self) -> Option<&Path> {
        self.focused_context()
            .map(|context| context.workspace_root.as_path())
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
    /// 执行单一展示状态命令，并刷新 A020 删除前的旧只读投影。
    ///
    /// `mode` 与 `settings_section` 在本阶段不再接受业务路径直接写入；它们只服务
    /// 尚未迁移的渲染和持久化读取。A020 删除这两个镜像后，本方法只保留命令转发。
    pub(crate) fn transition_display(
        &mut self,
        command: DisplayCommand,
    ) -> Result<DisplayTransition, DisplayTransitionError> {
        let result = self.workspace_focus.transition(command)?;
        self.mode = self.workspace_focus.legacy_mode();
        self.settings_section = self.workspace_focus.settings_section();
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DisplayCommand, DisplaySurface, DisplayTransition, DisplayTransitionError,
        WorkspaceFocusState,
    };
    use crate::SettingsSection;
    use paneflow_config::schema::AppMode;
    use std::path::Path;

    /// A015 的第一条红灯在新模型中变为明确拒绝，且失败不改变原状态。
    #[test]
    fn display_state_must_not_allow_review_without_focus() {
        let mut state = WorkspaceFocusState::default();

        assert_eq!(
            state.enter_review(),
            Err(DisplayTransitionError::ReviewRequiresFocusedWorkspace)
        );
        assert_eq!(state.surface(), DisplaySurface::Grid);
        assert_eq!(state.legacy_mode(), AppMode::Cli);
    }

    /// A015 的第二条红灯由互斥可见表面消除，关闭设置后恢复确定的 Review。
    #[test]
    fn display_state_must_not_allow_settings_over_review() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        state.enter_review().expect("聚焦态应能进入 Review");
        state.open_settings(SettingsSection::General);

        assert_eq!(state.surface(), DisplaySurface::Settings);
        assert_eq!(state.settings_section(), Some(SettingsSection::General));
        assert_eq!(state.legacy_mode(), AppMode::Diff);
        assert!(state.close_settings());
        assert_eq!(state.surface(), DisplaySurface::Review);
        assert_eq!(state.workspace_id(), Some(41));
    }

    /// 基础转换和相等性只由一个模型决定，不依赖调用顺序同步平行字段。
    #[test]
    fn display_state_has_deterministic_equality_and_basic_transitions() {
        let mut left = WorkspaceFocusState::default();
        let mut right = WorkspaceFocusState::default();
        assert_eq!(left, right);

        left.focus(41, r"C:\repo-a");
        right.focus(41, r"C:\repo-a");
        assert_eq!(left, right);
        assert_eq!(left.surface(), DisplaySurface::Focused);

        left.enter_review().expect("聚焦态应能进入 Review");
        assert_ne!(left, right);
        left.exit_review().expect("Review 应能返回聚焦终端");
        assert_eq!(left, right);

        left.open_settings(SettingsSection::Appearance);
        left.open_settings(SettingsSection::Terminal);
        assert_eq!(left.settings_section(), Some(SettingsSection::Terminal));
        assert!(left.close_settings());
        assert!(!left.close_settings());
        assert_eq!(left, right);
    }

    /// 表驱动覆盖所有合法命令、幂等结果以及 Review 内切换工作区。
    #[test]
    fn display_transition_table_covers_legal_and_idempotent_paths() {
        let mut state = WorkspaceFocusState::default();
        let cases = [
            (
                DisplayCommand::RestoreGrid,
                DisplayTransition::Unchanged,
                DisplaySurface::Grid,
            ),
            (
                DisplayCommand::FocusWorkspace {
                    workspace_id: 41,
                    workspace_root: r"C:\repo-a".into(),
                },
                DisplayTransition::Changed,
                DisplaySurface::Focused,
            ),
            (
                DisplayCommand::FocusWorkspace {
                    workspace_id: 41,
                    workspace_root: r"C:\repo-a".into(),
                },
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
                DisplayCommand::FocusWorkspace {
                    workspace_id: 72,
                    workspace_root: r"C:\repo-b".into(),
                },
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
        let mut state = WorkspaceFocusState::default();

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
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
        state.open_settings(SettingsSection::General);

        assert_eq!(
            state.transition(DisplayCommand::FocusWorkspace {
                workspace_id: 72,
                workspace_root: r"C:\repo-b".into(),
            }),
            Ok(DisplayTransition::Changed)
        );
        assert_eq!(state.surface(), DisplaySurface::Settings);
        assert_eq!(state.workspace_id(), Some(72));
        assert!(state.close_settings());
        assert_eq!(state.surface(), DisplaySurface::Focused);
        assert_eq!(state.workspace_root(), Some(Path::new(r"C:\repo-b")));
    }

    /// 工作区生命周期清空命令可在设置页内更新返回状态，但不抢走可见设置页。
    #[test]
    fn clearing_workspace_under_settings_keeps_overlay_and_returns_to_grid() {
        let mut state = WorkspaceFocusState::default();
        state.focus(41, r"C:\repo-a");
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
