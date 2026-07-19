//! AgentWorkspace 的紧凑型原生 About 对话框。

use gpui::{
    AnyElement, ClickEvent, Context, InteractiveElement, IntoElement, MouseButton, ObjectFit,
    ParentElement, Styled, deferred, div, hsla, img, prelude::*, px, rgb, svg,
};

use crate::PaneFlowApp;
use crate::product_identity::{
    LICENSE_URL, PRODUCT_NAME, REPOSITORY_URL, THIRD_PARTY_LICENSES_URL, UPSTREAM_REPOSITORY_URL,
};

/// 构造静态法律材料入口；点击只交给 Windows 默认浏览器，不启动后台任务或轮询。
fn legal_link_button(
    id: &'static str,
    label: &'static str,
    url: &'static str,
    cx: &mut Context<PaneFlowApp>,
) -> AnyElement {
    let ui = crate::theme::ui_colors();
    div()
        .id(id)
        .h(px(27.))
        .px(px(10.))
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .border_1()
        .border_color(rgb(0x4a4a50))
        .cursor_pointer()
        .text_size(px(11.))
        .text_color(ui.text)
        .hover(|style| style.bg(rgb(0x343438)))
        .on_click(cx.listener(move |_this, _: &ClickEvent, _, cx| {
            if let Err(error) = crate::external_open::open_url(url) {
                log::warn!("打开 About 法律材料失败：{url}: {error}");
            }
            cx.stop_propagation();
        }))
        .child(label)
        .into_any_element()
}

impl PaneFlowApp {
    pub(crate) fn render_about_dialog(&self, cx: &mut Context<Self>) -> AnyElement {
        let ui = crate::theme::ui_colors();
        let version = env!("CARGO_PKG_VERSION");

        let close_x = div()
            .id("about-close-x")
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .w(px(30.))
            .h(px(30.))
            .rounded(px(7.))
            .cursor_pointer()
            .hover(|s| s.bg(rgb(0x3a3a3c)))
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.show_about_dialog = false;
                cx.notify();
                cx.stop_propagation();
            }))
            .child(
                svg()
                    .size(px(12.))
                    .flex_none()
                    .path("icons/close.svg")
                    .text_color(ui.text),
            );

        let header = div()
            .h(px(32.))
            .w_full()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .pl(px(10.))
            .pr(px(2.))
            .bg(rgb(0x222228))
            .border_b_1()
            .border_color(rgb(0x343438))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(7.))
                    .child(
                        img("icons/agent-workspace.png")
                            .w(px(16.))
                            .h(px(16.))
                            .object_fit(ObjectFit::Contain),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .font_weight(gpui::FontWeight::NORMAL)
                            .text_color(ui.text)
                            .child(format!("About {PRODUCT_NAME}")),
                    ),
            )
            .child(close_x);

        let body = div()
            .w_full()
            .h(px(310.))
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .bg(rgb(0x202020))
            .child(
                img("icons/agent-workspace.png")
                    .w(px(64.))
                    .h(px(64.))
                    .object_fit(ObjectFit::Contain),
            )
            .child(
                div()
                    .mt(px(14.))
                    .text_color(ui.text)
                    .text_size(px(16.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(PRODUCT_NAME),
            )
            .child(
                div()
                    .mt(px(20.))
                    .text_color(ui.muted)
                    .text_size(px(12.))
                    .child(format!("Version {version}")),
            )
            .child(
                div()
                    .mt(px(11.))
                    .text_color(ui.muted)
                    .text_size(px(12.))
                    .child("Copyright 2025 Arthur Jean · 2026 C-Q-D"),
            )
            .child(
                div()
                    .mt(px(7.))
                    .text_color(ui.muted)
                    .text_size(px(11.))
                    .child("Modified from Paneflow; not an official Paneflow release."),
            )
            .child(
                div()
                    .mt(px(5.))
                    .text_color(ui.muted)
                    .text_size(px(11.))
                    .child("GPL-3.0-or-later · No warranty"),
            )
            .child(
                div()
                    .mt(px(15.))
                    .flex()
                    .flex_row()
                    .gap(px(8.))
                    .child(legal_link_button(
                        "about-source-code",
                        "Source code",
                        REPOSITORY_URL,
                        cx,
                    ))
                    .child(legal_link_button(
                        "about-upstream",
                        "Paneflow upstream",
                        UPSTREAM_REPOSITORY_URL,
                        cx,
                    ))
                    .child(legal_link_button(
                        "about-license",
                        "GPL license",
                        LICENSE_URL,
                        cx,
                    ))
                    .child(legal_link_button(
                        "about-third-party-licenses",
                        "Third-party licenses",
                        THIRD_PARTY_LICENSES_URL,
                        cx,
                    )),
            );

        let ok_button = div()
            .id("about-ok")
            .w(px(76.))
            .h(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(3.))
            .border_1()
            .border_color(rgb(0x66666a))
            .bg(rgb(0x2d2d2f))
            .cursor_pointer()
            .text_size(px(12.))
            .text_color(ui.text)
            .hover(|s| s.bg(rgb(0x3a3a3c)))
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.show_about_dialog = false;
                cx.notify();
                cx.stop_propagation();
            }))
            .child("OK");

        let footer = div()
            .w_full()
            .h(px(56.))
            .flex_none()
            .flex()
            .items_center()
            .justify_end()
            .px(px(14.))
            .bg(rgb(0x252525))
            .border_t_1()
            .border_color(rgb(0x343438))
            .child(ok_button);

        let dialog = div()
            .id("about-dialog")
            .occlude()
            .w(px(492.))
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(rgb(0x202020))
            .border_1()
            .border_color(rgb(0x3a3a3c))
            .rounded(px(10.))
            .shadow_lg()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_mouse_down(MouseButton::Right, |_, _, cx| cx.stop_propagation())
            .child(header)
            .child(body)
            .child(footer);

        deferred(
            div()
                .id("about-dialog-backdrop")
                .absolute()
                .top_0()
                .left_0()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .bg(hsla(0., 0., 0., 0.55))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, _, cx| {
                        this.show_about_dialog = false;
                        cx.notify();
                    }),
                )
                .child(dialog),
        )
        .with_priority(10)
        .into_any_element()
    }
}
