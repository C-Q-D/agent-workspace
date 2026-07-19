//! 工作区创建与会话恢复共享的生命周期边界。
//!
//! 本模块先集中稳定 `workspaceRoot` 的恢复规划；后续 Git 准备、watcher 登记和
//! 持久化回执也由同一接缝承载。这里的纯规划接口不创建 PTY、不访问 GPUI 实体，
//! 因此会话输入边界可以用真实文件系统独立验证。

use std::path::PathBuf;

/// 一个已经通过恢复入口校验的稳定工作区根目录。
///
/// 标题和根目录成对返回，防止调用方在跳过失效条目后继续使用原会话的其他字段，
/// 或把目录替换成进程当前目录而悄悄改变窗口身份。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RestoredWorkspaceRoot {
    /// 会话中持久化的窗口标题，不根据进程启动目录重新推导。
    pub(crate) title: String,
    /// 会话中持久化且当前仍然存在的目录。
    pub(crate) workspace_root: PathBuf,
}

/// 工作区生命周期的单一应用层入口。
///
/// 该类型不保存运行时状态；它把跨显式创建和会话恢复的规则组织成小接口，隐藏
/// 根目录校验、稳定身份回执与异步 Git 登记的具体顺序。
pub(crate) struct WorkspaceLifecycle;

impl WorkspaceLifecycle {
    /// 把一条持久化工作区记录规划为可恢复的稳定根目录。
    ///
    /// 只有仍存在的目录可以恢复。缺失路径、普通文件或不可读取为目录的路径均返回
    /// `None`，由上层只跳过该窗口；禁止回退到进程当前目录，因为那会让文件树、
    /// 路径引用和 Git 审查悄悄绑定到另一个仓库。
    pub(crate) fn plan_restored_root(
        title: &str,
        persisted_root: &str,
    ) -> Option<RestoredWorkspaceRoot> {
        let workspace_root = PathBuf::from(persisted_root);
        if !workspace_root.is_dir() {
            log::warn!(
                "session restore: workspace root {} is unavailable; skipping this workspace",
                workspace_root.display()
            );
            return None;
        }

        Some(RestoredWorkspaceRoot {
            title: title.to_string(),
            workspace_root,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::WorkspaceLifecycle;

    /// 有效目录必须保持原始标题和根目录，不能重新解释为启动目录。
    #[test]
    fn restored_root_preserves_existing_directory_identity() {
        let dir = tempfile::tempdir().expect("应能创建真实工作区目录");
        let root = dir.path().to_string_lossy().into_owned();

        let plan = WorkspaceLifecycle::plan_restored_root("Workspace A", &root)
            .expect("有效目录应生成恢复计划");

        assert_eq!(plan.title, "Workspace A");
        assert_eq!(plan.workspace_root, dir.path());
    }

    /// 缺失目录和普通文件都不能被替换为任意可用目录。
    #[test]
    fn restored_root_skips_missing_and_non_directory_paths() {
        let dir = tempfile::tempdir().expect("应能创建真实临时目录");
        let missing = dir.path().join("missing");
        let file = dir.path().join("not-a-workspace.txt");
        std::fs::write(&file, "真实文件").expect("应能创建普通文件边界");

        assert!(
            WorkspaceLifecycle::plan_restored_root("Missing", &missing.to_string_lossy()).is_none()
        );
        assert!(WorkspaceLifecycle::plan_restored_root("File", &file.to_string_lossy()).is_none());
    }

    /// 文件系统根目录如果确实被用户保存，仍是合法且稳定的工作区身份。
    #[test]
    fn restored_root_does_not_repair_numbered_title_to_process_cwd() {
        let root = std::env::current_dir()
            .expect("应能读取当前目录")
            .ancestors()
            .last()
            .expect("当前目录应具有文件系统根")
            .to_path_buf();

        let plan = WorkspaceLifecycle::plan_restored_root("Terminal 1", &root.to_string_lossy())
            .expect("真实根目录仍应可恢复");

        assert_eq!(plan.title, "Terminal 1");
        assert_eq!(plan.workspace_root, root);
    }
}
