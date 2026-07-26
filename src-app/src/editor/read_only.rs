//! 右侧轻量只读 Editor。
//!
//! 该模块把文件树打开动作绑定到 E005 的 Focused Context：普通文本和 Markdown
//! 只在放大工作区的右栏显示，正文读取沿用 E007 的 1 MiB、UTF-8 和二进制边界。
//! 它刻意不提供输入框、保存按钮或终端注入，避免第一版把只读审查误变成第二个
//! 编辑器；正文按页构建 GPUI 节点，确保极端多行文件不会一次性制造大量布局对象。

use std::path::{Path, PathBuf};

use gpui::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    SharedString, Styled, div, prelude::*, px,
};

use crate::PaneFlowApp;
use crate::app::files_tree;
use crate::app::workspace_focus::{DisplaySurface, FocusedContextKey, FocusedContextKind};
use crate::editor::TextDocumentLoad;

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
                        Ok(document) => ReadOnlyEditorState::Ready {
                            path: result_path.clone(),
                            document,
                            key: editor_key.clone(),
                            page: 0,
                        },
                        Err(error) => ReadOnlyEditorState::Failed {
                            path: result_path,
                            key: editor_key,
                            message: error.user_message(),
                        },
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
                    .child(title),
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

    /// 只读 Editor 正文分页；每一行都是不可交互的文本节点，不存在编辑/保存路径。
    fn render_read_only_editor_body(
        &self,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(state) = self.read_only_editor.as_ref() else {
            return div().into_any_element();
        };
        match state {
            ReadOnlyEditorState::Loading { .. } => editor_message("正在读取文件…", ui),
            ReadOnlyEditorState::Failed { message, .. } => editor_message(message, ui),
            ReadOnlyEditorState::Ready { document, page, .. } => {
                let page_count = document_page_count(document);
                let page = (*page).min(page_count.saturating_sub(1));
                let line_count = document_line_count(document);
                let start = page.saturating_mul(READ_ONLY_EDITOR_PAGE_SIZE);
                let end = (start + READ_ONLY_EDITOR_PAGE_SIZE).min(line_count);
                let mut rows = div()
                    .id("read-only-editor-rows")
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .overflow_x_hidden()
                    .track_scroll(&self.files_tree_scroll);
                if document.text().is_empty() {
                    rows = rows.child(render_editor_line(1, "", ui));
                } else {
                    for (offset, line) in document
                        .text()
                        .lines()
                        .skip(start)
                        .take(end.saturating_sub(start))
                        .enumerate()
                    {
                        rows = rows.child(render_editor_line(start + offset + 1, line, ui));
                    }
                }
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .child(rows)
                    .child(render_editor_pager(page, page_count, ui, cx))
                    .into_any_element()
            }
        }
    }
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
    use super::{READ_ONLY_EDITOR_PAGE_SIZE, ReadOnlyEditorState, document_page_count};
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
}
