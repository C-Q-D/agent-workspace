//! 文件树内的真实文件只读行选择器。
//!
//! 文件读取始终在后台线程完成，并受字节上限与文本格式检查约束；界面按页渲染，
//! 避免大文件把全部行同时转换为 GPUI 节点。这里只维护路径和行号范围，不向模型
//! 或终端复制文件正文。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpui::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    SharedString, Styled, div, prelude::*, px,
};

use crate::PaneFlowApp;
use crate::editor::{MAX_TEXT_DOCUMENT_BYTES, TextDocumentLoad};

/// 只读选择器允许加载的最大文件字节数。
const MAX_LINE_PICKER_BYTES: u64 = MAX_TEXT_DOCUMENT_BYTES;
/// 每页最多创建的行节点数，限制单帧布局成本。
const LINE_PICKER_PAGE_SIZE: usize = 200;

/// 已加载的真实文本文件及当前连续选择范围。
#[derive(Debug, Clone)]
pub(crate) struct FileLineDocument {
    /// 文件绝对路径，用于后续生成 workspaceRoot 相对引用。
    path: PathBuf,
    /// 去除 CRLF 行尾后的真实文本行；正文不会写入终端。
    lines: Arc<Vec<String>>,
    /// 普通点击建立的 1-based 锚点。
    anchor_line: Option<usize>,
    /// 规范化后的 1-based 闭区间。
    selection: Option<(usize, usize)>,
    /// 当前分页，始终在渲染和切页时夹紧。
    page: usize,
    /// 加载完成时的文件元数据，用于确认前检测行号漂移风险。
    stamp: FileLineStamp,
}

/// 足以检测常规保存/替换的轻量文件版本标记。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileLineStamp {
    /// 文件字节长度。
    len: u64,
    /// 文件系统提供的最后修改时间；不支持时为 `None`。
    modified: Option<std::time::SystemTime>,
}

impl FileLineStamp {
    /// 从真实文件元数据构建版本标记。
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        Self {
            len: metadata.len(),
            modified: metadata.modified().ok(),
        }
    }
}

impl FileLineDocument {
    /// 创建尚未选择任何行的只读文档。
    fn new(path: PathBuf, lines: Vec<String>, stamp: FileLineStamp) -> Self {
        Self {
            path,
            lines: Arc::new(lines),
            anchor_line: None,
            selection: None,
            page: 0,
            stamp,
        }
    }

    /// 返回页数；空文件仍保留一页空状态。
    fn page_count(&self) -> usize {
        self.lines.len().max(1).div_ceil(LINE_PICKER_PAGE_SIZE)
    }

    /// 普通点击重置锚点，Shift+点击从既有锚点扩展连续范围。
    fn select_line(&mut self, line: usize, extend: bool) {
        if self.lines.is_empty() {
            return;
        }
        let line = line.clamp(1, self.lines.len());
        if extend && let Some(anchor) = self.anchor_line {
            self.selection = Some((anchor.min(line), anchor.max(line)));
        } else {
            self.anchor_line = Some(line);
            self.selection = Some((line, line));
        }
    }

    /// 切换分页并夹紧到真实页数。
    fn set_page(&mut self, page: usize) {
        self.page = page.min(self.page_count().saturating_sub(1));
    }

    /// 确认磁盘文件仍与加载完成时一致，避免发送已经漂移的行号。
    fn is_current_on_disk(&self) -> bool {
        std::fs::metadata(&self.path)
            .map(|metadata| FileLineStamp::from_metadata(&metadata) == self.stamp)
            .unwrap_or(false)
    }
}

/// 行选择器异步加载生命周期。
#[derive(Debug, Clone)]
pub(crate) enum FileLinePickerState {
    /// 后台正在读取目标文件。
    Loading { path: PathBuf },
    /// 已加载且可选择真实行号。
    Ready(FileLineDocument),
    /// 文件无法安全读取；错误信息直接显示在右侧面板。
    Failed { path: PathBuf, message: String },
}

