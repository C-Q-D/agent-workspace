//! 管理匿名安装遥测标识。
//!
//! 调用方必须传入完整文件路径，目录归属由上层统一用户数据布局决定。本模块
//! 只负责读取或首次创建 UUID v4，不推测平台目录，也不读取任何旧命名空间。
//! 文件损坏、已有文件不可读或父目录不可写时，返回仅当前进程使用的临时 ID，
//! 并且不会覆盖用户已有文件。

use std::io::Write;
use std::path::Path;

use uuid::Uuid;

/// 读取或初始化指定路径的遥测标识文件。
///
/// 返回 `(id, is_first_run)`：只有当前调用成功新建并完整写入文件时，
/// `is_first_run` 才为 `true`。缺失的父目录会按需创建；已有损坏或不可读文件
/// 保持原样，写入失败则降级为临时 UUID，避免每次启动重复计算首次运行事件。
pub fn telemetry_id_at_path(file: &Path) -> (String, bool) {
    match std::fs::read_to_string(file) {
        Ok(contents) => return id_from_existing_contents(file, &contents),
        Err(error) if file.exists() => {
            return (
                ephemeral_id(&format!(
                    "无法读取已有 telemetry_id 文件 {}：{error}",
                    file.display()
                )),
                false,
            );
        }
        Err(_) => {}
    }

    let Some(parent) = file.parent().filter(|path| !path.as_os_str().is_empty()) else {
        return (ephemeral_id("telemetry_id 路径没有可创建的父目录"), false);
    };
    if let Err(error) = std::fs::create_dir_all(parent) {
        return (
            ephemeral_id(&format!(
                "无法创建 telemetry_id 父目录 {}：{error}",
                parent.display()
            )),
            false,
        );
    }

    let fresh = Uuid::new_v4().to_string();
    let mut output = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(file)
    {
        Ok(output) => output,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            // 并发首次启动时另一个调用方可能已抢先创建文件；重新读取其值，
            // 避免当前进程使用与磁盘不同的安装标识。
            return match std::fs::read_to_string(file) {
                Ok(contents) => id_from_existing_contents(file, &contents),
                Err(read_error) => (
                    ephemeral_id(&format!(
                        "并发创建后无法读取 telemetry_id 文件 {}：{read_error}",
                        file.display()
                    )),
                    false,
                ),
            };
        }
        Err(error) => {
            log::debug!(
                "agent-workspace: 无法持久化 telemetry_id 到 {}（{error}），本次会话使用临时 ID",
                file.display()
            );
            return (fresh, false);
        }
    };

    match output.write_all(fresh.as_bytes()) {
        Ok(()) => (fresh, true),
        Err(error) => {
            // 只有 create_new 成功后才会进入这里，因此残缺文件属于本次调用，
            // 可以安全尝试删除；删除失败也保持降级，不继续覆盖文件。
            drop(output);
            let _ = std::fs::remove_file(file);
            log::debug!(
                "agent-workspace: 无法完整写入 telemetry_id 到 {}（{error}），本次会话使用临时 ID",
                file.display()
            );
            (fresh, false)
        }
    }
}

/// 解析已有文件内容；无效内容保持原样并降级为临时 ID。
fn id_from_existing_contents(file: &Path, contents: &str) -> (String, bool) {
    let trimmed = contents.trim();
    if Uuid::parse_str(trimmed).is_ok() {
        return (trimmed.to_string(), false);
    }
    (
        ephemeral_id(&format!(
            "telemetry_id 文件 {} 不是有效 UUID",
            file.display()
        )),
        false,
    )
}

/// 返回仅当前进程使用的 UUID v4，并以 DEBUG 记录降级原因。
pub fn ephemeral_id(reason: &str) -> String {
    log::debug!("agent-workspace: 遥测标识降级为会话状态（{reason}）");
    Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn parses_as_uuid(value: &str) -> bool {
        Uuid::parse_str(value).is_ok()
    }

    #[test]
    fn first_call_creates_parent_and_file_with_v4_uuid() {
        let sandbox = TempDir::new().expect("应能创建真实临时目录");
        let file = sandbox.path().join("state").join("telemetry_id");

        let (id, first_run) = telemetry_id_at_path(&file);

        assert!(parses_as_uuid(&id));
        assert!(first_run, "首次成功持久化必须报告首次运行");
        assert_eq!(fs::read_to_string(&file).expect("标识文件应存在"), id);
        assert_eq!(
            Uuid::parse_str(&id).expect("应为 UUID").get_version_num(),
            4
        );
    }

    #[test]
    fn second_call_returns_same_persisted_id() {
        let sandbox = TempDir::new().expect("应能创建真实临时目录");
        let file = sandbox.path().join("state/telemetry_id");

        let (first_id, first_flag) = telemetry_id_at_path(&file);
        let (second_id, second_flag) = telemetry_id_at_path(&file);

        assert_eq!(first_id, second_id);
        assert!(first_flag);
        assert!(!second_flag);
    }

    #[test]
    fn corrupt_file_yields_ephemeral_id_and_preserves_bytes() {
        let sandbox = TempDir::new().expect("应能创建真实临时目录");
        let file = sandbox.path().join("state/telemetry_id");
        fs::create_dir_all(file.parent().expect("必须有父目录")).unwrap();
        fs::write(&file, b"not-a-uuid-garbage").unwrap();

        let (id, first_run) = telemetry_id_at_path(&file);

        assert!(parses_as_uuid(&id));
        assert!(!first_run);
        assert_eq!(fs::read(&file).unwrap(), b"not-a-uuid-garbage");
    }

    #[test]
    fn blocked_parent_yields_ephemeral_id_without_overwriting_blocker() {
        let sandbox = TempDir::new().expect("应能创建真实临时目录");
        let blocker = sandbox.path().join("state");
        fs::write(&blocker, b"parent-is-a-file").unwrap();
        let file = blocker.join("telemetry_id");

        let (id, first_run) = telemetry_id_at_path(&file);

        assert!(parses_as_uuid(&id));
        assert!(!first_run);
        assert!(!file.exists());
        assert_eq!(fs::read(&blocker).unwrap(), b"parent-is-a-file");
    }

    #[test]
    fn path_without_parent_yields_ephemeral_id() {
        let (id, first_run) = telemetry_id_at_path(Path::new("telemetry_id"));
        assert!(parses_as_uuid(&id));
        assert!(!first_run);
    }

    #[test]
    fn ephemeral_id_returns_valid_uuid() {
        assert!(parses_as_uuid(&ephemeral_id("测试降级")));
    }
}
