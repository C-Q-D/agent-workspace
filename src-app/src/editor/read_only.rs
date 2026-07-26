//! 右侧轻量文件 Editor。
//!
//! 该模块把文件树打开动作绑定到 E005 的 Focused Context：普通文本和 Markdown
//! 只在放大工作区的右栏显示，正文读取沿用 E007 的 1 MiB、UTF-8 和二进制边界。
//! 文本输入沿用共享的 [`TextArea`]，保存仍由宿主按 Context key 和保存序列统一调度，
//! 不会把文件内容注入终端；加载和保存的阻塞 I/O 始终放在后台线程，避免拖慢 GPUI 帧。

use std::path::{Path, PathBuf};

use gpui::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    SharedString, Styled, div, prelude::*, px,
};

use crate::PaneFlowApp;
use crate::app::files_tree;
use crate::app::workspace_focus::{DisplaySurface, FocusedContextKey, FocusedContextKind};
use crate::editor::TextDocumentLoad;
use crate::widgets::text_area::{TextArea, TextAreaMode};

/// 每页最多创建的代码行节点数，和行引用面板保持一致以控制帧成本。
const READ_ONLY_EDITOR_PAGE_SIZE: usize = 200;

/// 右侧只读 Editor 的异步生命周期。
#[derive(Clone, Debug)]
pub(crate) enum ReadOnlyEditorState {
    /// 正在后台读取真实文件；加载期间不创建正文节点。
    Loading {
        /// 请求目标的真实路径。
        path: PathBuf,
        /// 用于丢弃切换工作区或 Context 后的旧结果。
        key: FocusedContextKey,
    },
    /// 已加载的 E007 文档快照和当前分页。
    Ready {
        /// 文件树点击时保存的真实路径。
        path: PathBuf,
        /// 受控文本快照，包含原始字节和指纹但不会写回磁盘。
        document: TextDocumentLoad,
        /// 与快照绑定的 Context 身份。
        key: FocusedContextKey,
        /// 当前页，从零开始并在渲染时再次夹紧。
        page: usize,
        /// 当前编辑正文是否与磁盘基线不同。
        dirty: bool,
        /// 是否有保存任务正在写盘；保存期间仍允许继续编辑。
        saving: bool,
        /// 保存期间用户再次按下保存时只保留一个最新请求；实际写盘严格串行。
        pending_save: Option<String>,
    },
    /// 文件无法安全显示时的降级状态；仍保留外部打开入口。
    Failed {
        /// 加载失败的真实路径。
        path: PathBuf,
        /// 用于丢弃迟到错误的 Context 身份。
        key: FocusedContextKey,
        /// 面向用户的可判别失败原因，不包含文件正文。
        message: String,
    },
}

impl ReadOnlyEditorState {
    /// 返回当前请求的路径，供标题、外部打开和异步结果匹配复用。
    fn path(&self) -> &Path {
        match self {
            Self::Loading { path, .. } | Self::Ready { path, .. } | Self::Failed { path, .. } => {
                path
            }
        }
    }

    /// 返回当前 Context key，避免调用方仅按路径判断异步结果归属。
    fn key(&self) -> &FocusedContextKey {
        match self {
            Self::Loading { key, .. } | Self::Ready { key, .. } | Self::Failed { key, .. } => key,
        }
    }

    /// 只有仍处于同一路径、同一 Context key 的 Loading 状态才能接收后台结果。
    /// 该门禁与 `PaneFlowApp` 的状态清理分开，保证即使旧任务因系统调度延迟返回，
    /// 也不会把正文写入新的工作区或新的 Editor 请求。
    fn accepts_load_result(&self, path: &Path, key: &FocusedContextKey) -> bool {
        matches!(
            self,
            Self::Loading {
                path: current_path,
                key: current_key,
            } if current_path == path && current_key == key
        )
    }
}

