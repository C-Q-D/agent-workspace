//! 把桌面应用的统一用户数据布局接入遥测安装标识。
//!
//! 对外函数保持不变；本模块只解析 `UserDataLayout` 并把完整
//! `state/telemetry_id` 路径交给遥测 crate。无法解析用户主目录时继续使用
//! 仅当前进程有效的临时 UUID，不回退到数据根旧文件或 Paneflow 旧目录。

use paneflow_config::data_layout::UserDataLayout;

use crate::runtime_paths;

/// 返回当前安装稳定的匿名遥测 UUID。
///
/// 首次调用会按需创建 `state/` 并写入 `state/telemetry_id`；读取或写入失败
/// 时返回临时 UUID，应用其余功能继续运行。
pub fn telemetry_id() -> String {
    telemetry_id_with_first_run().0
}

/// 返回遥测 UUID 及其是否由本次调用首次成功持久化。
///
/// 只有文件确实新建成功时第二项才为 `true`，降级路径不会重复上报首次运行。
pub fn telemetry_id_with_first_run() -> (String, bool) {
    match runtime_paths::user_data_layout() {
        Some(layout) => telemetry_id_for_layout(&layout),
        None => (
            paneflow_telemetry::id::ephemeral_id("无法解析 AgentWorkspace 用户数据布局"),
            false,
        ),
    }
}

/// 使用明确布局生成遥测 ID，供生产入口与真实文件系统边界测试共享。
fn telemetry_id_for_layout(layout: &UserDataLayout) -> (String, bool) {
    paneflow_telemetry::id::telemetry_id_at_path(&layout.telemetry_id_path())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn layout_writes_only_state_and_preserves_legacy_sentinels() {
        let sandbox = tempfile::TempDir::new().expect("应能创建真实临时用户目录");
        let home = sandbox.path().join("用户目录");
        let layout = UserDataLayout::from_home(&home);
        let root_legacy = layout.root().join("telemetry_id");
        let paneflow_legacy = home.join("AppData/Local/paneflow/telemetry_id");
        for sentinel in [&root_legacy, &paneflow_legacy] {
            fs::create_dir_all(sentinel.parent().expect("哨兵必须有父目录")).unwrap();
            fs::write(sentinel, b"legacy-sentinel").unwrap();
        }

        let (id, first_run) = telemetry_id_for_layout(&layout);

        assert!(uuid::Uuid::parse_str(&id).is_ok());
        assert!(first_run);
        assert_eq!(fs::read_to_string(layout.telemetry_id_path()).unwrap(), id);
        assert_eq!(fs::read(&root_legacy).unwrap(), b"legacy-sentinel");
        assert_eq!(fs::read(&paneflow_legacy).unwrap(), b"legacy-sentinel");
    }
}
