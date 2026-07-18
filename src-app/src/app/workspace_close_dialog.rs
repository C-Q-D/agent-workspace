//! 运行中工作区的关闭确认对话框。
//!
//! 对话框只持有应用状态中的稳定 workspace ID；取消不触发副作用，确认再进入
//! `workspace_ops` 的唯一关闭执行函数，避免复制终端和资源清理逻辑。

use gpui::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement, IntoElement, MouseButton,
    ParentElement, Styled, deferred, div, prelude::*, px,
};

use crate::PaneFlowApp;

impl PaneFlowApp {
    /// 渲染覆盖主窗口的运行中工作区关闭确认对话框。
    pub(crate) fn render_workspace_close_dialog(
        &self,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = self
            .pending_workspace_close
            .and_then(|workspace_id| {
                self.workspaces
                    .iter()
                    .find(|workspace| workspace.id == workspace_id)
            })
            .map(|workspace| workspace.title.clone())
            .unwrap_or_else(|| "Workspace".to_string());
        let body =
            format!("Close \"{title}\"? Its running PowerShell and CLI processes will be stopped.");

        let backdrop = div()
            .id("workspace-close-backdrop")
            .occlude()
            .absolute()
            .top(px(0.))
            .left(px(0.))
            .size_full()
            .bg(gpui::black().opacity(0.45))
            .flex()
            .items_center()
            .justify_center()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| this.cancel_workspace_close(cx)),
            )
            .child(
                div()
                    .id("workspace-close-dialog")
                    .occlude()
                    .w(px(380.))
                    .bg(ui.overlay)
                    .border_1()
                    .border_color(ui.border)
                    .rounded(px(10.))
                    .shadow_lg()
                    .p(px(16.))
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(ui.text)
                            .child("Close running workspace?"),
                    )
                    .child(div().text_size(px(12.)).text_color(ui.muted).child(body))
                    .child(
                        div()
                            .mt(px(6.))
                            .flex()
                            .flex_row()
                            .justify_end()
                            .gap(px(8.))
                            .child(
                                div()
                                    .id("workspace-close-cancel")
                                    .px(px(14.))
                                    .py(px(7.))
                                    .rounded(px(6.))
                                    .cursor_pointer()
                                    .bg(ui.subtle)
                                    .text_size(px(12.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(ui.text)
                                    .hover(|style| {
                                        let ui = crate::theme::ui_colors();
                                        style.bg(ui.surface)
                                    })
                                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                        this.cancel_workspace_close(cx);
                                    }))
                                    .child("Cancel"),
                            )
                            .child(
                                div()
                                    .id("workspace-close-confirm")
                                    .px(px(14.))
                                    .py(px(7.))
                                    .rounded(px(6.))
                                    .cursor_pointer()
                                    .bg(gpui::rgb(0xf38ba8))
                                    .text_size(px(12.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(ui.base)
                                    .hover(|style| style.opacity(0.88))
                                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                        this.confirm_workspace_close(window, cx);
                                    }))
                                    .child("Close Workspace"),
                            ),
                    ),
            );

        deferred(backdrop).priority(4).into_any_element()
    }
}
