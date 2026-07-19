//! “General”通用设置页。
//!
//! 本页承载默认编辑器、新终端 Shell，以及新工作区的引用格式和 Git 初始化策略。
//! 所有控件复用共享设置组件与 [`PaneFlowApp::persist_setting`]，点击后先更新内存
//! 并重绘，再由后台原子写入配置文件；页面本身不创建轮询或常驻任务。

use gpui::{
    AnyElement, ClickEvent, Context, CursorStyle, InteractiveElement, IntoElement, MouseButton,
    ParentElement, SharedString, Styled, div, prelude::*, px,
};
use serde_json::Value;

use crate::GeneralDropdown;
use crate::PaneFlowApp;
use crate::reference_formatter::ReferenceFormat;
use crate::settings::components::{
    Logo, deferred_select_menu, hairline, render_logo, section_header, select_chevron, select_item,
    select_menu, select_trigger, setting_card, setting_text, toggle_pill,
};

/// One select option: display label, optional leading logo, the JSON value
/// written to config when picked, and whether it is the current selection.
type SelectOption = (String, Option<Logo>, Value, bool);

impl PaneFlowApp {
    pub(crate) fn render_general_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let ui = crate::theme::ui_colors();
        let config = &self.cached_config;

        // ── Default editor (external_editor) ────────────────────────────
        // "auto" is the default when unset. Each preset carries its brand logo
        // (see `editor_icon`).
        let editor_value = config
            .external_editor
            .clone()
            .unwrap_or_else(|| "auto".to_string());
        let editor_opts: Vec<SelectOption> = EDITOR_PRESETS
            .iter()
            .map(|(label, val)| {
                (
                    (*label).to_string(),
                    editor_icon(val),
                    Value::String((*val).to_string()),
                    editor_value == *val,
                )
            })
            .collect();
        let editor_label = editor_opts
            .iter()
            .find(|(_, _, _, selected)| *selected)
            .map(|(label, _, _, _)| label.clone())
            .unwrap_or_else(|| editor_value.clone());

        let editor_row = self.general_select_row(
            GeneralDropdown::Editor,
            "Default editor",
            "Default application for opening files and folders.",
            editor_label,
            editor_icon(&editor_value),
            editor_opts,
            "external_editor",
            ui,
            cx,
        );

        // ── Shell in the integrated terminal (default_shell) ────────────
        // Order mirrors `terminal::shell`'s resolver preference. Any other value
        // still works via config; the trigger shows the raw value when it does
        // not match a preset, or "System default" when unset.
        #[cfg(target_os = "windows")]
        let shells: Vec<(&str, String)> = vec![
            ("PowerShell", "pwsh.exe".to_string()),
            ("Windows PowerShell", "powershell.exe".to_string()),
            ("Command Prompt", "cmd.exe".to_string()),
            (
                "Git Bash",
                crate::terminal::shell::find_windows_git_bash()
                    .unwrap_or_else(|| "bash.exe".to_string()),
            ),
        ];
        #[cfg(not(target_os = "windows"))]
        let shells: Vec<(&str, String)> = vec![
            ("zsh", "/bin/zsh".to_string()),
            ("bash", "/bin/bash".to_string()),
            ("sh", "/bin/sh".to_string()),
            ("fish", "/usr/bin/fish".to_string()),
        ];

        let current_shell = config.default_shell.clone().unwrap_or_default();
        let shell_opts: Vec<SelectOption> = shells
            .iter()
            .map(|(label, val)| {
                (
                    (*label).to_string(),
                    None,
                    Value::String(val.clone()),
                    shell_preset_eq(&current_shell, val),
                )
            })
            .collect();
        let shell_label = shell_opts
            .iter()
            .find(|(_, _, _, selected)| *selected)
            .map(|(label, _, _, _)| label.clone())
            .unwrap_or_else(|| {
                if current_shell.is_empty() {
                    "System default".to_string()
                } else {
                    current_shell.clone()
                }
            });

        let shell_row = self.general_select_row(
            GeneralDropdown::Shell,
            "Shell in the integrated terminal",
            "Choose which shell opens in new integrated terminals. Existing terminals keep their shell until restarted.",
            shell_label,
            None,
            shell_opts,
            "default_shell",
            ui,
            cx,
        );

        let launch_card = setting_card(ui)
            .child(editor_row)
            .child(hairline(ui))
            .child(shell_row);