impl PaneFlowApp {
    /// 从放大工作区的文件树打开一个真实文本文件到只读 Editor。
    ///
    /// 文件读取始终在 `smol::unblock` 中执行；进入 Editor 会递增 Context 代数并
    /// 丢弃 Files watcher，保证文件树异步结果不能覆盖当前正文。点击目录、Grid 或
    /// 非 Files Context 时直接拒绝，不会创建隐藏的文件读取任务。
    pub(crate) fn open_file_in_context(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        if !self.files_sidebar_open
            || self.workspace_focus.surface() != DisplaySurface::Focused
            || self.workspace_focus.context_kind() != Some(FocusedContextKind::Files)
        {
            return;
        }
        let root = self.files_tree.root.clone();
        if self.workspace_focus.focused_context_key(&root).is_none() {
            return;
        }
        // 文件树只能把普通文件交给 Editor；目录和越界的异步结果都由加载模型拒绝，
        // 这里不做第二套路径分类，避免 UI 与 E007 的真实文件判定分叉。
        if path.is_dir() {
            return;
        }
        if !self
            .workspace_focus
            .activate_context_kind(FocusedContextKind::Editor)
        {
            return;
        }
        let Some(editor_key) = self.workspace_focus.focused_context_key(&root) else {
            return;
        };
        self.files_line_picker = None;
        self.files_watcher = None;
        self.files_event_rx = None;
        self.files_menu_open = None;
        self.files_tree_scroll = gpui::ScrollHandle::new();
        self.clear_read_only_editor_state();
        self.read_only_editor = Some(ReadOnlyEditorState::Loading {
            path: path.clone(),
            key: editor_key.clone(),
        });
        // 新请求会丢弃旧句柄；旧 future 即使已经排队，完成回调仍必须通过下面的
        // path + key 门禁，不能依赖任务取消的时序保证正确性。
        self.read_only_editor_task = None;
        cx.notify();

        let load_path = path.clone();
        let result_path = path.clone();
        let request_root = root.clone();
        let task = cx.spawn(
            async move |this: gpui::WeakEntity<Self>, cx: &mut gpui::AsyncApp| {
                let result = smol::unblock(move || TextDocumentLoad::load(load_path)).await;
                let _ = this.update(cx, |app, cx| {
                    let still_loading = app
                        .read_only_editor
                        .as_ref()
                        .is_some_and(|state| state.accepts_load_result(&result_path, &editor_key));
                    if !app.files_sidebar_open
                        || !still_loading
                        || !app
                            .workspace_focus
                            .accepts_context_key(&editor_key, &request_root)
                    {
                        return;
                    }
                    app.read_only_editor = Some(match result {
                        Ok(document) => {
                            let initial_text = document.text().to_owned();
                            let weak_app = cx.weak_entity();
                            let input_key = editor_key.clone();
                            let input_path = result_path.clone();
                            let input = cx.new(|editor_cx| {
                                let mut text_area = TextArea::new("编辑文件…", editor_cx);
                                text_area.set_mode(TextAreaMode::Document);
                                text_area.set_value(&initial_text, editor_cx);

                                // TextArea 回调在自身 update 内同步触发；必须 defer 到宿主
                                // update 之外，避免嵌套读取/修改 TextArea 实体造成 GPUI 重入。
                                let dirty_weak = weak_app.clone();
                                let dirty_key = input_key.clone();
                                let dirty_path = input_path.clone();
                                text_area.on_change(move |text, _cursor, text_cx| {
                                    let snapshot = text.to_owned();
                                    let weak = dirty_weak.clone();
                                    let key = dirty_key.clone();
                                    let path = dirty_path.clone();
                                    text_cx.defer(move |app_cx| {
                                        let _ = weak.update(app_cx, |app, cx| {
                                            app.update_read_only_editor_dirty(
                                                &snapshot, &path, &key, cx,
                                            );
                                        });
                                    });
                                });

                                let save_weak = weak_app.clone();
                                let save_key = input_key.clone();
                                let save_path = input_path.clone();
                                text_area.on_save(move |text, _window, text_cx| {
                                    let weak = save_weak.clone();
                                    let key = save_key.clone();
                                    let path = save_path.clone();
                                    text_cx.defer(move |app_cx| {
                                        let _ = weak.update(app_cx, |app, cx| {
                                            app.request_read_only_editor_save(text, path, key, cx);
                                        });
                                    });
                                });
                                text_area
                            });
                            app.read_only_editor_input = Some(input);
                            ReadOnlyEditorState::Ready {
                                path: result_path.clone(),
                                document,
                                key: editor_key.clone(),
                                page: 0,
                                dirty: false,
                                saving: false,
                                pending_save: None,
                            }
                        }
                        Err(error) => {
                            app.read_only_editor_input = None;
                            ReadOnlyEditorState::Failed {
                                path: result_path,
                                key: editor_key,
                                message: error.user_message(),
                            }
                        }
                    });
                    // 只有当前请求完成时才清空句柄；旧请求的迟到回调不能误清空新请求。
                    app.read_only_editor_task = None;
                    cx.notify();
                });
            },
        );
        self.read_only_editor_task = Some(task);
    }

