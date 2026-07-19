//! "AI Agent" settings page - compact toggles for the built-in AI launcher
//! buttons rendered in every tab bar, plus the Claude bypass-permissions guard.
//!
//! Sections use lowercase eyebrows followed by `setting_card` groups of toggles,
//! separated by `hairline()` dividers. Only the switch is interactive - the row
//! itself does not hover or click.
//!
//! Persistence goes through [`PaneFlowApp::persist_setting`] - it mutates the
//! cached config for instant feedback and writes `paneflow.json` off the main
//! thread; `pane.rs` picks up the new state via the ConfigWatcher propagation so
//! the tab bar reflects changes without a restart. The MCP bridge installer
//! lives on its own page (`settings::tabs::mcp`).

use gpui::{
    AnyElement, ClickEvent, Context, CursorStyle, Hsla, InteractiveElement, IntoElement,
    KeyDownEvent, ParentElement, SharedString, Styled, div, img, prelude::*, px, rgb, svg,
};

use crate::PaneFlowApp;
use crate::agent_launcher::TerminalAgent;
use crate::settings::components::{
    SETTINGS_CONTROL_CORNER_RADIUS, hairline, secondary_button, section_header, setting_card,
    setting_text, toggle_pill,
};

/// AI Agent 页当前支持编辑的两个稳定启动命令字段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AgentCommandField {
    ClaudeCode,
    Codex,
}

impl AgentCommandField {
    /// 返回持久化键；只允许固定枚举映射，避免 UI 字符串进入配置路径。
    fn config_key(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude_code_command",
            Self::Codex => "codex_command",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code command",
            Self::Codex => "Codex command",
        }
    }

    fn default_command(self) -> &'static str {
        match self {
            Self::ClaudeCode => {
                paneflow_config::schema::PaneFlowConfig::DEFAULT_CLAUDE_CODE_COMMAND
            }
            Self::Codex => paneflow_config::schema::PaneFlowConfig::DEFAULT_CODEX_COMMAND,
        }
    }

    fn row_id(self) -> &'static str {
        match self {
            Self::ClaudeCode => "row-claude-command",
            Self::Codex => "row-codex-command",
        }
    }

    fn reset_id(self) -> &'static str {
        match self {
            Self::ClaudeCode => "reset-claude-command",
            Self::Codex => "reset-codex-command",
        }
    }
}

/// 将单行输入转换为可持久化值；空白表示删除字段并恢复默认命令。
fn normalize_agent_command_input(raw: &str) -> Result<Option<String>, &'static str> {
    // 先检查原始输入，避免制表符等控制字符被 trim 吞掉后误判为“恢复默认”。
    if raw.chars().any(char::is_control) {
        return Err("Command cannot contain tabs, newlines, or other control characters.");
    }
    let command = raw.trim();
    if command.is_empty() {
        return Ok(None);
    }
    if command.len() > paneflow_config::schema::PaneFlowConfig::MAX_AGENT_COMMAND_BYTES {
        return Err("Command must be 4096 UTF-8 bytes or fewer.");
    }
    Ok(Some(command.to_string()))
}

struct AgentToggleRow {
    id: &'static str,
    title: &'static str,
    description: &'static str,
    agent: TerminalAgent,
    config_key: &'static str,
}