        // 新工作区引用格式只读取稳定枚举，不探测正在运行的 CLI。
        let reference_format = ReferenceFormat::from_new_workspace_config(config);
        let reference_opts = reference_format_setting_options(reference_format);
        let reference_row = self.general_select_row(
            GeneralDropdown::ReferenceFormat,
            "Default reference format",
            "Choose how file and line references are inserted in new workspaces. Existing workspaces keep their saved format.",
            reference_format_setting_label(reference_format).to_string(),
            None,
            reference_opts,
            "default_reference_format",
            ui,
            cx,
        );
        let git_auto_init = config.git_auto_init_enabled();
        let git_auto_init_row = self.general_toggle_row(
            "general-git-auto-init",
            "Initialize Git repositories automatically",
            "Run git init when a new or restored workspace root is not already a repository. Existing repositories remain available when disabled.",
            git_auto_init,
            "git_auto_init",
            ui,
            cx,
        );
        let workspace_card = setting_card(ui)
            .child(reference_row)
            .child(hairline(ui))
            .child(git_auto_init_row);

        div()
            .flex()
            .flex_col()
            .child(section_header(ui, "Launch defaults"))
            .child(launch_card)
            .child(div().h(px(20.)).flex_none())
            .child(section_header(ui, "New workspace defaults"))
            .child(workspace_card)
            .child(div().h(px(120.)).flex_none())
    }

    /// One General-page setting row: label/description on the left, a Codex-style
    /// select on the right (shared `components::select_*` primitives). `options`
    /// are `(label, leading_logo, json_value, is_selected)`. Both fields this
    /// drives are top-level, so the write is always un-nested.
    #[allow(clippy::too_many_arguments)]
    fn general_select_row(
        &self,
        which: GeneralDropdown,
        title: &'static str,
        description: &'static str,
        current_label: String,
        current_icon: Option<Logo>,
        options: Vec<SelectOption>,
        config_key: &'static str,
        ui: crate::theme::UiColors,
        // Concrete `AnyElement` (not `impl IntoElement`) so the value does not
        // capture `cx`'s borrow under edition-2024 RPIT - otherwise the two
        // `let` rows above would hold overlapping `&mut cx` borrows.
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_open = self.general_dropdown == Some(which);

        // Value cluster: optional leading logo + truncating label.
        let mut value = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.))
            .flex_1()
            .min_w_0();
        if let Some(icon) = current_icon {
            value = value.child(render_logo(icon, ui));
        }
        value = value.child(
            div()
                .min_w_0()
                .text_size(px(12.))
                .text_color(ui.text)
                .truncate()
                .child(current_label),
        );

        // Decide open/close from the render-time `is_open` snapshot, not the
        // live state: the menu's `on_mouse_down_out` fires on this same press and
        // may have already cleared the state, so a live toggle would re-open.
        let mut trigger =
            select_trigger(SharedString::from(format!("general-dd-{config_key}")), ui)
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.general_dropdown = if is_open { None } else { Some(which) };
                        this.settings_focus.focus(window, cx);
                        cx.notify();
                    }),
                )
                .child(value)
                .child(select_chevron(ui));

        if is_open {
            let mut menu = select_menu(
                SharedString::from(format!("general-dd-list-{config_key}")),
                ui,
            )
            // Guard on `which` so opening the *other* select does not
            // close it via this menu's out-handler (shared state).
            .on_mouse_down_out(cx.listener(move |this, _, _w, cx| {
                if this.general_dropdown == Some(which) {
                    this.general_dropdown = None;
                    cx.notify();
                }
            }));
            for (i, (label, icon, value, selected)) in options.into_iter().enumerate() {
                let value_for_click = value;
                let mut item = select_item((config_key, i), selected, ui).on_click(cx.listener(
                    move |this, _: &ClickEvent, _w, cx| {
                        this.general_dropdown = None;
                        this.persist_setting(false, config_key, value_for_click.clone(), cx);
                    },
                ));
                if let Some(icon) = icon {
                    item = item.child(render_logo(icon, ui));
                }
                item = item.child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_color(ui.text)
                        .child(label),
                );
                menu = menu.child(item);
            }
            trigger = trigger.child(deferred_select_menu(menu));
        }

        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(16.))
            .px(px(12.))
            .py(px(10.))
            .child(setting_text(ui, title, description))
            .child(div().flex_shrink_0().child(trigger))
            .into_any_element()
    }

    /// 渲染顶层布尔设置；目标值在本次渲染时固定，快速点击仍由统一配置写入器串行化。
    #[allow(clippy::too_many_arguments)]
    fn general_toggle_row(
        &self,
        id: &'static str,
        title: &'static str,
        description: &'static str,
        current: bool,
        config_key: &'static str,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let target_value = !current;
        div()
            .id(SharedString::from(format!("{id}-row")))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(16.))
            .px(px(12.))
            .py(px(10.))
            .child(setting_text(ui, title, description))
            .child(
                div()
                    .id(SharedString::from(id))
                    .flex_shrink_0()
                    .cursor(CursorStyle::PointingHand)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                        this.persist_setting(false, config_key, Value::Bool(target_value), cx);
                    }))
                    .child(toggle_pill(current, ui)),
            )
            .into_any_element()
    }
}