    /// 返回文件树并恢复 Files Context；恢复时重新建立 watcher/hydration，避免使用
    /// 已经被 Editor 代数失效的旧异步资源。
    pub(crate) fn close_read_only_editor(&mut self, cx: &mut Context<Self>) {
        if !self.guard_read_only_editor_discard(cx) {
            return;
        }
        self.clear_read_only_editor_state();
        self.files_tree_scroll = gpui::ScrollHandle::new();
        self.files_menu_open = None;
        if self.files_sidebar_open
            && self.workspace_focus.context_kind() == Some(FocusedContextKind::Editor)
            && self
                .workspace_focus
                .activate_context_kind(FocusedContextKind::Files)
            && let Some((root, persisted)) = self.active_context_workspace().map(|workspace| {
                (
                    workspace.workspace_root().to_path_buf(),
                    workspace.files_expanded.clone(),
                )
            })
        {
            self.spawn_files_hydration(root, persisted, cx);
        }
        cx.notify();
    }

    /// 清空只读 Editor，不重新打开 Files；用于进入 Settings/Review、切换工作区或关闭
    /// 右栏等生命周期边界，实际 Context 代数由统一展示状态转换负责推进。
    pub(crate) fn clear_read_only_editor_state(&mut self) {
        self.read_only_editor = None;
        self.read_only_editor_task = None;
        self.read_only_editor_input = None;
        self.read_only_editor_save_task = None;
        self.read_only_editor_save_seq = self.read_only_editor_save_seq.wrapping_add(1);
    }

    /// 判断 Editor 是否仍有用户未明确保存的正文或进行中的写盘任务。
    pub(crate) fn read_only_editor_has_unsaved_changes(&self) -> bool {
        matches!(
            self.read_only_editor.as_ref(),
            Some(ReadOnlyEditorState::Ready { dirty: true, .. })
                | Some(ReadOnlyEditorState::Ready { saving: true, .. })
                | Some(ReadOnlyEditorState::Ready {
                    pending_save: Some(_),
                    ..
                })
        )
    }

    /// 在释放 Editor 前阻止静默丢弃脏缓冲；用户保存成功后可再次执行原动作。
    pub(crate) fn guard_read_only_editor_discard(&mut self, cx: &mut Context<Self>) -> bool {
        if self.read_only_editor_has_unsaved_changes() {
            self.show_toast("文件有未保存修改，请先保存", cx);
            return false;
        }
        true
    }

    /// 根据 TextArea 的最新快照更新脏标记；磁盘基线只在成功保存后替换。
    fn update_read_only_editor_dirty(
        &mut self,
        text: &str,
        path: &Path,
        key: &FocusedContextKey,
        cx: &mut Context<Self>,
    ) {
        let Some(ReadOnlyEditorState::Ready {
            document,
            path: current_path,
            key: current_key,
            dirty,
            ..
        }) = self.read_only_editor.as_mut()
        else {
            return;
        };
        if current_path != path || current_key != key {
            return;
        }
        let next_dirty = text != document.text();
        if *dirty != next_dirty {
            *dirty = next_dirty;
            cx.notify();
        }
    }

    /// 从标题栏保存按钮读取 TextArea 快照；输入回调已经通过同一入口保存。
    fn save_read_only_editor(&mut self, cx: &mut Context<Self>) {
        let Some(input) = self.read_only_editor_input.as_ref() else {
            return;
        };
        let text = input.read(cx).value();
        let Some((path, key)) = self
            .read_only_editor
            .as_ref()
            .and_then(|state| match state {
                ReadOnlyEditorState::Ready { path, key, .. } => Some((path.clone(), key.clone())),
                _ => None,
            })
        else {
            return;
        };
        self.request_read_only_editor_save(text, path, key, cx);
    }

