//! AgentWorkspace 安装器、任务栏和系统通知共享的 Windows 应用身份。

#[cfg(any(target_os = "windows", test))]
pub(crate) const AGENT_WORKSPACE_WINDOWS_AUMID: &str = "CQD.AgentWorkspace";

/// 在窗口创建前设置进程级 AUMID，使任务栏分组、快捷方式与通知归属一致。
///
/// Windows API 返回失败 HRESULT 时保留十六进制错误码，便于诊断安装器或
/// Shell 身份不一致；函数不负责回退到 Paneflow 的旧身份。
#[cfg(target_os = "windows")]
pub(crate) fn ensure_process_app_user_model_id() -> Result<(), String> {
    let app_id = windows_wide_null(AGENT_WORKSPACE_WINDOWS_AUMID);
    let result = unsafe {
        windows_sys::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID(app_id.as_ptr())
    };
    if result < 0 {
        Err(format!(
            "SetCurrentProcessExplicitAppUserModelID({AGENT_WORKSPACE_WINDOWS_AUMID}) returned HRESULT 0x{:08X}",
            result as u32
        ))
    } else {
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn windows_wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_aumid_matches_wix_shortcut_identity() {
        let wix = include_str!("../../packaging/wix/main.wxs");
        let shortcut_identity =
            format!("Key='System.AppUserModel.ID' Value='{AGENT_WORKSPACE_WINDOWS_AUMID}'");

        assert!(
            wix.contains(&shortcut_identity),
            "Windows shortcut identity must match the process AUMID"
        );
    }

    #[test]
    fn wix_shortcut_uses_target_exe_icon() {
        let wix = include_str!("../../packaging/wix/main.wxs");
        let shortcut = wix
            .split("<Shortcut Id='ApplicationStartMenuShortcut'")
            .nth(1)
            .and_then(|rest| rest.split("</Shortcut>").next())
            .expect("ApplicationStartMenuShortcut block should exist");

        assert!(
            shortcut.contains("Target='[APPLICATIONFOLDER]agent-workspace.exe'"),
            "Start Menu shortcut should target the installed exe"
        );
        assert!(
            !shortcut.contains("Target='[APPLICATIONFOLDER]paneflow.exe'"),
            "Start Menu shortcut must not target the upstream executable"
        );
        assert!(
            !shortcut.contains("Icon='"),
            "Start Menu shortcut must use the exe icon, not an MSI icon-table path"
        );
    }

    #[test]
    fn wix_uses_independent_agent_workspace_product_line() {
        let wix = include_str!("../../packaging/wix/main.wxs");
        let manifest = include_str!("../Cargo.toml");
        let workspace_manifest = include_str!("../../Cargo.toml");

        // 安装器、Cargo 打包元数据与公开仓库必须属于同一独立产品线；内部
        // helper 文件名可以暂时保留，但不能复用 Paneflow 的主程序身份。
        for expected in [
            "Name='AgentWorkspace'",
            "Manufacturer='C-Q-D'",
            "UpgradeCode='7D0C2220-1B4E-4E86-9D5E-AC3479C95B23'",
            "Key='Software\\C-Q-D\\AgentWorkspace'",
        ] {
            assert!(wix.contains(expected), "WIX missing identity: {expected}");
        }
        assert!(!wix.contains("Name='PaneFlow'"));
        assert!(!wix.contains("Manufacturer='Strivex'"));
        assert!(manifest.contains("name = \"agent-workspace\""));
        assert!(manifest.contains("upgrade-guid = \"7D0C2220-1B4E-4E86-9D5E-AC3479C95B23\""));
        assert!(workspace_manifest.contains("https://github.com/C-Q-D/agent-workspace"));
    }

    #[test]
    fn windows_public_icon_chain_uses_agent_workspace_assets() {
        let wix = include_str!("../../packaging/wix/main.wxs");
        let build_script = include_str!("../build.rs");
        let about_dialog = include_str!("app/about_dialog.rs");
        let notifications = include_str!("agents/notifications.rs");

        // 四个公开入口必须使用同名 AgentWorkspace 资产，防止后续改动只更新
        // 窗口或安装器的一部分，重新出现任务栏与 About 图标不一致。
        assert!(build_script.contains("join(\"AgentWorkspace.ico\")"));
        assert!(!build_script.contains("join(\"PaneFlow.ico\")"));
        assert!(wix.contains(
            "<Icon Id='AgentWorkspaceICO' SourceFile='packaging/wix/agent-workspace.ico'/>"
        ));
        assert!(wix.contains("<Property Id='ARPPRODUCTICON' Value='AgentWorkspaceICO'/>"));
        assert!(!wix.contains("packaging/wix/paneflow.ico"));
        assert!(about_dialog.contains("icons/agent-workspace.png"));
        assert!(!about_dialog.contains("icons/paneflow.png"));
        assert!(notifications.contains("icons/agent-workspace.png"));
        assert!(notifications.contains("agent-workspace-notification.png"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_wide_null_is_null_terminated() {
        let wide = windows_wide_null(AGENT_WORKSPACE_WINDOWS_AUMID);

        assert_eq!(wide.last(), Some(&0));
        assert_eq!(
            wide.iter().filter(|unit| **unit == 0).count(),
            1,
            "AUMID should contain a single trailing nul"
        );
    }
}
