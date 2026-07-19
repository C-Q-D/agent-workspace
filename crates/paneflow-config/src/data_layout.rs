//! AgentWorkspace 用户数据目录的纯路径布局。
//!
//! 本模块只计算路径，不访问文件系统。配置、会话、内部状态、稳定二进制、
//! 可重建缓存与日志都从同一个用户主目录派生，调用方无需了解根目录命名，
//! 也不能回退到 Paneflow 的旧 AppData 或当前工作目录。

use std::path::{Path, PathBuf};

/// 发布构建使用的用户数据根目录名。
pub const RELEASE_USER_DATA_DIRNAME: &str = ".agent-workspace";
/// 调试构建使用的用户数据根目录名，避免源码运行覆盖已安装版本。
pub const DEBUG_USER_DATA_DIRNAME: &str = ".agent-workspace-dev";

/// 当前构建实际使用的用户数据根目录名。
pub const USER_DATA_DIRNAME: &str = if cfg!(debug_assertions) {
    DEBUG_USER_DATA_DIRNAME
} else {
    RELEASE_USER_DATA_DIRNAME
};

/// 用户显式设置目录名。
pub const CONFIG_DIRNAME: &str = "config";
/// 工作区会话与损坏备份目录名。
pub const SESSIONS_DIRNAME: &str = "sessions";
/// 应用内部持久状态目录名。
pub const STATE_DIRNAME: &str = "state";
/// 被外部 CLI 配置稳定引用的二进制目录名。
pub const BIN_DIRNAME: &str = "bin";
/// 可安全删除并重建的缓存目录名。
pub const CACHE_DIRNAME: &str = "cache";
/// 可导出和按策略清理的文件日志目录名。
pub const LOGS_DIRNAME: &str = "logs";

/// AgentWorkspace 主设置文件名。
pub const SETTINGS_FILENAME: &str = "settings.json";
/// AgentWorkspace 工作区会话文件名。
pub const WORKSPACES_FILENAME: &str = "workspaces.json";
/// 匿名安装遥测标识文件名。
pub const TELEMETRY_ID_FILENAME: &str = "telemetry_id";
/// Markdown 可重建视图状态文件名。
pub const MARKDOWN_STATE_FILENAME: &str = "markdown_state.json";
/// Windows 通知图标缓存文件名。
pub const NOTIFICATION_ICON_FILENAME: &str = "agent-workspace-notification.png";

/// 单个用户主目录下的 AgentWorkspace 自有数据布局。
///
/// 该类型只持有根路径；所有分类路径都在调用时计算，克隆成本低且不会创建
/// 空目录。用户项目、Git worktree 及 Codex/Claude 自有目录不属于此布局。
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserDataLayout {
    root: PathBuf,
}

impl UserDataLayout {
    /// 使用当前构建的发布/调试根名从用户主目录创建布局。
    pub fn from_home(home: &Path) -> Self {
        Self::from_home_with_root_name(home, USER_DATA_DIRNAME)
    }

    /// 使用明确根名创建布局，供发布/调试契约测试和受控工具使用。
    ///
    /// `root_name` 必须由产品内部常量提供；生产调用方应使用 [`Self::from_home`]。
    pub fn from_home_with_root_name(home: &Path, root_name: &str) -> Self {
        debug_assert!(!root_name.is_empty());
        debug_assert_eq!(Path::new(root_name).components().count(), 1);
        Self {
            root: home.join(root_name),
        }
    }

    /// 返回 AgentWorkspace 自有数据根目录。
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 返回用户显式设置目录。
    pub fn config_dir(&self) -> PathBuf {
        self.root.join(CONFIG_DIRNAME)
    }

    /// 返回工作区会话与损坏备份目录。
    pub fn sessions_dir(&self) -> PathBuf {
        self.root.join(SESSIONS_DIRNAME)
    }

    /// 返回应用内部持久状态目录。
    pub fn state_dir(&self) -> PathBuf {
        self.root.join(STATE_DIRNAME)
    }

    /// 返回被外部 CLI 配置引用的稳定二进制目录。
    pub fn bin_dir(&self) -> PathBuf {
        self.root.join(BIN_DIRNAME)
    }

    /// 返回可安全删除并按需重建的缓存目录。
    pub fn cache_dir(&self) -> PathBuf {
        self.root.join(CACHE_DIRNAME)
    }

    /// 返回文件日志目录。
    pub fn logs_dir(&self) -> PathBuf {
        self.root.join(LOGS_DIRNAME)
    }