    /// 请求一次文件保存。一个 Editor 同时只允许一个写盘任务；保存期间的新请求
    /// 仅替换 `pending_save`，完成回调再按最新 TextArea 内容串行启动下一次写入。
    fn request_read_only_editor_save(
        &mut self,
        text: String,
        path: PathBuf,
        key: FocusedContextKey,
        cx: &mut Context<Self>,
    ) {
        let root = self.files_tree.root.clone();
        let Some((baseline, saving)) =
            self.read_only_editor
                .as_ref()
                .and_then(|state| match state {
                    ReadOnlyEditorState::Ready {
                        path: current_path,
                        document,
                        key: current_key,
                        saving,
                        ..
                    } if current_path == &path
                        && current_key == &key
                        && self.workspace_focus.accepts_context_key(&key, &root) =>
                    {
                        Some((document.text().to_owned(), *saving))
                    }
                    _ => None,
                })
        else {
            return;
        };

        if saving {
            if let Some(ReadOnlyEditorState::Ready {
                pending_save,
                dirty,
                document,
                ..
            }) = self.read_only_editor.as_mut()
            {
                // 即使用户先改 B、保存、再改回 A，也要把 A 作为最新请求记录，
                // 让完成回调根据真实当前内容决定是否需要第二次写盘。
                *pending_save = Some(text.clone());
                *dirty = text != document.text();
            }
            cx.notify();
            return;
        }

        // 未发生变化时不触碰磁盘，避免无意义的 mtime 变化和 Git 抖动。
        if text == baseline {
            if let Some(ReadOnlyEditorState::Ready {
                dirty,
                pending_save,
                ..
            }) = self.read_only_editor.as_mut()
            {
                *dirty = false;
                *pending_save = None;
            }
            cx.notify();
            return;
        }

        let save_seq = self.read_only_editor_save_seq.wrapping_add(1);
        self.read_only_editor_save_seq = save_seq;
        if let Some(ReadOnlyEditorState::Ready {
            dirty,
            saving,
            pending_save,
            ..
        }) = self.read_only_editor.as_mut()
        {
            *dirty = true;
            *saving = true;
            *pending_save = None;
        }

        let save_path = path.clone();
        let completion_path = path.clone();
        let load_path = path;
        let save_text = text;
        let save_key = key.clone();
        let request_root = root;
        let task = cx.spawn(
            async move |this: gpui::WeakEntity<Self>, cx: &mut gpui::AsyncApp| {
                let result =
                    smol::unblock(move || write_editor_snapshot(&save_path, &save_text, load_path))
                        .await;
                let _ = this.update(cx, |app, cx| {
                    let still_current = app.read_only_editor.as_ref().is_some_and(|state| {
                        matches!(
                            state,
                            ReadOnlyEditorState::Ready {
                                path: current_path,
                                key: current_key,
                                ..
                            } if current_path == &completion_path && current_key == &save_key
                        )
                    }) && app.read_only_editor_save_seq == save_seq
                        && app
                            .workspace_focus
                            .accepts_context_key(&save_key, &request_root);
                    if !still_current {
                        return;
                    }

                    let current_text = app
                        .read_only_editor_input
                        .as_ref()
                        .map(|input| input.read(cx).value())
                        .unwrap_or_default();
                    match result {
                        Ok(document) => {
                            let mut queued_text = None;
                            let mut new_baseline_text = String::new();
                            if let Some(ReadOnlyEditorState::Ready {
                                document: baseline,
                                dirty,
                                saving,
                                pending_save,
                                ..
                            }) = app.read_only_editor.as_mut()
                            {
                                *baseline = document;
                                *saving = false;
                                queued_text = pending_save.take();
                                new_baseline_text = baseline.text().to_owned();
                                *dirty = current_text != baseline.text();
                            }
                            app.read_only_editor_save_task = None;
                            if let Some(queued_text) =
                                queued_save_after_completion(queued_text, &new_baseline_text)
                            {
                                // 只写入用户明确按下保存时排队的快照；完成后继续编辑的
                                // 内容保持 dirty，必须再次显式保存，不能跨过用户边界。
                                app.request_read_only_editor_save(
                                    queued_text,
                                    completion_path.clone(),
                                    save_key,
                                    cx,
                                );
                            } else {
                                app.show_toast("文件已保存", cx);
                            }
                        }
                        Err(message) => {
                            if let Some(ReadOnlyEditorState::Ready {
                                dirty,
                                saving,
                                pending_save,
                                ..
                            }) = app.read_only_editor.as_mut()
                            {
                                *dirty = true;
                                *saving = false;
                                *pending_save = None;
                            }
                            app.read_only_editor_save_task = None;
                            app.show_toast(message, cx);
                        }
                    }
                    cx.notify();
                });
            },
        );
        self.read_only_editor_save_task = Some(task);
        cx.notify();
    }