const AGENT_TOGGLE_ROWS: &[AgentToggleRow] = &[
    AgentToggleRow {
        id: "row-claude-visible",
        title: "Claude Code",
        description: "Show the Claude Code launcher button in every tab bar.",
        agent: TerminalAgent::ClaudeCode,
        config_key: "claude_code_button_visible",
    },
    AgentToggleRow {
        id: "row-codex-visible",
        title: "Codex",
        description: "Show the Codex launcher button in every tab bar.",
        agent: TerminalAgent::Codex,
        config_key: "codex_button_visible",
    },
    AgentToggleRow {
        id: "row-opencode-visible",
        title: "Opencode",
        description: "Show the Opencode launcher button in every tab bar.",
        agent: TerminalAgent::OpenCode,
        config_key: "opencode_button_visible",
    },
    AgentToggleRow {
        id: "row-pi-visible",
        title: "Pi",
        description: "Show the Pi launcher button in every tab bar.",
        agent: TerminalAgent::Pi,
        config_key: "pi_button_visible",
    },
    AgentToggleRow {
        id: "row-hermes-agent-visible",
        title: "Hermes Agent",
        description: "Show the Hermes Agent launcher button in every tab bar.",
        agent: TerminalAgent::Hermes,
        config_key: "hermes_agent_button_visible",
    },
    AgentToggleRow {
        id: "row-grok-visible",
        title: "Grok",
        description: "Show the Grok launcher button in every tab bar.",
        agent: TerminalAgent::Grok,
        config_key: "grok_button_visible",
    },
    AgentToggleRow {
        id: "row-amp-visible",
        title: "Amp",
        description: "Show the Amp launcher button in every tab bar.",
        agent: TerminalAgent::Amp,
        config_key: "amp_button_visible",
    },
    AgentToggleRow {
        id: "row-cursor-visible",
        title: "Cursor",
        description: "Show the Cursor launcher button in every tab bar.",
        agent: TerminalAgent::Cursor,
        config_key: "cursor_button_visible",
    },
    AgentToggleRow {
        id: "row-gemini-visible",
        title: "Gemini",
        description: "Show the Gemini launcher button in every tab bar.",
        agent: TerminalAgent::Gemini,
        config_key: "gemini_button_visible",
    },
    AgentToggleRow {
        id: "row-kiro-visible",
        title: "Kiro",
        description: "Show the Kiro launcher button in every tab bar.",
        agent: TerminalAgent::Kiro,
        config_key: "kiro_button_visible",
    },
    AgentToggleRow {
        id: "row-antigravity-visible",
        title: "Antigravity",
        description: "Show the Antigravity launcher button in every tab bar.",
        agent: TerminalAgent::Antigravity,
        config_key: "antigravity_button_visible",
    },
    AgentToggleRow {
        id: "row-copilot-visible",
        title: "Copilot",
        description: "Show the Copilot launcher button in every tab bar.",
        agent: TerminalAgent::Copilot,
        config_key: "copilot_button_visible",
    },
    AgentToggleRow {
        id: "row-codebuddy-visible",
        title: "CodeBuddy",
        description: "Show the CodeBuddy launcher button in every tab bar.",
        agent: TerminalAgent::CodeBuddy,
        config_key: "codebuddy_button_visible",
    },
    AgentToggleRow {
        id: "row-factory-visible",
        title: "Factory",
        description: "Show the Factory launcher button in every tab bar.",
        agent: TerminalAgent::Factory,
        config_key: "factory_button_visible",
    },
    AgentToggleRow {
        id: "row-qoder-visible",
        title: "Qoder",
        description: "Show the Qoder launcher button in every tab bar.",
        agent: TerminalAgent::Qoder,
        config_key: "qoder_button_visible",
    },
    AgentToggleRow {
        id: "row-openclaw-visible",
        title: "Openclaw",
        description: "Show the Openclaw launcher button in every tab bar.",
        agent: TerminalAgent::Openclaw,
        config_key: "openclaw_button_visible",
    },
];

impl PaneFlowApp {
    /// 从当前配置同步两个输入框；原始自定义值保留，便于用户修复无效配置。
    pub(crate) fn sync_ai_agent_command_inputs(&mut self, cx: &mut Context<Self>) {
        let claude = self
            .cached_config
            .claude_code_command
            .clone()
            .unwrap_or_default();
        let codex = self.cached_config.codex_command.clone().unwrap_or_default();
        self.ai_agent_claude_command_input
            .update(cx, |input, cx| input.set_value(claude, cx));
        self.ai_agent_codex_command_input
            .update(cx, |input, cx| input.set_value(codex, cx));
        self.ai_agent_command_status = None;
    }

    /// 返回字段对应的输入实体，调用方使用克隆避免跨可变更新持有借用。
    fn agent_command_input(
        &self,
        field: AgentCommandField,
    ) -> gpui::Entity<crate::widgets::text_input::TextInput> {
        match field {
            AgentCommandField::ClaudeCode => self.ai_agent_claude_command_input.clone(),
            AgentCommandField::Codex => self.ai_agent_codex_command_input.clone(),
        }
    }