/// 设置页使用完整的产品名称，避免把普通 PowerShell 默认值误解成任意 Shell。
fn reference_format_setting_label(format: ReferenceFormat) -> &'static str {
    match format {
        ReferenceFormat::Common => "Common",
        ReferenceFormat::Codex => "Codex",
        ReferenceFormat::Claude => "Claude Code",
        ReferenceFormat::PowerShell => "PowerShell",
    }
}

/// 生成稳定顺序的引用格式选项，并直接携带写入配置的规范小写值。
fn reference_format_setting_options(current: ReferenceFormat) -> Vec<SelectOption> {
    ReferenceFormat::ALL
        .into_iter()
        .map(|format| {
            (
                reference_format_setting_label(format).to_string(),
                None,
                Value::String(format.as_persisted().to_string()),
                format == current,
            )
        })
        .collect()
}

/// Per-editor leading logo for the Default-editor select. Brand-color logos
/// (Zed / VS Code / Visual Studio) are PNGs rendered in full color; Cursor and
/// Windsurf ship as monochrome `currentColor` SVGs that follow the theme.
/// `auto` / `system` have no logo.
pub(crate) const EDITOR_PRESETS: &[(&str, &str)] = &[
    ("Auto-detect", "auto"),
    ("Zed", "zed"),
    ("Cursor", "cursor"),
    ("Windsurf", "windsurf"),
    ("VS Code", "code"),
    ("Visual Studio", "visual_studio"),
    ("System default", "system"),
];

pub(crate) fn editor_icon(value: &str) -> Option<Logo> {
    match value {
        "zed" => Some(("icons/editor-zed.png", true)),
        "code" => Some(("icons/editor-vscode.png", true)),
        "visual_studio" => Some(("icons/editor-visual-studio.png", true)),
        "cursor" => Some(("icons/editor-cursor.svg", false)),
        "windsurf" => Some(("icons/editor-windsurf.svg", false)),
        _ => None,
    }
}

/// Case-insensitive comparison for shell presets. Bare configured names match
/// by basename (`bash.exe` should still select Git Bash), while two explicit
/// paths must point at the same executable (`C:\Windows\System32\bash.exe`
/// should not be presented as Git Bash).
fn shell_preset_eq(stored: &str, chip: &str) -> bool {
    fn has_separator(s: &str) -> bool {
        s.contains(['/', '\\'])
    }

    fn path_key(s: &str) -> String {
        s.replace('/', "\\").to_ascii_lowercase()
    }

    fn stem(s: &str) -> String {
        let base = s
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or(s)
            .to_ascii_lowercase();
        base.trim_end_matches(".exe").to_string()
    }

    if stored.is_empty() {
        false
    } else if has_separator(stored) && has_separator(chip) {
        path_key(stored) == path_key(chip)
    } else {
        stem(stored) == stem(chip)
    }
}

#[cfg(test)]
mod tests {
    use crate::reference_formatter::ReferenceFormat;

    #[test]
    fn shell_preset_matches_bare_names_by_basename() {
        assert!(super::shell_preset_eq(
            "bash.exe",
            r"C:\Program Files\Git\bin\bash.exe"
        ));
        assert!(super::shell_preset_eq(
            r"C:\Program Files\Git\bin\bash.exe",
            "bash.exe"
        ));
    }

    #[test]
    fn shell_preset_does_not_label_explicit_wsl_bash_as_git_bash() {
        assert!(!super::shell_preset_eq(
            r"C:\Windows\System32\bash.exe",
            r"C:\Program Files\Git\bin\bash.exe"
        ));
    }

    #[test]
    fn reference_format_options_keep_labels_values_and_selection_stable() {
        let options = super::reference_format_setting_options(ReferenceFormat::Claude);
        let simplified: Vec<_> = options
            .into_iter()
            .map(|(label, _icon, value, selected)| (label, value, selected))
            .collect();

        assert_eq!(
            simplified,
            vec![
                ("Common".to_string(), serde_json::json!("common"), false),
                ("Codex".to_string(), serde_json::json!("codex"), false),
                ("Claude Code".to_string(), serde_json::json!("claude"), true),
                (
                    "PowerShell".to_string(),
                    serde_json::json!("powershell"),
                    false
                ),
            ]
        );
    }
}