    /// 在用户明确点击降级页面的外部打开按钮时复用现有编辑器探测链；不会自动把正文
    /// 写入终端，也不会等待外部编辑器退出。
    fn open_read_only_editor_externally(&self) {
        if let Some(state) = self.read_only_editor.as_ref() {
            let _ = crate::editor::open_at_location(state.path(), None, None);
        }
    }

    /// 修改只读 Editor 的分页并重置滚动位置；不改变文档快照。
    fn set_read_only_editor_page(&mut self, page: usize, cx: &mut Context<Self>) {
        if let Some(ReadOnlyEditorState::Ready {
            document,
            page: current,
            ..
        }) = self.read_only_editor.as_mut()
        {
            let page_count = document_page_count(document);
            *current = page.min(page_count.saturating_sub(1));
            self.files_tree_scroll = gpui::ScrollHandle::new();
            cx.notify();
        }
    }

    /// 渲染右侧只读 Editor；按状态只构建加载提示、失败降级或当前页正文。
    pub(crate) fn render_read_only_editor(
        &self,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(state) = self.read_only_editor.as_ref() else {
            return div().into_any_element();
        };
        let title: SharedString =
            files_tree::workspace_relative_path(&self.files_tree.root, state.path()).into();
        let key_is_current = self
            .workspace_focus
            .accepts_context_key(state.key(), &self.files_tree.root);
        let (dirty, saving) = match state {
            ReadOnlyEditorState::Ready { dirty, saving, .. } => (*dirty, *saving),
            _ => (false, false),
        };
        let save_label = if saving {
            "Saving…"
        } else if dirty {
            "Save"
        } else {
            "Saved"
        };
        let header = div()
            .h(px(36.))
            .flex_none()
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(6.))
            .child(
                div()
                    .id("read-only-editor-back")
                    .size(px(22.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .rounded(px(5.))
                    .text_color(ui.muted)
                    .hover(|style| style.bg(crate::app::constants::sidebar_tab_hover_background()))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.close_read_only_editor(cx);
                        cx.stop_propagation();
                    }))
                    .child("‹"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis()
                    .text_size(px(11.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(if key_is_current { ui.text } else { ui.muted })
                    .child(title)
                    .when(dirty, |title| title.child(" •")),
            )
            .child(
                div()
                    .id("read-only-editor-save")
                    .px(px(6.))
                    .py(px(4.))
                    .rounded(px(4.))
                    .text_size(px(10.))
                    .text_color(if dirty { ui.accent } else { ui.muted })
                    .when(dirty || saving, |button| button.cursor_pointer())
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.save_read_only_editor(cx);
                        cx.stop_propagation();
                    }))
                    .child(save_label),
            )
            .child(
                div()
                    .id("read-only-editor-external")
                    .px(px(6.))
                    .py(px(4.))
                    .rounded(px(4.))
                    .cursor_pointer()
                    .text_size(px(10.))
                    .text_color(ui.muted)
                    .hover(|style| style.bg(crate::app::constants::sidebar_tab_hover_background()))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.open_read_only_editor_externally();
                        cx.stop_propagation();
                    }))
                    .child("External"),
            )
            .child(
                div()
                    .id("read-only-editor-close-sidebar")
                    .size(px(22.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .rounded(px(5.))
                    .text_color(ui.muted)
                    .hover(|style| style.bg(crate::app::constants::sidebar_tab_hover_background()))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.close_files_sidebar(cx);
                        cx.stop_propagation();
                    }))
                    .child("×"),
            );

        div()
            .flex()
            .flex_col()
            .size_full()
            .child(header)
            .child(self.render_read_only_editor_body(ui, cx))
            .into_any_element()
    }

    /// 渲染 Editor 正文；Loading/Failed 保留轻量提示，Ready 使用共享 TextArea 实体。
    fn render_read_only_editor_body(
        &self,
        ui: crate::theme::UiColors,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(state) = self.read_only_editor.as_ref() else {
            return div().into_any_element();
        };
        match state {
            ReadOnlyEditorState::Loading { .. } => editor_message("正在读取文件…", ui),
            ReadOnlyEditorState::Failed { message, .. } => editor_message(message, ui),
            ReadOnlyEditorState::Ready { .. } => self
                .read_only_editor_input
                .as_ref()
                .map(|input| {
                    div()
                        .id("read-only-editor-input")
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_h_0()
                        .w_full()
                        .overflow_y_scroll()
                        .child(input.clone())
                        .into_any_element()
                })
                .unwrap_or_else(|| editor_message("正在准备编辑器…", ui)),
        }
    }
}