    /// 返回主设置文件路径。
    pub fn settings_path(&self) -> PathBuf {
        self.config_dir().join(SETTINGS_FILENAME)
    }

    /// 返回工作区会话文件路径。
    pub fn workspaces_path(&self) -> PathBuf {
        self.sessions_dir().join(WORKSPACES_FILENAME)
    }

    /// 返回匿名安装遥测标识路径。
    pub fn telemetry_id_path(&self) -> PathBuf {
        self.state_dir().join(TELEMETRY_ID_FILENAME)
    }

    /// 返回 Markdown 可重建视图状态路径。
    pub fn markdown_state_path(&self) -> PathBuf {
        self.cache_dir().join(MARKDOWN_STATE_FILENAME)
    }

    /// 返回 Windows 通知图标缓存路径。
    pub fn notification_icon_path(&self) -> PathBuf {
        self.cache_dir()
            .join("icons")
            .join(NOTIFICATION_ICON_FILENAME)
    }

    /// 返回 shell 集成脚本缓存目录。
    pub fn shell_integration_dir(&self) -> PathBuf {
        self.cache_dir().join("shell")
    }

    /// 返回版本化 CLI helper 缓存的父目录。
    pub fn helper_cache_dir(&self) -> PathBuf {
        self.cache_dir().join("bin")
    }

    /// 返回 Windows 更新下载和 relay staging 缓存目录。
    pub fn update_cache_dir(&self) -> PathBuf {
        self.cache_dir().join("update")
    }

    /// 返回 Windows 更新与 relay 文件日志目录。
    pub fn update_logs_dir(&self) -> PathBuf {
        self.logs_dir().join("update")
    }

    /// 返回备份、升级和卸载边界必须保留的 durable 目录。
    ///
    /// `bin/` 虽然内容可由应用重新释放，但外部 CLI 配置会稳定引用其中路径，
    /// 因而不能与普通缓存一起清理。
    pub fn durable_directories(&self) -> [PathBuf; 4] {
        [
            self.config_dir(),
            self.sessions_dir(),
            self.state_dir(),
            self.bin_dir(),
        ]
    }

    /// 返回可安全删除并由应用按需重建的目录。
    pub fn rebuildable_directories(&self) -> [PathBuf; 1] {
        [self.cache_dir()]
    }

