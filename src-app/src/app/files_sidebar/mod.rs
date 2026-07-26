//! Docked Files right sidebar (PRD `prd-files-tree-sidebar-2026-Q3`, EP-001).
//!
//! Mirrors the agent-sessions sidebar (`sessions_sidebar.rs`): a
//! `flex_shrink_0` child of the root `flex_row`, toggled by the tab-bar Files
//! button via `PaneEvent::ToggleFilesSidebar`, mutually exclusive with the
//! sessions sidebar (one right column). Renders a lazily-expanded,
//! folders-first tree of the active workspace's `cwd`. Text rows open in the
//! Focused-only read-only Editor; Markdown keeps its drag-to-pane affordance,
//! while file/line references remain explicit context-menu actions.
//!
//! This module holds the state mutations (open/close, re-root, expand/collapse,
//! open-file) + the container render; the header/body/row rendering lives
//! in `view.rs`, and the pure tree model + fs helpers in `files_tree.rs`.

mod context_menu;
mod keyboard;
mod line_picker;
mod row;
mod view;

pub(crate) use line_picker::FileLinePickerState;
mod watch;

use std::path::Path;

use gpui::{
    AnyElement, Context, CursorStyle, Focusable, InteractiveElement, IntoElement, MouseButton,
    MouseDownEvent, ParentElement, Pixels, Styled, Window, div, prelude::*, px,
};

use crate::app::files_tree::{self, FilesTreeState};
use crate::app::ipc_handler::find_terminal_by_surface_id;
use crate::app::workspace_focus::{DisplaySurface, FocusedContextKind};
use crate::reference_formatter::{ReferenceFormat, ReferenceRequest, format_reference};
use crate::{PaneFlowApp, ToggleFilesSidebar};

/// Files Context 首次打开时的默认宽度；用户拖拽后的宽度只保留在本次应用会话。
pub(crate) const FILES_SIDEBAR_WIDTH: f32 = 300.;
/// 用户拖拽时的最小宽度；默认 300px 仍保留，避免升级后首次打开突然变宽。
pub(crate) const FILES_SIDEBAR_MIN_WIDTH: f32 = 320.;
/// 右侧 Context 不得超过当前窗口宽度的 60%。
const FILES_SIDEBAR_MAX_VIEWPORT_RATIO: f32 = 0.6;
pub(super) const ROW_HEIGHT: Pixels = px(28.);
/// Per-depth indentation added to the row's left padding.
pub(super) const INDENT_STEP: f32 = 12.;
/// Extra opacity knock-down for gitignored / hidden rows (US-004 second tier).
pub(super) const DIMMED_OPACITY: f32 = 0.55;

impl PaneFlowApp {
    /// 根据当前窗口宽度限制右栏可用的最大值。
    pub(crate) fn max_files_sidebar_width(viewport_width: f32) -> f32 {
        (viewport_width.max(0.) * FILES_SIDEBAR_MAX_VIEWPORT_RATIO).max(1.)
    }

    /// 限制窗口变化后的已有宽度；不强制应用拖拽最小值，以保留 300px 默认值。
    pub(crate) fn clamp_files_sidebar_width(width: f32, viewport_width: f32) -> f32 {
        width
            .max(0.)
            .min(Self::max_files_sidebar_width(viewport_width))
    }

    /// 限制用户拖拽产生的宽度，确保右栏不会被拖到难以操作的窄条。
    pub(crate) fn clamp_files_sidebar_drag_width(width: f32, viewport_width: f32) -> f32 {
        let max_width = Self::max_files_sidebar_width(viewport_width);
        let min_width = FILES_SIDEBAR_MIN_WIDTH.min(max_width);
        width.clamp(min_width, max_width)
    }

    /// 在右栏左边缘建立一次拖拽锚点。
    pub(crate) fn begin_files_sidebar_resize(&mut self, cursor_x: f32) {
        if self.files_sidebar_open {
            self.files_sidebar_resize = Some((cursor_x, self.files_sidebar_width));
        }
    }