    /// 校验并提交单个命令字段；无变化时不调度磁盘任务。
    fn commit_agent_command(&mut self, field: AgentCommandField, cx: &mut Context<Self>) {
        let input = self.agent_command_input(field);
        let raw = input.read(cx).value();
        let desired = match normalize_agent_command_input(&raw) {
            Ok(value) => value,
            Err(message) => {
                self.ai_agent_command_status = Some(format!("{}: {message}", field.label()));
                self.show_toast(format!("{} is invalid", field.label()), cx);
                cx.notify();
                return;
            }
        };
        let current = match field {
            AgentCommandField::ClaudeCode => self.cached_config.claude_code_command.as_deref(),
            AgentCommandField::Codex => self.cached_config.codex_command.as_deref(),
        };
        if current == desired.as_deref() {
            self.ai_agent_command_status =
                Some(format!("{} has no unsaved changes.", field.label()));
            cx.notify();
            return;
        }

        let display_value = desired.clone().unwrap_or_default();
        input.update(cx, |input, cx| input.set_value(display_value, cx));
        let json_value = desired
            .map(serde_json::Value::String)
            .unwrap_or(serde_json::Value::Null);
        self.persist_agent_command_setting(field.config_key(), json_value, cx);
        self.ai_agent_command_status = Some(format!(
            "{} saved. It applies to new launches and resumes.",
            field.label()
        ));
        cx.notify();
    }

    /// 删除自定义字段并立即恢复默认命令，同时同步输入框和有效值提示。
    fn reset_agent_command(&mut self, field: AgentCommandField, cx: &mut Context<Self>) {
        let input = self.agent_command_input(field);
        input.update(cx, |input, cx| input.clear(cx));
        self.persist_agent_command_setting(field.config_key(), serde_json::Value::Null, cx);
        self.ai_agent_command_status = Some(format!(
            "{} restored to default `{}`.",
            field.label(),
            field.default_command()
        ));
        cx.notify();
    }

    /// 在关闭设置或离开 AI Agent 页时提交仍在输入框中的有效改动。
    pub(crate) fn commit_ai_agent_command_inputs(&mut self, cx: &mut Context<Self>) {
        self.commit_agent_command(AgentCommandField::ClaudeCode, cx);
        self.commit_agent_command(AgentCommandField::Codex, cx);
    }