    /// 返回用于诊断导出和独立清理策略的日志目录。
    pub fn diagnostic_directories(&self) -> [PathBuf; 1] {
        [self.logs_dir()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    #[test]
    fn release_and_debug_roots_are_explicit_and_distinct() {
        let home = Path::new("C:/Users/TestUser");
        let release = UserDataLayout::from_home_with_root_name(home, RELEASE_USER_DATA_DIRNAME);
        let debug = UserDataLayout::from_home_with_root_name(home, DEBUG_USER_DATA_DIRNAME);

        assert_eq!(release.root(), home.join(".agent-workspace"));
        assert_eq!(debug.root(), home.join(".agent-workspace-dev"));
        assert_ne!(release.root(), debug.root());
    }

    #[test]
    fn top_level_categories_share_one_root_without_overlap() {
        let layout = UserDataLayout::from_home(Path::new("C:/Users/TestUser"));
        let directories = [
            layout.config_dir(),
            layout.sessions_dir(),
            layout.state_dir(),
            layout.bin_dir(),
            layout.cache_dir(),
            layout.logs_dir(),
        ];
        let unique: HashSet<_> = directories.iter().collect();

        assert_eq!(unique.len(), directories.len());
        assert!(directories
            .iter()
            .all(|directory| directory.starts_with(layout.root())));
    }

    #[test]
    fn known_files_belong_to_their_declared_lifecycle_directories() {
        let layout = UserDataLayout::from_home(Path::new("C:/Users/TestUser"));

        assert_eq!(
            layout.settings_path().parent(),
            Some(layout.config_dir().as_path())
        );
        assert_eq!(
            layout.workspaces_path().parent(),
            Some(layout.sessions_dir().as_path())
        );
        assert_eq!(
            layout.telemetry_id_path().parent(),
            Some(layout.state_dir().as_path())
        );
        for rebuildable in [
            layout.markdown_state_path(),
            layout.notification_icon_path(),
            layout.shell_integration_dir(),
            layout.helper_cache_dir(),
            layout.update_cache_dir(),
        ] {
            assert!(rebuildable.starts_with(layout.cache_dir()));
        }
        assert!(layout.update_logs_dir().starts_with(layout.logs_dir()));
    }

    #[test]
    fn layout_never_uses_legacy_paneflow_namespace() {
        let layout = UserDataLayout::from_home(Path::new("C:/Users/TestUser"));
        for path in [
            layout.root().to_path_buf(),
            layout.settings_path(),
            layout.workspaces_path(),
            layout.telemetry_id_path(),
            layout.notification_icon_path(),
            layout.update_cache_dir(),
            layout.update_logs_dir(),
        ] {
            let rendered = path.to_string_lossy().to_ascii_lowercase();
            assert!(rendered.contains("agent-workspace"));
            assert!(!rendered.contains("paneflow"));
        }
    }

    #[test]
    fn lifecycle_classification_covers_each_top_level_directory_once() {
        let layout = UserDataLayout::from_home(Path::new("C:/Users/TestUser"));
        let durable = layout.durable_directories();
        let rebuildable = layout.rebuildable_directories();
        let diagnostic = layout.diagnostic_directories();
        let classified: Vec<_> = durable
            .iter()
            .chain(rebuildable.iter())
            .chain(diagnostic.iter())
            .collect();
        let unique: HashSet<_> = classified.iter().copied().collect();

        assert_eq!(classified.len(), 6);
        assert_eq!(unique.len(), classified.len());
        assert!(durable.contains(&layout.bin_dir()));
        assert!(!rebuildable.contains(&layout.bin_dir()));
        assert_eq!(rebuildable, [layout.cache_dir()]);
        assert_eq!(diagnostic, [layout.logs_dir()]);
    }

    #[test]
    fn real_cache_cleanup_preserves_durable_logs_and_legacy_data() {
        // 使用真实文件系统创建完整分类树；缓存清理只删除布局明确标记的
        // rebuildable 目录，不通过内存替身模拟文件生命周期。
        let sandbox = tempfile::TempDir::new().expect("应能创建真实临时用户目录");
        let home = sandbox.path().join("用户主目录");
        let layout = UserDataLayout::from_home_with_root_name(&home, RELEASE_USER_DATA_DIRNAME);
        let legacy_root = home.join("AppData/Local/paneflow");
        let legacy_sentinel = legacy_root.join("旧数据不得修改.txt");
        std::fs::create_dir_all(&legacy_root).expect("应能创建旧数据哨兵目录");
        std::fs::write(&legacy_sentinel, b"legacy-paneflow-bytes").expect("应能写入旧数据哨兵");

        let classified_files = [
            (layout.settings_path(), b"settings".as_slice()),
            (layout.workspaces_path(), b"workspaces".as_slice()),
            (layout.telemetry_id_path(), b"telemetry-id".as_slice()),
            (
                layout.bin_dir().join("paneflow-mcp.exe"),
                b"stable-bin".as_slice(),
            ),
            (layout.markdown_state_path(), b"markdown-cache".as_slice()),
            (
                layout.update_logs_dir().join("update.log"),
                b"diagnostic-log".as_slice(),
            ),
        ];
        for (path, bytes) in &classified_files {
            std::fs::create_dir_all(path.parent().expect("分类文件必须有父目录"))
                .expect("应能创建分类目录");
            std::fs::write(path, bytes).expect("应能写入分类文件");
        }
        let preserved_before: HashMap<_, _> = classified_files
            .iter()
            .filter(|(path, _)| !path.starts_with(layout.cache_dir()))
            .map(|(path, _)| {
                (
                    path.clone(),
                    std::fs::read(path).expect("应能读取清理前文件"),
                )
            })
            .collect();

        for cache_dir in layout.rebuildable_directories() {
            std::fs::remove_dir_all(cache_dir).expect("应能只删除可重建缓存目录");
        }

        assert!(!layout.cache_dir().exists());
        for (path, expected) in preserved_before {
            assert_eq!(
                std::fs::read(&path).expect("缓存清理后 durable/log 文件必须存在"),
                expected,
                "缓存清理不应修改 {}",
                path.display()
            );
        }
        assert_eq!(
            std::fs::read(&legacy_sentinel).expect("旧数据哨兵必须存在"),
            b"legacy-paneflow-bytes"
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_paths_have_stable_expected_shape() {
        let layout = UserDataLayout::from_home(Path::new(r"C:\Users\测试用户"));
        assert_eq!(
            layout.workspaces_path(),
            PathBuf::from(r"C:\Users\测试用户")
                .join(USER_DATA_DIRNAME)
                .join("sessions")
                .join("workspaces.json")
        );
        assert_eq!(
            layout.update_logs_dir(),
            PathBuf::from(r"C:\Users\测试用户")
                .join(USER_DATA_DIRNAME)
                .join("logs")
                .join("update")
        );
    }
}