    /// 根据鼠标横向位移调整右栏宽度；右栏停靠在窗口右侧，向左拖会变宽。
    pub(crate) fn drag_files_sidebar_resize(
        &mut self,
        cursor_x: f32,
        viewport_width: f32,
        cx: &mut Context<Self>,
    ) {
        if let Some((anchor_x, anchor_width)) = self.files_sidebar_resize {
            let delta = anchor_x - cursor_x;
            self.files_sidebar_width =
                Self::clamp_files_sidebar_drag_width(anchor_width + delta, viewport_width);
            cx.notify();
        }
    }

    /// 结束右栏拖拽；鼠标释放或模式切换都会调用该入口。
    pub(crate) fn end_files_sidebar_resize(&mut self, cx: &mut Context<Self>) -> bool {
        if self.files_sidebar_resize.take().is_some() {
            cx.notify();
            true
        } else {
            false
        }
    }

    /// 返回当前文件面板所属工作区的引用策略；索引失效时使用公共格式。
    pub(super) fn active_files_reference_format(&self) -> ReferenceFormat {
        self.workspaces
            .get(self.active_idx)
            .map_or(ReferenceFormat::Common, |workspace| {
                workspace.reference_format
            })
    }

    /// 更新当前工作区的引用策略并立即持久化，不影响其他工作区。
    pub(super) fn set_active_files_reference_format(
        &mut self,
        format: ReferenceFormat,
        cx: &mut Context<Self>,
    ) {
        let Some(workspace) = self.workspaces.get_mut(self.active_idx) else {
            return;
        };
        if workspace.reference_format == format {
            return;
        }
        workspace.reference_format = format;
        self.save_session(cx);
        cx.notify();
    }

    /// 统一格式化右键路径与行选择引用，避免两个入口产生不同 CLI 文本。
    pub(super) fn format_files_reference(
        &self,
        target_path: &Path,
        is_directory: bool,
        lines: Option<(usize, usize)>,
    ) -> String {
        format_reference(
            self.active_files_reference_format(),
            ReferenceRequest {
                workspace_root: &self.files_tree.root,
                target_path,
                is_directory,
                lines,
            },
        )
    }

    /// 把已经格式化的文件引用安全预填到当前放大工作区绑定终端。
    ///
    /// `inject_text` 会尊重 bracketed paste，但绝不追加回车；返回值表示目标终端
    /// 是否仍然存在，调用方据此显示成功或失效提示。
    pub(crate) fn inject_files_reference(
        &mut self,
        reference: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(terminal) = self
            .workspace_focus
            .terminal_surface_id()
            .and_then(|surface_id| find_terminal_by_surface_id(&self.workspaces, surface_id, cx))
        else {
            return false;
        };
        terminal.read(cx).inject_text(&format!("{reference} "));
        terminal.read(cx).focus_handle(cx).focus(window, cx);
        true
    }

