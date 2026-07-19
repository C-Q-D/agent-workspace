//! AgentWorkspace 对用户公开的稳定产品名称。
//!
//! 本模块只收敛跨 GUI、主题和通知复用的短常量，避免公开名称在多个界面
//! 漂移。内部 `paneflow-*` crate、兼容标记和辅助二进制不属于这里。

/// Windows 应用、About 与系统通知共同显示的产品名。
pub(crate) const PRODUCT_NAME: &str = "AgentWorkspace";

/// Windows 主程序和本地控制命令共用的 CLI 名称。
pub(crate) const CLI_NAME: &str = "agent-workspace";

/// 内置浅色主题的公开名称。
pub(crate) const LIGHT_THEME_NAME: &str = "AgentWorkspace Light";

/// 开源项目主页，是帮助菜单和其他公开链接的唯一仓库来源。
pub(crate) const REPOSITORY_URL: &str = "https://github.com/C-Q-D/agent-workspace";

/// 面向用户的项目说明入口。
pub(crate) const README_URL: &str = "https://github.com/C-Q-D/agent-workspace#readme";

/// 手动下载与更新失败回退共用的发布页。
pub(crate) const RELEASES_URL: &str = "https://github.com/C-Q-D/agent-workspace/releases";

/// 用户反馈与故障排查入口。
pub(crate) const ISSUES_URL: &str = "https://github.com/C-Q-D/agent-workspace/issues";

/// 自动更新默认读取的 GitHub 最新 Release API。
pub(crate) const LATEST_RELEASE_API_URL: &str =
    "https://api.github.com/repos/C-Q-D/agent-workspace/releases/latest";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_product_constants_are_stable() {
        assert_eq!(PRODUCT_NAME, "AgentWorkspace");
        assert_eq!(CLI_NAME, "agent-workspace");
        assert_eq!(LIGHT_THEME_NAME, "AgentWorkspace Light");
        assert_eq!(REPOSITORY_URL, "https://github.com/C-Q-D/agent-workspace");
        assert!(README_URL.starts_with(REPOSITORY_URL));
        assert!(RELEASES_URL.starts_with(REPOSITORY_URL));
        assert!(ISSUES_URL.starts_with(REPOSITORY_URL));
        assert_eq!(
            LATEST_RELEASE_API_URL,
            "https://api.github.com/repos/C-Q-D/agent-workspace/releases/latest"
        );
    }

    #[test]
    fn windows_public_sources_do_not_reference_upstream_links() {
        let sources = [
            include_str!("main.rs"),
            include_str!("app/profile_menu.rs"),
            include_str!("app/self_update_flow.rs"),
            include_str!("update/checker.rs"),
        ];
        for source in sources {
            assert!(!source.contains("ArthurDEV44/paneflow"));
            assert!(!source.contains("paneflow.dev"));
        }
    }

    #[test]
    fn windows_gui_sources_do_not_reintroduce_upstream_brand_phrases() {
        let sources = [
            include_str!("app/about_dialog.rs"),
            include_str!("app/profile_menu.rs"),
            include_str!("agents/notifications.rs"),
            include_str!("app/theme_picker.rs"),
            include_str!("theme/builtin.rs"),
            include_str!("theme/model.rs"),
            include_str!("settings/tabs/workspaces.rs"),
            include_str!("settings/tabs/terminal.rs"),
            include_str!("settings/tabs/ai_agent.rs"),
            include_str!("settings/tabs/notifications.rs"),
            include_str!("window_chrome/title_bar.rs"),
        ]
        .join("\n");

        // 这里只禁止明确面向用户的旧品牌短语；内部函数名、图标资源名和
        // 上游归属仍可保留，避免把产品改名扩大成无价值的全仓库重构。
        for forbidden in [
            "About Paneflow",
            ".child(\"Paneflow\")",
            ".appname(\"Paneflow\")",
            "set_string(\"DisplayName\", \"Paneflow\")",
            "PaneFlow Light",
            "Restart Paneflow",
            "while Paneflow is unfocused",
            "Paneflow does not submit",
            "PaneFlow default",
            "whenever Paneflow",
            "Paneflow's built-in renderer",
        ] {
            assert!(
                !sources.contains(forbidden),
                "仍包含旧公开品牌短语：{forbidden}"
            );
        }
    }
}