impl FileLinePickerState {
    /// 返回当前状态对应的文件路径，供标题和异步防陈旧检查使用。
    fn path(&self) -> &Path {
        match self {
            Self::Loading { path } | Self::Failed { path, .. } => path,
            Self::Ready(document) => &document.path,
        }
    }
}

/// 从磁盘读取并验证一个真实文本文件。
fn load_file_lines(path: PathBuf) -> Result<FileLineDocument, String> {
    let document = TextDocumentLoad::load(path.clone()).map_err(|error| error.user_message())?;
    let text = document.text();
    let lines = if text.is_empty() {
        Vec::new()
    } else {
        let mut lines = text
            .split('\n')
            .map(|line| line.strip_suffix('\r').unwrap_or(line).to_string())
            .collect::<Vec<_>>();
        if text.ends_with('\n') {
            lines.pop();
        }
        lines
    };
    let fingerprint = document.fingerprint();
    Ok(FileLineDocument::new(
        path,
        lines,
        FileLineStamp {
            len: fingerprint.byte_len,
            modified: fingerprint.modified,
        },
    ))
}

impl PaneFlowApp {
    /// 在文件树面板中异步打开真实文件行选择器。
    pub(crate) fn open_file_line_picker(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        let root = self.files_tree.root.clone();
        let Some(context_key) = self.workspace_focus.focused_context_key(&root) else {
            return;
        };
        self.files_line_picker = Some(FileLinePickerState::Loading { path: path.clone() });
        self.files_tree_scroll = gpui::ScrollHandle::new();
        cx.notify();

        cx.spawn(
            async move |this: gpui::WeakEntity<Self>, cx: &mut gpui::AsyncApp| {
                let result = smol::unblock({
                    let path = path.clone();
                    move || load_file_lines(path)
                })
                .await;
                let _ = this.update(cx, |app, cx| {
                    let still_current = app
                        .files_line_picker
                        .as_ref()
                        .is_some_and(|state| state.path() == path);
                    if !app.files_sidebar_open
                        || !still_current
                        || !app.workspace_focus.accepts_context_key(&context_key, &root)
                    {
                        return;
                    }
                    app.files_line_picker = Some(match result {
                        Ok(document) => FileLinePickerState::Ready(document),
                        Err(message) => FileLinePickerState::Failed { path, message },
                    });
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// 返回文件树并释放当前行选择状态。
    fn close_file_line_picker(&mut self, cx: &mut Context<Self>) {
        self.files_line_picker = None;
        self.files_tree_scroll = gpui::ScrollHandle::new();
        cx.notify();
    }

    /// 校验当前选择并把行范围引用预填到绑定终端。
    fn add_selected_line_reference(&mut self, window: &mut gpui::Window, cx: &mut Context<Self>) {
        let Some(FileLinePickerState::Ready(document)) = self.files_line_picker.as_ref() else {
            return;
        };
        let Some((first, last)) = document.selection else {
            self.show_toast("Select one or more lines first", cx);
            return;
        };
        if !document.is_current_on_disk() {
            self.show_toast("File changed; reopen it before adding lines", cx);
            return;
        }
        let reference = self.format_files_reference(&document.path, false, Some((first, last)));
        if self.inject_files_reference(&reference, window, cx) {
            self.show_toast("Added line reference to prompt", cx);
        } else {
            self.show_toast("Target terminal is unavailable", cx);
        }
    }

    /// 渲染行选择器标题栏，保留返回文件树和关闭整个右栏两个显式动作。
    pub(super) fn render_file_line_picker_header(
        &self,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title: SharedString = self
            .files_line_picker
            .as_ref()
            .and_then(|state| state.path().file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Select lines".to_string())
            .into();
        div()
            .h(px(36.))
            .flex_none()
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(6.))
            .child(
                div()
                    .id("files-line-picker-back")
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
                        this.close_file_line_picker(cx);
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
                    .text_size(px(12.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(ui.text)
                    .child(title),
            )
            .child(
                div()
                    .id("files-line-picker-close-sidebar")
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
            )
            .into_any_element()
    }

    /// 渲染当前文件页及连续行选择状态。
    pub(super) fn render_file_line_picker_body(
        &self,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(state) = self.files_line_picker.clone() else {
            return div().into_any_element();
        };
        match state {
            FileLinePickerState::Loading { .. } => line_picker_message("正在读取文件…", ui),
            FileLinePickerState::Failed { message, .. } => line_picker_message(&message, ui),
            FileLinePickerState::Ready(document) => {
                if document.lines.is_empty() {
                    return line_picker_message("文件为空，没有可选择的行。", ui);
                }
                let page_count = document.page_count();
                let page = document.page.min(page_count.saturating_sub(1));
                let start = page.saturating_mul(LINE_PICKER_PAGE_SIZE);
                let end = (start + LINE_PICKER_PAGE_SIZE).min(document.lines.len());
                let selection = document.selection;
                let mut rows = div()
                    .id("files-line-picker-rows")
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .overflow_x_hidden()
                    .track_scroll(&self.files_tree_scroll);
                for index in start..end {
                    let line_number = index + 1;
                    let content: SharedString = document.lines[index].clone().into();
                    let selected = selection
                        .is_some_and(|(first, last)| line_number >= first && line_number <= last);
                    rows = rows.child(
                        div()
                            .id(SharedString::from(format!("files-line-{line_number}")))
                            .h(px(24.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .when(selected, |row| row.bg(ui.accent.opacity(0.18)))
                            .hover(|style| {
                                style.bg(crate::app::constants::sidebar_tab_hover_background())
                            })
                            .on_click(cx.listener(move |this, event: &ClickEvent, _window, cx| {
                                let extend = matches!(
                                    event,
                                    ClickEvent::Mouse(mouse) if mouse.down.modifiers.shift
                                );
                                if let Some(FileLinePickerState::Ready(document)) =
                                    this.files_line_picker.as_mut()
                                {
                                    document.select_line(line_number, extend);
                                    cx.notify();
                                }
                                cx.stop_propagation();
                            }))
                            .child(
                                div()
                                    .w(px(46.))
                                    .flex_none()
                                    .pr(px(8.))
                                    .text_right()
                                    .text_size(px(10.))
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
                                    .text_size(px(11.))
                                    .text_color(ui.text)
                                    .child(content),
                            ),
                    );
                }

                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h_0()
                    .child(rows)
                    .child(render_line_picker_pager(page, page_count, ui, cx))
                    .child(render_line_picker_action(selection, ui, cx))
                    .into_any_element()
            }
        }
    }
}

/// 渲染行范围确认按钮；没有选择时保留布局但不可点击。
fn render_line_picker_action(
    selection: Option<(usize, usize)>,
    ui: crate::theme::UiColors,
    cx: &mut Context<PaneFlowApp>,
) -> AnyElement {
    let label = selection.map_or_else(
        || "Select lines".to_string(),
        |(first, last)| {
            if first == last {
                format!("Add L{first} to Prompt")
            } else {
                format!("Add L{first}-L{last} to Prompt")
            }
        },
    );
    div()
        .h(px(40.))
        .flex_none()
        .px(px(10.))
        .pb(px(8.))
        .child(
            div()
                .id("files-lines-add-reference")
                .h(px(32.))
                .w_full()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(6.))
                .text_size(px(11.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(if selection.is_some() {
                    ui.base
                } else {
                    ui.muted
                })
                .bg(if selection.is_some() {
                    ui.accent
                } else {
                    ui.subtle
                })
                .when(selection.is_some(), |button| {
                    button
                        .cursor_pointer()
                        .hover(|style| style.opacity(0.88))
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.add_selected_line_reference(window, cx);
                            cx.stop_propagation();
                        }))
                })
                .child(label),
        )
        .into_any_element()
}

/// 渲染加载、失败或空文件提示。
fn line_picker_message(message: &str, ui: crate::theme::UiColors) -> AnyElement {
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

/// 渲染固定高度分页器；单页文件仅显示行数，不创建无效按钮。
fn render_line_picker_pager(
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
            line_picker_page_button("files-lines-prev", "Previous", previous_enabled, ui).on_click(
                cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    if previous_enabled
                        && let Some(FileLinePickerState::Ready(document)) =
                            this.files_line_picker.as_mut()
                    {
                        document.set_page(document.page.saturating_sub(1));
                        this.files_tree_scroll = gpui::ScrollHandle::new();
                        cx.notify();
                    }
                }),
            ),
        )
        .child(format!("{} / {}", page + 1, page_count))
        .child(
            line_picker_page_button("files-lines-next", "Next", next_enabled, ui).on_click(
                cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    if next_enabled
                        && let Some(FileLinePickerState::Ready(document)) =
                            this.files_line_picker.as_mut()
                    {
                        document.set_page(document.page.saturating_add(1));
                        this.files_tree_scroll = gpui::ScrollHandle::new();
                        cx.notify();
                    }
                }),
            ),
        )
        .into_any_element()
}

/// 渲染行选择器的轻量分页按钮。
fn line_picker_page_button(
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_real_utf8_crlf_file_and_keeps_true_lines() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("source.rs");
        std::fs::write(&path, "第一行\r\nsecond line\r\n").expect("应能写入真实文本文件");

        let document = load_file_lines(path).expect("真实 UTF-8 文件应成功加载");

        assert_eq!(&*document.lines, &["第一行", "second line"]);
    }

    #[test]
    fn rejects_real_binary_and_oversized_files() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let binary = directory.path().join("binary.dat");
        std::fs::write(&binary, [1_u8, 0, 2]).expect("应能写入真实二进制文件");
        assert!(load_file_lines(binary).unwrap_err().contains("二进制"));

        let oversized = directory.path().join("large.txt");
        let file = std::fs::File::create(&oversized).expect("应能创建真实大文件");
        file.set_len(MAX_LINE_PICKER_BYTES + 1)
            .expect("应能设置真实文件长度");
        assert!(load_file_lines(oversized).unwrap_err().contains("1 MiB"));
    }

    #[test]
    fn normal_and_shift_click_form_normalized_continuous_range() {
        let mut document = FileLineDocument::new(
            PathBuf::from("source.rs"),
            (1..=12).map(|line| format!("line {line}")).collect(),
            FileLineStamp {
                len: 0,
                modified: None,
            },
        );

        document.select_line(8, false);
        assert_eq!(document.selection, Some((8, 8)));
        document.select_line(3, true);
        assert_eq!(document.selection, Some((3, 8)));
        document.select_line(11, false);
        assert_eq!(document.selection, Some((11, 11)));
    }

    #[test]
    fn empty_real_file_has_no_selectable_lines() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("empty.txt");
        std::fs::write(&path, []).expect("应能创建真实空文件");

        let mut document = load_file_lines(path).expect("空文本文件应成功加载");
        document.select_line(1, false);

        assert!(document.lines.is_empty());
        assert_eq!(document.selection, None);
        assert_eq!(document.page_count(), 1);
    }

    #[test]
    fn real_file_change_invalidates_loaded_line_numbers() {
        let directory = tempfile::tempdir().expect("应能创建真实临时目录");
        let path = directory.path().join("changing.rs");
        std::fs::write(&path, "one\ntwo").expect("应能写入初始真实文件");
        let document = load_file_lines(path.clone()).expect("初始文件应成功加载");
        assert!(document.is_current_on_disk());

        std::fs::write(&path, "one\ntwo\nthree").expect("应能修改真实文件");

        assert!(!document.is_current_on_disk());
    }
}