/// 将编辑器快照写入真实路径并重新读取为新的磁盘基线。
///
/// 该函数集中承载阻塞文件操作，调用方必须在后台执行器中调用；重新读取而不是直接
/// 把输入字符串当作基线，能够让保存完成后的指纹、字节长度和错误分类保持一致。
fn write_editor_snapshot(
    save_path: &Path,
    text: &str,
    load_path: PathBuf,
) -> Result<TextDocumentLoad, String> {
    if !save_path.is_file() {
        return Err("保存文件失败（目标文件不存在或已被删除）".to_string());
    }
    std::fs::write(save_path, text.as_bytes())
        .map_err(|error| format!("保存文件失败（{error}）"))?;
    TextDocumentLoad::load(load_path).map_err(|error| error.user_message())
}

/// 保存完成后只返回“用户明确排队的快照”；完成期间继续输入的正文不应被隐式写盘。
fn queued_save_after_completion(queued_text: Option<String>, new_baseline: &str) -> Option<String> {
    queued_text.filter(|text| text != new_baseline)
}

/// 计算真实文本行数；只遍历 UTF-8 字符边界，不复制正文。
fn document_line_count(document: &TextDocumentLoad) -> usize {
    if document.text().is_empty() {
        1
    } else {
        document.text().lines().count()
    }
}

/// 空文档也保留一页，避免分页器出现零除或无内容页面。
fn document_page_count(document: &TextDocumentLoad) -> usize {
    document_line_count(document).div_ceil(READ_ONLY_EDITOR_PAGE_SIZE)
}

/// 构造单行只读节点；正文转换为拥有所有权的 SharedString，避免把临时文件快照的
/// 借用生命周期带入 GPUI 的静态元素树。
fn render_editor_line(
    line_number: usize,
    line: &str,
    ui: crate::theme::UiColors,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(SharedString::from(format!(
            "read-only-editor-line-{line_number}"
        )))
        .min_h(px(22.))
        .flex_none()
        .flex()
        .items_start()
        .font_family("monospace")
        .text_size(px(11.))
        .text_color(ui.text)
        .child(
            div()
                .w(px(46.))
                .flex_none()
                .pr(px(8.))
                .text_right()
                .text_color(ui.muted)
                .child(line_number.to_string()),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .overflow_hidden()
                .whitespace_nowrap()
                .text_ellipsis()
                .child(SharedString::from(line.to_string())),
        )
}

/// 渲染只读 Editor 的前后翻页按钮。
fn render_editor_pager(
    page: usize,
    page_count: usize,
    ui: crate::theme::UiColors,
    cx: &mut Context<PaneFlowApp>,
) -> AnyElement {
    let previous_enabled = page > 0;
    let next_enabled = page + 1 < page_count;
    div()
        .h(px(32.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .gap(px(10.))
        .text_size(px(10.))
        .text_color(ui.muted)
        .child(
            editor_page_button("read-only-editor-prev", "Previous", previous_enabled, ui).on_click(
                cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    if previous_enabled {
                        this.set_read_only_editor_page(page.saturating_sub(1), cx);
                    }
                    cx.stop_propagation();
                }),
            ),
        )
        .child(format!("{} / {}", page + 1, page_count))
        .child(
            editor_page_button("read-only-editor-next", "Next", next_enabled, ui).on_click(
                cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    if next_enabled {
                        this.set_read_only_editor_page(page.saturating_add(1), cx);
                    }
                    cx.stop_propagation();
                }),
            ),
        )
        .into_any_element()
}