    pub(crate) fn render_ai_agent_content(&self, cx: &mut Context<Self>) -> impl IntoElement {
        // Read the cached config (no per-frame `load_config()`).
        let config = &self.cached_config;
        let ui = crate::theme::ui_colors();

        // Effective state, not the raw key: an absent key defaults to
        // "shown only if the agent's CLI is installed" (see
        // `TerminalAgent::is_visible`). Toggling writes an explicit
        // `Some(..)` that pins the choice regardless of install state.
        let bypass = config.claude_code_bypass_permissions.unwrap_or(false);
        // EP-003 US-009 (agent-control-plane): AI free-access mode + the
        // independent injection fence. Defaults: unrestricted OFF, fence ON.
        let unrestricted = config.ai_unrestricted_enabled();
        let fence = config.ai_injection_fence_enabled();

        let commands_card = setting_card(ui)
            .child(self.agent_command_row(
                AgentCommandField::ClaudeCode,
                config.resolved_claude_code_command().to_string(),
                ui,
                cx,
            ))
            .child(hairline(ui))
            .child(self.agent_command_row(
                AgentCommandField::Codex,
                config.resolved_codex_command().to_string(),
                ui,
                cx,
            ));
        let commands_section = div()
            .flex()
            .flex_col()
            .child(section_header(ui, "Launch commands"))
            .child(commands_card)
            .when_some(self.ai_agent_command_status.clone(), |section, status| {
                section.child(
                    div()
                        .pt(px(8.))
                        .text_size(px(11.))
                        .text_color(ui.muted)
                        .child(status),
                )
            });

        let mut buttons_card = setting_card(ui);
        for (idx, row) in AGENT_TOGGLE_ROWS.iter().enumerate() {
            if idx > 0 {
                buttons_card = buttons_card.child(hairline(ui));
            }
            buttons_card = buttons_card.child(setting_row(
                row.id,
                row.title,
                row.description,
                Some(row.agent),
                row.agent.is_visible(config),
                row.config_key,
                ui,
                cx,
            ));
        }

        let buttons_section = div()
            .mt(px(24.))
            .flex()
            .flex_col()
            .child(section_header(ui, "Tab bar buttons"))
            .child(buttons_card);

        let permissions_card = setting_card(ui).child(setting_row(
            "row-claude-bypass",
            "Bypass permissions",
            "Adds --permission-mode bypassPermissions whenever AgentWorkspace \
             launches Claude Code in a terminal (tab-bar button and the \
             Agents-view thread picker). Anthropic warns this mode offers \
             no protection against prompt injection - only enable on \
             machines you trust.",
            None,
            bypass,
            "claude_code_bypass_permissions",
            ui,
            cx,
        ));

        let permissions_section = div()
            .mt(px(24.))
            .flex()
            .flex_col()
            .child(section_header(ui, "Permissions"))
            .child(permissions_card);

        // EP-003 US-009: AI access (free-access mode + injection fence). The
        // fence sub-toggle only appears once free-access is on: with the mode
        // off, surface.read is always fenced and there is nothing to relax.
        let mut access_card = setting_card(ui).child(setting_row(
            "row-ai-unrestricted",
            "AI free access",
            "Lets a conductor (a CLI agent or external orchestrator) auto-submit \
             prompts to your other panes without the PANEFLOW_IPC_SCRIPTING env \
             gate. Off by default. Best on isolated worktrees or throwaway \
             branches: an agent driving its peers has a wide blast radius. Every \
             write it makes is logged.",
            None,
            unrestricted,
            "ai_unrestricted",
            ui,
            cx,
        ));
        if unrestricted {
            access_card = access_card.child(hairline(ui)).child(setting_row(
                "row-ai-injection-fence",
                "Injection fence",
                "Keeps a peer pane's output wrapped as untrusted when a conductor \
                 reads it (surface.read / paneflow read), so a malicious repo \
                 cannot hijack the conductor. On by default even here: it \
                 protects the AI, it does not restrict it. Turning it off opens a \
                 hijack vector that resuming control by hand will not catch in time.",
                None,
                fence,
                "ai_injection_fence",
                ui,
                cx,
            ));
            // AC #3: once the fence is OFF, surface the active risk in red so
            // the trade-off is explicit and impossible to miss.
            if !fence {
                access_card = access_card.child(hairline(ui)).child(
                    div()
                        .px(px(12.))
                        .py(px(8.))
                        .text_size(px(12.))
                        .text_color(rgb(0xE0_6C_75))
                        .child(
                            "Fence disabled: a malicious pane can redirect your \
                             conductor, and resuming control by hand will not undo \
                             a fast, silent injection. Re-enable it unless you fully \
                             trust every repo your agents read.",
                        ),
                );
            }
        }
        let access_section = div()
            .mt(px(24.))
            .flex()
            .flex_col()
            .child(section_header(ui, "AI access"))
            .child(access_card);

        div()
            .flex()
            .flex_col()
            .child(commands_section)
            .child(buttons_section)
            .child(permissions_section)
            .child(access_section)
            .child(div().h(px(180.)).flex_none())
    }