    /// 记录活动工作区当前终端，供文件/目录引用发送回正确 CLI 对话。
    fn capture_active_files_surface(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<u64> {
        self.workspaces
            .get(self.active_idx)
            .and_then(|ws| ws.root.as_ref())
            .and_then(|root| root.focused_pane(window, cx))
            .and_then(|pane| pane.read(cx).active_terminal_opt())
            .map(|terminal| terminal.entity_id().as_u64())
    }

    /// 无窗口上下文时使用活动工作区第一个窗格的当前终端作为文件引用目标。
    fn capture_active_files_surface_fallback(&self, cx: &Context<Self>) -> Option<u64> {
        self.workspaces
            .get(self.active_idx)
            .and_then(|ws| ws.root.as_ref())
            .and_then(|root| root.first_leaf())
            .and_then(|pane| pane.read(cx).active_terminal_opt())
            .map(|terminal| terminal.entity_id().as_u64())
    }

    /// 为应用级放大的活动工作区自动打开或重定向文件树。
    ///
    /// 该入口不会把焦点移到文件树，确保用户点击放大后可以直接继续操作终端。
    pub(crate) fn open_files_sidebar_for_maximized_workspace(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let surface_id = self.capture_active_files_surface(window, cx);
        self.workspace_focus.set_terminal_surface_id(surface_id);
        if self.files_sidebar_open {
            self.reroot_files_tree(cx);
        } else {
            self.toggle_files_sidebar(cx);
        }
    }

    /// 在 IPC、异步目录选择等没有 `Window` 的入口中重定向放大工作区文件树。
    pub(crate) fn retarget_files_sidebar_without_window(&mut self, cx: &mut Context<Self>) {
        let surface_id = self.capture_active_files_surface_fallback(cx);
        self.workspace_focus.set_terminal_surface_id(surface_id);
        if self.files_sidebar_open {
            self.reroot_files_tree(cx);
        } else {
            self.toggle_files_sidebar(cx);
        }
    }

    /// Toggle the Files sidebar. Opening resolves the active workspace's `cwd`
    /// to the tree root, reads + auto-expands it, and closes the sessions
    /// sidebar (mutual exclusion). Re-clicking closes and releases the tree.
    pub(crate) fn handle_toggle_files_sidebar(
        &mut self,
        _: &ToggleFilesSidebar,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 第一版把文件树定义为放大工作区的上下文面板；矩阵状态不允许手动挂载，
        // 避免右侧目录与多个同时可见终端之间产生含糊归属。
        if !matches!(self.workspace_focus.surface(), DisplaySurface::Focused) {
            if self.files_sidebar_open {
                self.close_files_sidebar(cx);
            }
            return;
        }
        if !self.files_sidebar_open {
            let surface_id = self.capture_active_files_surface(window, cx);
            self.workspace_focus.set_terminal_surface_id(surface_id);
        }
        self.toggle_files_sidebar(cx);
        if self.files_sidebar_open {
            self.files_focus.focus(window, cx);
        }
    }

    pub(crate) fn toggle_files_sidebar(&mut self, cx: &mut Context<Self>) {
        if self.files_sidebar_open {
            self.close_files_sidebar(cx);
            return;
        }
        let Some((root, persisted)) = self.active_context_workspace().map(|workspace| {
            (
                workspace.workspace_root().to_path_buf(),
                workspace.files_expanded.clone(),
            )
        }) else {
            return;
        };
        // US-007: restore this workspace's expansion (held on the Workspace,
        // so it survives a previous close within the session and a restart).

        // Mutual exclusion: only one right column is ever visible.
        if self.agent_sessions.sessions_sidebar_open
            || self.agent_sessions.sessions_sidebar_animation.is_some()
        {
            self.close_sessions_sidebar_immediate(cx);
        }
        // Floating dropdowns would paint over the docked panel.
        self.dismiss_transient_surfaces();

        self.set_files_sidebar_open(true, cx);
        // Files 是 Focused 内唯一的右侧 Context；切换到它会分配新的异步代数。
        if !self
            .workspace_focus
            .activate_context_kind(FocusedContextKind::Files)
        {
            self.set_files_sidebar_open(false, cx);
            return;
        }
        self.files_tree_scroll = gpui::ScrollHandle::new();
        self.files_selected = 0;
        // US-018: hydrate the tree + install non-recursive watches OFF the
        // render thread. A root shell paints this frame; `sync_files_expansion`
        // runs (and reconciles stale persisted paths back into `session.json`)
        // once hydration lands.
        self.spawn_files_hydration(root, persisted, cx);
    }

    /// Close the sidebar and release the per-open tree cache + watcher. The
    /// per-workspace expansion lives on the `Workspace`, so it is NOT reset
    /// here (US-007) - reopening restores it.
    pub(crate) fn close_files_sidebar(&mut self, cx: &mut Context<Self>) {
        // US-005: drop the watch + its channel while closed.
        self.files_watcher = None;
        self.files_event_rx = None;
        self.clear_read_only_editor_state();
        // Close any open row context menu so it can't outlive the tree.
        self.files_menu_open = None;
        self.files_sidebar_resize = None;
        self.workspace_focus.release_context_kind();
        self.set_files_sidebar_open(false, cx);
    }

    /// 立即关闭并释放文件树，供互斥的聚焦审查界面接管右侧上下文。
    ///
    /// 普通用户关闭保留宽度动画；模式切换不能等待动画结束，否则 Diff 已显示时
    /// 旧目录仍会短暂存在，形成错误的双重工作区归属。
    pub(crate) fn close_files_sidebar_immediate(&mut self, cx: &mut Context<Self>) {
        self.files_sidebar_open = false;
        self.files_sidebar_animation = None;
        self.files_sidebar_resize = None;
        self.clear_read_only_editor_state();
        self.workspace_focus.release_context_kind();
        self.clear_files_sidebar_state();
        cx.notify();
    }

    fn files_sidebar_width_at(&self, now: std::time::Instant) -> f32 {
        if let Some(animation) = self.files_sidebar_animation {
            animation.width_at(now)
        } else if self.files_sidebar_open {
            self.files_sidebar_width
        } else {
            0.
        }
    }

    pub(crate) fn rendered_files_sidebar_width(&mut self, window: &mut Window) -> f32 {
        self.files_sidebar_width = Self::clamp_files_sidebar_width(
            self.files_sidebar_width,
            f32::from(window.viewport_size().width),
        );
        let now = std::time::Instant::now();
        if let Some(animation) = self.files_sidebar_animation {
            if animation.is_finished(now) {
                self.files_sidebar_animation = None;
                if !self.files_sidebar_open {
                    self.clear_files_sidebar_state();
                }
                animation.to_width
            } else {
                window.request_animation_frame();
                animation.width_at(now)
            }
        } else if self.files_sidebar_open {
            self.files_sidebar_width
        } else {
            0.
        }
    }

    fn set_files_sidebar_open(&mut self, open: bool, cx: &mut Context<Self>) {
        let now = std::time::Instant::now();
        let from_width = self.files_sidebar_width_at(now);
        self.files_sidebar_open = open;
        let to_width = if open { self.files_sidebar_width } else { 0. };

        self.files_sidebar_animation =
            if (from_width - to_width).abs() > crate::PRIMARY_SIDEBAR_MIN_ANIMATION_DELTA {
                Some(crate::SidebarWidthAnimation {
                    from_width,
                    to_width,
                    started_at: now,
                })
            } else {
                None
            };

        if !open && self.files_sidebar_animation.is_none() {
            self.clear_files_sidebar_state();
        }
        cx.notify();
    }

    fn clear_files_sidebar_state(&mut self) {
        self.files_tree = FilesTreeState::default();
        self.files_line_picker = None;
        self.clear_read_only_editor_state();
        self.files_watcher = None;
        self.files_event_rx = None;
        self.files_menu_open = None;
        self.files_sidebar_resize = None;
        self.workspace_focus.set_terminal_surface_id(None);
        self.files_selected = 0;
    }

    /// Re-root the tree on the active workspace's `cwd` when it changed while
    /// the sidebar is open (US-002 workspace-switch). No-op when closed or when
    /// the root is unchanged. Restores the new workspace's expansion (US-007)
    /// and re-targets the watcher (US-005).
    pub(crate) fn reroot_files_tree(&mut self, cx: &mut Context<Self>) {
        if !self.files_sidebar_open {
            return;
        }
        let Some((root, persisted)) = self.active_context_workspace().map(|workspace| {
            (
                workspace.workspace_root().to_path_buf(),
                workspace.files_expanded.clone(),
            )
        }) else {
            return;
        };
        let workspace_id = self.workspace_focus.workspace_id();
        if self.files_tree.root == root && self.files_tree.owner_workspace_id == workspace_id {
            return;
        }
        // 行选择状态只属于原 workspaceRoot；切换放大目标时不得保留旧文件视图。
        self.files_line_picker = None;
        // US-018: re-root off the render thread.
        self.spawn_files_hydration(root, persisted, cx);
    }

    /// Expand or collapse a directory. First expand reads its listing (lazy,
    /// cached thereafter); when the live watcher is unavailable (US-006), every
    /// expand re-reads so manual navigation stays current without push updates.
    /// Reads are synchronous on the interaction (not the render path) per the
    /// PRD's "start synchronous" decision. Mirrors the expansion into the
    /// workspace + persists it (US-007).
    fn toggle_dir(&mut self, path: &Path, cx: &mut Context<Self>) {
        if self.files_tree.expanded.contains(path) {
            self.files_tree.expanded.remove(path);
            self.unwatch_files_dir(path);
        } else {
            self.files_tree.expanded.insert(path.to_path_buf());
            self.watch_files_dir(path);
            let stale =
                self.files_watcher.is_none() || !self.files_tree.children.contains_key(path);
            if stale {
                let listing = files_tree::read_dir_sorted(&self.files_tree.root, path);
                self.files_tree.children.insert(path.to_path_buf(), listing);
            }
        }
        self.sync_files_expansion();
        self.clamp_files_selection();
        self.save_session(cx);
        cx.notify();
    }

    /// Render the docked Files sidebar. Only called when `files_sidebar_open`.
    pub(crate) fn render_files_sidebar(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let ui = crate::theme::ui_colors();
        let theme = crate::theme::active_theme();
        div()
            .id("files-sidebar")
            .flex()
            .flex_col()
            .relative()
            .w(px(self.files_sidebar_width))
            .flex_shrink_0()
            .h_full()
            .track_focus(&self.files_focus)
            .on_key_down(cx.listener(Self::handle_files_sidebar_key_down))
            // Match the app's other navigation rails: optional native material
            // on Windows, platform default on macOS, and a light/dark tint on Linux.
            .bg(crate::app::constants::cockpit_chrome_background(
                theme.title_bar_background,
                window.is_window_active(),
                self.cached_config.cockpit_chrome_material_enabled(),
            ))
            .child(
                // 细长的左边缘命中区让拖拽不必精准点在 1px 边框上；实际位移由
                // 主内容的全高 on_mouse_move 捕获，因此光标离开边缘后仍可连续调整。
                div()
                    .id("files-sidebar-resize")
                    .absolute()
                    .left(px(-3.))
                    .top_0()
                    .bottom_0()
                    .w(px(7.))
                    .cursor(CursorStyle::ResizeLeftRight)
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                            this.begin_files_sidebar_resize(f32::from(event.position.x));
                            cx.stop_propagation();
                        }),
                    ),
            )
            .when(self.read_only_editor.is_some(), |panel| {
                panel.child(self.render_read_only_editor(ui, cx))
            })
            .when(self.read_only_editor.is_none(), |panel| {
                panel
                    .child(self.files_sidebar_header(ui, cx))
                    .child(self.files_reference_format_selector(ui, cx))
                    .child(self.files_sidebar_body(ui, cx))
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{FILES_SIDEBAR_MIN_WIDTH, PaneFlowApp};

    /// 右栏最大宽度始终按窗口宽度的 60% 计算。
    #[test]
    fn files_sidebar_max_width_uses_viewport_ratio() {
        assert_eq!(PaneFlowApp::max_files_sidebar_width(1200.0), 720.0);
        assert_eq!(PaneFlowApp::max_files_sidebar_width(0.0), 1.0);
    }

    /// 窗口变窄只收缩已有宽度；默认 300px 不会被无故升级为拖拽下限。
    #[test]
    fn files_sidebar_width_clamps_without_forcing_drag_floor() {
        assert_eq!(PaneFlowApp::clamp_files_sidebar_width(300.0, 1200.0), 300.0);
        assert_eq!(PaneFlowApp::clamp_files_sidebar_width(900.0, 1200.0), 720.0);
    }

    /// 用户拖拽时应用 320px 下限以及 60% 上限；极窄窗口以可用最大值为准。
    #[test]
    fn files_sidebar_drag_width_is_bounded() {
        assert_eq!(
            PaneFlowApp::clamp_files_sidebar_drag_width(100.0, 1200.0),
            FILES_SIDEBAR_MIN_WIDTH
        );
        assert_eq!(
            PaneFlowApp::clamp_files_sidebar_drag_width(900.0, 1200.0),
            720.0
        );
        let narrow = PaneFlowApp::clamp_files_sidebar_drag_width(100.0, 400.0);
        assert!(
            (narrow - 240.0).abs() < 0.01,
            "unexpected narrow width: {narrow}"
        );
    }
}