/// 轻量分页按钮；禁用状态不注册动作，只保留可读的页码布局。
fn editor_page_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    ui: crate::theme::UiColors,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px(px(8.))
        .py(px(3.))
        .rounded(px(4.))
        .text_color(if enabled { ui.text } else { ui.muted })
        .when(enabled, |button| {
            button
                .cursor_pointer()
                .hover(|style| style.bg(crate::app::constants::sidebar_tab_hover_background()))
        })
        .child(label)
}

/// 渲染加载/失败提示，并保持外部打开和返回按钮在标题栏可用。
fn editor_message(message: &str, ui: crate::theme::UiColors) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .flex_1()
        .p(px(14.))
        .text_size(px(12.))
        .text_color(ui.muted)
        .child(message.to_string())
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{
        READ_ONLY_EDITOR_PAGE_SIZE, ReadOnlyEditorState, document_page_count,
        queued_save_after_completion, write_editor_snapshot,
    };
    use crate::app::workspace_focus::{FocusedContextKey, FocusedContextKind};
    use crate::editor::TextDocumentLoad;
    use std::path::PathBuf;

    /// 使用真实临时文本验证 Editor 的分页上限，不构造 mock 文档或伪造正文。
    #[test]
    fn real_text_document_pages_are_bounded() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("many-lines.txt");
        let content = (0..(READ_ONLY_EDITOR_PAGE_SIZE * 2 + 1))
            .map(|line| format!("line-{line}"))
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&path, content).expect("应能写入真实文本文件");
        let document = TextDocumentLoad::load(path).expect("真实文本应能加载");

        assert_eq!(document_page_count(&document), 3);
    }

    /// 过期请求必须在状态层被拒绝；不构造 PaneFlowApp 或 mock 文件内容，直接验证
    /// 生产回调使用的精确 path + Context key 合同。
    #[test]
    fn loading_result_requires_exact_path_and_context_key() {
        let path = PathBuf::from("C:/workspace/a.txt");
        let key = FocusedContextKey {
            workspace_id: 7,
            workspace_root: PathBuf::from("C:/workspace"),
            generation: 11,
            kind: FocusedContextKind::Editor,
        };
        let state = ReadOnlyEditorState::Loading {
            path: path.clone(),
            key: key.clone(),
        };

        assert!(state.accepts_load_result(&path, &key));
        assert!(!state.accepts_load_result(PathBuf::from("C:/workspace/b.txt").as_path(), &key));

        let mut other_key = key.clone();
        other_key.generation += 1;
        assert!(!state.accepts_load_result(&path, &other_key));
    }

    /// 保存必须写入真实磁盘并重新建立可读取的基线；不使用内存 mock 掩盖文件系统错误。
    #[test]
    fn real_editor_save_updates_disk_and_reload_baseline() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("editable.txt");
        std::fs::write(&path, b"before").expect("应能写入初始内容");

        let document = write_editor_snapshot(&path, "after\nline", path.clone())
            .expect("真实文件保存后应能重新读取");

        assert_eq!(
            std::fs::read(&path).expect("应能读取保存后的字节"),
            b"after\nline"
        );
        assert_eq!(document.text(), "after\nline");
        assert_eq!(document.raw_bytes(), b"after\nline");
    }

    /// B 保存期间用户排队 C、随后继续编辑 D 时，完成回调必须仍返回 C，不能越过
    /// 显式保存边界把 D 偷偷写入磁盘。
    #[test]
    fn queued_save_keeps_explicit_snapshot_after_later_edit() {
        let queued = queued_save_after_completion(Some("C".to_string()), "B");
        assert_eq!(queued.as_deref(), Some("C"));
        assert_ne!(queued.as_deref(), Some("D"));
    }

    /// 目标在保存前消失时必须返回可展示错误，不能把失败误报为已保存。
    #[test]
    fn real_editor_save_keeps_missing_target_as_error() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("deleted.txt");
        let error = write_editor_snapshot(&path, "content", path.clone())
            .expect_err("不存在的目标不应被静默创建");
        assert!(error.contains("保存文件失败"));
    }
}