    /// 渲染单个完整命令输入行；Enter 与真正失焦才提交，行内恢复按钮不触发失焦保存。
    fn agent_command_row(
        &self,
        field: AgentCommandField,
        effective_command: String,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let input = self.agent_command_input(field);
        let focus_input = input.clone();
        let reset = secondary_button(
            field.reset_id(),
            "Restore default",
            ui,
            cx.listener(move |this, _: &ClickEvent, _window, cx| {
                this.reset_agent_command(field, cx);
            }),
        );

        div()
            .id(field.row_id())
            .flex()
            .flex_col()
            .gap(px(8.))
            .px(px(12.))
            .py(px(10.))
            .on_key_down(cx.listener(move |this, event: &KeyDownEvent, _window, cx| {
                if event.keystroke.key == "enter" {
                    this.commit_agent_command(field, cx);
                    cx.stop_propagation();
                }
            }))
            .on_mouse_down_out(cx.listener(move |this, _, window, cx| {
                if focus_input.read(cx).focus_handle.is_focused(window) {
                    this.commit_agent_command(field, cx);
                    window.blur();
                    cx.notify();
                }
            }))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_start()
                    .justify_between()
                    .gap(px(12.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(crate::ui_primitives::BODY)
                                    .font_weight(gpui::FontWeight::MEDIUM)
                                    .text_color(ui.text)
                                    .child(field.label()),
                            )
                            .child(
                                div()
                                    .text_size(crate::ui_primitives::LABEL_SM)
                                    .text_color(ui.muted)
                                    .child("Full command with optional arguments. Applies to new launches and resumes."),
                            ),
                    )
                    .child(reset),
            )
            .child(
                div()
                    .w_full()
                    .px(px(10.))
                    .py(px(7.))
                    .rounded(SETTINGS_CONTROL_CORNER_RADIUS)
                    .bg(ui.subtle)
                    .text_size(px(12.))
                    .text_color(ui.text)
                    .child(input),
            )
            .child(
                div()
                    .text_size(px(11.))
                    .text_color(ui.muted)
                    .child(format!("Effective: {effective_command}")),
            )
            .into_any_element()
    }
}

/// The agent's logo for its settings row, rendered identically to the tab
/// bar: multi-color logos via `img()` (native palette preserved), monochrome
/// logos via a `text_color`-tinted `svg()` mask (brand accent if any, else
/// the theme's primary text color).
fn agent_icon_el(agent: TerminalAgent, ui: crate::theme::UiColors) -> AnyElement {
    let path = SharedString::from(agent.icon_path());
    if agent.icon_multicolor() {
        img(path).size(px(18.)).flex_none().into_any_element()
    } else {
        let tint: Hsla = agent.accent().map(|c| rgb(c).into()).unwrap_or(ui.text);
        svg()
            .size(px(18.))
            .flex_none()
            .path(path)
            .text_color(tint)
            .into_any_element()
    }
}

#[allow(clippy::too_many_arguments)]
fn setting_row(
    id: &'static str,
    title: &'static str,
    description: &'static str,
    icon: Option<TerminalAgent>,
    current: bool,
    config_key: &'static str,
    ui: crate::theme::UiColors,
    cx: &mut Context<PaneFlowApp>,
) -> impl IntoElement {
    let target_value = !current;

    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(16.))
        .px(px(12.))
        .py(px(10.))
        .when_some(icon, |d, agent| d.child(agent_icon_el(agent, ui)))
        .child(setting_text(ui, title, description))
        .child(
            // Only the switch is interactive - the row no longer hovers/toggles.
            div()
                .id(SharedString::from(id))
                .flex_shrink_0()
                .cursor(CursorStyle::PointingHand)
                .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    // cache-mutate + notify + off-thread persist.
                    this.persist_setting(
                        false,
                        config_key,
                        serde_json::Value::Bool(target_value),
                        cx,
                    );
                }))
                .child(toggle_pill(current, ui)),
        )
}

#[cfg(test)]
mod tests {
    use super::normalize_agent_command_input;
    use paneflow_config::schema::PaneFlowConfig;

    #[test]
    fn command_input_accepts_arguments_quotes_and_utf8_boundary() {
        assert_eq!(
            normalize_agent_command_input(
                "  \"C:\\Program Files\\Claude\\claude.exe\" --profile work  "
            ),
            Ok(Some(
                "\"C:\\Program Files\\Claude\\claude.exe\" --profile work".to_string()
            ))
        );
        let boundary = "x".repeat(PaneFlowConfig::MAX_AGENT_COMMAND_BYTES);
        assert_eq!(normalize_agent_command_input(&boundary), Ok(Some(boundary)));
    }

    #[test]
    fn command_input_empty_restores_default_and_invalid_values_are_rejected() {
        assert_eq!(normalize_agent_command_input("   "), Ok(None));
        assert!(normalize_agent_command_input("claude\t--profile work").is_err());
        assert!(normalize_agent_command_input("claude\nsecond").is_err());
        assert!(
            normalize_agent_command_input(&"x".repeat(PaneFlowConfig::MAX_AGENT_COMMAND_BYTES + 1))
                .is_err()
        );
    }
}
