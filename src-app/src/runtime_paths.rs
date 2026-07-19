//! 解析 AgentWorkspace 的运行时目录、持久数据根目录与本地 IPC 端点。
//!
//! 用户持久数据统一归属 `~/.agent-workspace`；调试版使用
//! `~/.agent-workspace-dev`。Unix IPC 仍遵守 `sun_path` 长度限制，Windows
//! 使用命名管道；两端默认命名空间必须一致，避免与上游 Paneflow 冲突。
//!
//! Public helpers:
//! - `ipc::start_server` consumes `socket_path()` for the main JSON-RPC socket,
//! - `terminal::paneflow_socket_path` propagates the same path as the
//!   `PANEFLOW_SOCKET_PATH` env var passed into each PTY child shell.
//!
//! Keeping the chain in one place prevents the two sites from drifting -
//! a difference in one branch would silently break IPC on macOS
//! without any visible error.
//!
//! US-013 removed the former third consumer (the AI-hook wrapper-scripts
//! bin-dir helper) along with its call sites - the extraction targets
//! never existed in the embed set, so the helper and its PATH-injection
//! caller were dead code.
//!
//! `PANEFLOW_SOCKET_PATH` overrides the computed path on every platform so
//! isolated debug/test instances and panes launched from a running instance
//! agree on the exact IPC endpoint. Without this, clients can point at one pipe
//! while the server keeps binding the default one.
//!
//! Windows 默认端点为 `\\.\pipe\agent-workspace`，调试版追加 `-dev`；
//! Unix 继续使用 XDG/TMPDIR 回退链和路径长度保护。

use std::path::{Path, PathBuf};

/// macOS `sockaddr_un.sun_path` is `[c_char; 104]`. Linux allows 108, but
/// using the smaller ceiling keeps paths portable across both targets.
/// Unused on Windows (named pipes are limited to 256 chars, well above
/// anything we compose).
#[cfg(unix)]
pub(crate) const MAX_SOCKET_PATH_BYTES: usize = 104;

/// 运行时与 IPC 使用的公开命名空间，不包含用户目录前导点。
///
/// 调试版与发布版保持隔离；该常量也供仍使用平台缓存的非 Windows 更新模块
/// 复用，但持久数据根目录由 `paneflow_config::loader` 单独解析。
pub const APP_SUBDIR: &str = if cfg!(debug_assertions) {
    "agent-workspace-dev"
} else {
    "agent-workspace"
};

#[cfg(unix)]
const APP_RUNTIME_SUBDIR: &str = APP_SUBDIR;
/// Socket filename, namespaced per build profile so a `cargo run` debug
/// instance and an installed release instance can coexist on the same host
/// without one silently stealing the other's socket. Each instance binds
/// its own listener and the AI-hook wrapper scripts (which read
/// `PANEFLOW_SOCKET_PATH` from the PTY env) route to the right one.
#[cfg(unix)]
const SOCKET_FILE: &str = if cfg!(debug_assertions) {
    "agent-workspace-dev.sock"
} else {
    "agent-workspace.sock"
};

/// IPC endpoint plus ownership metadata for the server-side binder.
///
/// `PANEFLOW_SOCKET_PATH` is useful for tests and intentionally isolated debug
/// instances, but the path belongs to the caller, not Paneflow. The IPC server
/// must therefore not create/chmod its parent directory or reclaim a non-socket
/// file there. The default path is Paneflow-owned and may be prepared by the
/// server before bind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IpcSocketPath {
    path: PathBuf,
    owned_parent: bool,
}

impl IpcSocketPath {
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(unix)]
    pub(crate) fn owned_parent(&self) -> bool {
        self.owned_parent
    }
}

/// Resolve the PaneFlow runtime directory. Fallback chain:
/// 1. `$XDG_RUNTIME_DIR` - explicit Linux XDG (usually `/run/user/<uid>`).
/// 2. `dirs::runtime_dir()` - same on Linux, `None` on macOS.
/// 3. `$TMPDIR` - populated on macOS (usually `/var/folders/xx/.../T/`).
/// 4. `dirs::cache_dir().join("run")` - last-resort cross-platform fallback.
///
/// Returns `None` only if every layer fails, which in practice means the
/// caller runs on an environment with neither XDG nor TMPDIR nor a cache
/// dir (e.g. a broken container). Callers should `log::warn!` and disable
/// IPC rather than panic.
#[cfg(unix)]
fn runtime_dir() -> Option<PathBuf> {
    std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(dirs::runtime_dir)
        .or_else(|| {
            std::env::var("TMPDIR")
                .ok()
                .map(PathBuf::from)
                .filter(|p| !p.as_os_str().is_empty())
        })
        .or_else(|| dirs::cache_dir().map(|d| d.join("run")))
}

/// Full path to the IPC socket.
///
/// Unix: `<runtime_dir>/paneflow/paneflow.sock`, or `None` if the runtime
/// dir cannot be resolved or the composed path would exceed the `sun_path`
/// limit. A `log::warn!` is emitted in the over-length case so the user
/// can see why IPC is disabled.
///
/// Windows (US-009): the named-pipe path `\\.\pipe\paneflow`, unconditionally.
/// Named pipes live in a global kernel namespace - there is no runtime dir
/// to resolve, no sun_path limit to enforce, and no XDG fallback chain.
#[cfg(unix)]
pub(crate) fn socket_path_spec() -> Option<IpcSocketPath> {
    if let Some(path) = socket_path_from_env(std::env::var_os("PANEFLOW_SOCKET_PATH")) {
        return check_sun_path_fits(&path).then_some(IpcSocketPath {
            path,
            owned_parent: false,
        });
    }
    let path = runtime_dir()?.join(APP_RUNTIME_SUBDIR).join(SOCKET_FILE);
    check_sun_path_fits(&path).then_some(IpcSocketPath {
        path,
        owned_parent: true,
    })
}

#[cfg(windows)]
pub(crate) fn socket_path_spec() -> Option<IpcSocketPath> {
    if let Some(path) = socket_path_from_env(std::env::var_os("PANEFLOW_SOCKET_PATH")) {
        return Some(IpcSocketPath {
            path,
            owned_parent: false,
        });
    }
    Some(IpcSocketPath {
        path: PathBuf::from(if cfg!(debug_assertions) {
            r"\\.\pipe\agent-workspace-dev"
        } else {
            r"\\.\pipe\agent-workspace"
        }),
        owned_parent: false,
    })
}

pub(crate) fn socket_path() -> Option<PathBuf> {
    socket_path_spec().map(|spec| spec.path)
}

/// 返回 Shell 集成脚本的可重建缓存目录，不创建目录。
pub(crate) fn shell_integration_dir() -> Option<PathBuf> {
    user_data_layout().map(|layout| layout.shell_integration_dir())
}

fn socket_path_from_env(raw: Option<std::ffi::OsString>) -> Option<PathBuf> {
    let path = PathBuf::from(raw?);
    path.is_absolute().then_some(path)
}

/// Prepend the common per-user `bin/` directories to the process `PATH`
/// so PATH-based lookups see binaries installed under the user's home - `~/.bun/bin`,
/// `~/.cargo/bin`, `~/.local/bin`, plus `/opt/homebrew/bin` on macOS.
///
/// Why: when Paneflow is launched from a `.desktop` file, Finder, or the
/// Windows Start Menu, it inherits the systemd-user / launchd / Explorer
/// PATH, which does NOT include `~/.bun/bin`. Agent launch and CLI helper
/// paths then fail to find user-installed tools even though they are available
/// in a normal terminal. Zed, VS Code, and most GUI dev tools all patch their
/// own PATH at startup for the same reason.
///
/// Dirs are prepended (not appended), so user installs always win over any
/// system-shadowed name. Existing entries in PATH are skipped - no
/// duplicates. Idempotent: safe to call multiple times.
///
/// Safety: mutates a process-global env var. Must be called from `main`
/// before any other thread is spawned (i.e. before GPUI initialises),
/// otherwise concurrent readers may observe a torn PATH. Rust 2024 marks
/// `set_var` as `unsafe` for this exact reason.
pub fn augment_path_for_gui_launch() {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join(".bun").join("bin"));
        candidates.push(home.join(".cargo").join("bin"));
        candidates.push(home.join(".local").join("bin"));
    }

    #[cfg(target_os = "macos")]
    {
        candidates.push(PathBuf::from("/opt/homebrew/bin"));
        candidates.push(PathBuf::from("/usr/local/bin"));
    }

    #[cfg(target_os = "windows")]
    {
        if let Some(home) = dirs::home_dir() {
            candidates.push(home.join(".bun").join("bin"));
        }
        // US-041: Git for Windows ships `git.exe` under `<install>\cmd`, but a
        // GUI launch (Start Menu / Explorer) inherits a PATH that frequently
        // omits it, so the diff viewer's `Command::new("git")` (`diff/git.rs`)
        // fails with NotFound and the whole diff mode is dead on Windows. Add
        // the standard system (`%ProgramFiles%`, `%ProgramFiles(x86)%`) and
        // per-user (`%LOCALAPPDATA%\Programs`) Git locations; the `is_dir()`
        // filter below drops whichever ones aren't present.
        if let Some(program_files) = std::env::var_os("ProgramFiles") {
            candidates.push(PathBuf::from(&program_files).join("Git").join("cmd"));
        }
        if let Some(program_files_x86) = std::env::var_os("ProgramFiles(x86)") {
            candidates.push(PathBuf::from(&program_files_x86).join("Git").join("cmd"));
        }
        if let Some(local) = dirs::data_local_dir() {
            candidates.push(local.join("Programs").join("Git").join("cmd"));
        }
    }

    let current = std::env::var_os("PATH").unwrap_or_default();
    let existing: Vec<PathBuf> = std::env::split_paths(&current).collect();

    let mut to_prepend: Vec<PathBuf> = Vec::new();
    for cand in candidates {
        if !cand.is_dir() {
            continue;
        }
        if existing.iter().any(|p| p == &cand) {
            continue;
        }
        if to_prepend.contains(&cand) {
            continue;
        }
        to_prepend.push(cand);
    }

    if to_prepend.is_empty() {
        return;
    }

    let mut merged: Vec<PathBuf> = to_prepend.clone();
    merged.extend(existing);

    match std::env::join_paths(&merged) {
        Ok(joined) => {
            log::info!(
                "agent-workspace: augmented PATH with user bin dirs: {}",
                to_prepend
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            // SAFETY: called from `main` before GPUI / IPC / PTY threads start,
            // so no other thread is reading PATH concurrently.
            unsafe { std::env::set_var("PATH", joined) };
        }
        Err(e) => {
            log::warn!(
                "agent-workspace: failed to join augmented PATH ({e}); leaving PATH unchanged"
            );
        }
    }
}

/// 返回当前用户的 AgentWorkspace 数据布局，不创建任何目录。
///
/// 无法解析用户主目录时返回 `None`；调用方必须使用内存降级，禁止回退到
/// Paneflow 旧目录、当前工作目录或系统临时目录。
pub fn user_data_layout() -> Option<paneflow_config::data_layout::UserDataLayout> {
    dirs::home_dir().map(|home| paneflow_config::data_layout::UserDataLayout::from_home(&home))
}

/// 返回已经确认根目录可写的用户数据布局。
///
/// 只有真正需要写入持久文件的入口才调用此函数；单纯计算路径的读取方仍使用
/// [`user_data_layout`]，避免应用启动时无条件创建目录。
fn writable_user_data_layout() -> Option<paneflow_config::data_layout::UserDataLayout> {
    let layout = user_data_layout()?;
    if let Err(e) = std::fs::create_dir_all(layout.root()) {
        log::debug!(
            "agent-workspace: data root {} is unwritable ({e}); callers will use ephemeral state",
            layout.root().display()
        );
        return None;
    }
    Some(layout)
}

#[cfg(test)]
fn data_dir_from(home: &Path) -> PathBuf {
    paneflow_config::data_layout::UserDataLayout::from_home(home)
        .root()
        .to_path_buf()
}

#[cfg(test)]
mod data_path_tests {
    use super::*;

    #[test]
    fn data_dir_uses_agent_workspace_home_namespace() {
        let home = Path::new("C:/Users/TestUser");
        let path = data_dir_from(home);
        assert_eq!(path, home.join(paneflow_config::loader::USER_DATA_DIRNAME));
        assert!(
            !path
                .to_string_lossy()
                .to_ascii_lowercase()
                .contains("paneflow")
        );
    }

    #[test]
    fn stable_helpers_are_derived_from_layout_bin_directory() {
        let layout = paneflow_config::data_layout::UserDataLayout::from_home_with_root_name(
            Path::new("C:/Users/TestUser"),
            ".agent-workspace-test",
        );

        assert_eq!(
            bridge_binary_path_from_layout(&layout),
            layout
                .bin_dir()
                .join(format!("paneflow-mcp{}", executable_suffix()))
        );
        assert_eq!(
            ai_hook_binary_path_from_layout(&layout),
            layout
                .bin_dir()
                .join(format!("paneflow-ai-hook{}", executable_suffix()))
        );
        assert!(!bridge_binary_path_from_layout(&layout).starts_with(layout.cache_dir()));
    }

    #[test]
    fn persistent_write_modules_keep_using_the_layout_contract() {
        // 这是一道低成本源码门禁：若未来有人重新手拼目录，测试会在全量验收中
        // 立即失败，避免写入点悄悄漂回系统缓存或临时目录。
        let telemetry = include_str!("telemetry/id.rs");
        let notifications = include_str!("agents/notifications.rs");
        let shell = include_str!("terminal/shell.rs");
        let update = include_str!("update/windows/msi.rs");
        let markdown = include_str!("markdown/state.rs");
        let helpers = include_str!("ai_hooks/extract.rs");

        assert!(telemetry.contains(".telemetry_id_path()"));
        assert!(notifications.contains(".notification_icon_path()"));
        assert!(shell.contains(".shell_integration_dir()"));
        assert!(update.contains(".update_cache_dir()"));
        assert!(update.contains(".update_logs_dir()"));
        assert!(!update.contains("std::env::temp_dir"));
        assert!(markdown.contains(".markdown_state_path()"));
        assert!(helpers.contains(".helper_cache_dir()"));
    }
}

/// 返回当前平台可执行文件后缀，供两个稳定 helper 路径共用。
fn executable_suffix() -> &'static str {
    if cfg!(windows) { ".exe" } else { "" }
}

/// 仅根据布局计算 MCP bridge 路径，不触碰文件系统。
fn bridge_binary_path_from_layout(
    layout: &paneflow_config::data_layout::UserDataLayout,
) -> PathBuf {
    layout
        .bin_dir()
        .join(format!("paneflow-mcp{}", executable_suffix()))
}

/// 仅根据布局计算 AI Hook 路径，不触碰文件系统。
fn ai_hook_binary_path_from_layout(
    layout: &paneflow_config::data_layout::UserDataLayout,
) -> PathBuf {
    layout
        .bin_dir()
        .join(format!("paneflow-ai-hook{}", executable_suffix()))
}

/// 返回内嵌 MCP bridge 的稳定、无版本绝对路径。
///
/// 外部 Codex/Claude 配置会持久引用此路径，因此 helper 必须位于
/// `~/.agent-workspace/bin/`（调试版使用对应 dev 根），不能进入可清理缓存。
/// 本函数只计算路径；无法准备用户数据根时返回 `None`，实际原子释放由
/// `ai_hooks::extract::ensure_bridge_extracted` 负责。
pub fn bridge_binary_path() -> Option<PathBuf> {
    Some(bridge_binary_path_from_layout(&writable_user_data_layout()?))
}

/// 返回 AI Hook callback 的稳定、无版本绝对路径。
///
/// 与 [`bridge_binary_path`] 相同，外部配置会持久引用此文件，因此它属于
/// durable `bin/`，不会随 `cache/` 清理。函数只计算路径，实际释放由
/// `ai_hooks::extract::ensure_ai_hook_extracted` 负责。
pub fn ai_hook_binary_path() -> Option<PathBuf> {
    Some(ai_hook_binary_path_from_layout(
        &writable_user_data_layout()?
    ))
}

#[cfg(unix)]
fn check_sun_path_fits(path: &std::path::Path) -> bool {
    let bytes = path.as_os_str().len();
    // `MAX_SOCKET_PATH_BYTES` is `sizeof(sun_path)`, and `bind()` needs room for
    // the trailing NUL inside that array - so a path of *exactly* the array size
    // does not fit. Reject `>=`, not `>` (the usable maximum is the array size
    // minus one).
    if bytes >= MAX_SOCKET_PATH_BYTES {
        log::warn!(
            "agent-workspace: computed IPC socket path does not fit sun_path ({} >= {} bytes, no room for the NUL terminator): {} - IPC will be disabled. Set $XDG_RUNTIME_DIR (Linux) or shorten $TMPDIR (macOS) to enable it.",
            bytes,
            MAX_SOCKET_PATH_BYTES,
            path.display()
        );
        false
    } else {
        true
    }
}

#[cfg(test)]
mod socket_env_tests {
    use super::*;

    #[test]
    fn socket_path_env_helper_requires_absolute_path() {
        let absolute = if cfg!(windows) {
            r"\\.\pipe\paneflow-test"
        } else {
            "/tmp/paneflow-test.sock"
        };
        assert_eq!(
            socket_path_from_env(Some(std::ffi::OsString::from(absolute))),
            Some(PathBuf::from(absolute))
        );
        assert_eq!(
            socket_path_from_env(Some(std::ffi::OsString::from("relative-paneflow.sock"))),
            None
        );
        assert_eq!(socket_path_from_env(None), None);
    }
}

// US-009 - these tests assert Unix socket path composition and sun_path
// length limits, so they are structurally Unix-only.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Env vars are process-global; tests that mutate them must be serialised.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        socket: Option<String>,
        xdg: Option<String>,
        tmp: Option<String>,
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn take() -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            Self {
                socket: std::env::var("PANEFLOW_SOCKET_PATH").ok(),
                xdg: std::env::var("XDG_RUNTIME_DIR").ok(),
                tmp: std::env::var("TMPDIR").ok(),
                _guard: guard,
            }
        }

        fn clear(&self) {
            // SAFETY: serialised by ENV_LOCK; no other test or production
            // thread mutates these vars during the test window.
            unsafe {
                std::env::remove_var("PANEFLOW_SOCKET_PATH");
                std::env::remove_var("XDG_RUNTIME_DIR");
                std::env::remove_var("TMPDIR");
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            // SAFETY: serialised by ENV_LOCK (still held via _guard).
            unsafe {
                match &self.socket {
                    Some(v) => std::env::set_var("PANEFLOW_SOCKET_PATH", v),
                    None => std::env::remove_var("PANEFLOW_SOCKET_PATH"),
                }
                match &self.xdg {
                    Some(v) => std::env::set_var("XDG_RUNTIME_DIR", v),
                    None => std::env::remove_var("XDG_RUNTIME_DIR"),
                }
                match &self.tmp {
                    Some(v) => std::env::set_var("TMPDIR", v),
                    None => std::env::remove_var("TMPDIR"),
                }
            }
        }
    }

    #[test]
    fn paneflow_socket_path_env_wins_when_absolute() {
        let g = EnvGuard::take();
        g.clear();
        // SAFETY: ENV_LOCK held.
        unsafe {
            std::env::set_var("PANEFLOW_SOCKET_PATH", "/tmp/paneflow-isolated.sock");
            std::env::set_var("XDG_RUNTIME_DIR", "/run/user/1000");
        }
        assert_eq!(
            socket_path(),
            Some(PathBuf::from("/tmp/paneflow-isolated.sock"))
        );
        let spec = socket_path_spec().expect("env socket path resolves");
        assert_eq!(spec.path(), Path::new("/tmp/paneflow-isolated.sock"));
        assert!(
            !spec.owned_parent(),
            "env override parent must not be treated as Paneflow-owned"
        );
    }

    #[test]
    fn xdg_runtime_dir_wins_when_set() {
        let g = EnvGuard::take();
        g.clear();
        // SAFETY: ENV_LOCK held.
        unsafe { std::env::set_var("XDG_RUNTIME_DIR", "/run/user/1000") };
        let p = socket_path().expect("runtime dir must resolve");
        assert_eq!(
            p,
            PathBuf::from(format!("/run/user/1000/{APP_SUBDIR}/{SOCKET_FILE}")),
            "AC5: Linux with XDG_RUNTIME_DIR must resolve to the XDG path \
             (subdir + filename vary by build profile via APP_SUBDIR / SOCKET_FILE)"
        );
        assert!(
            socket_path_spec().expect("socket spec").owned_parent(),
            "default runtime-dir socket is Paneflow-owned"
        );
    }

    #[test]
    fn tmpdir_fallback_when_xdg_and_runtime_dir_missing() {
        let g = EnvGuard::take();
        g.clear();
        // SAFETY: ENV_LOCK held.
        unsafe { std::env::set_var("TMPDIR", "/tmp/macos-stub") };
        let p = socket_path();
        if let Some(p) = p {
            // On Linux, dirs::runtime_dir() may still return Some before we
            // reach the TMPDIR branch - accept either but prove the path is
            // well-formed.
            assert!(p.ends_with(format!("{APP_SUBDIR}/{SOCKET_FILE}")));
        }
    }

    #[test]
    fn overlong_path_returns_none() {
        let g = EnvGuard::take();
        g.clear();
        // 120-byte XDG_RUNTIME_DIR → joined path blows past 104.
        let long = "/".to_string() + &"x".repeat(119);
        // SAFETY: ENV_LOCK held.
        unsafe { std::env::set_var("XDG_RUNTIME_DIR", &long) };
        assert!(
            socket_path().is_none(),
            "AC6: over-long sun_path must return None rather than a bind-time error"
        );
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        socket: Option<String>,
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn take() -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            Self {
                socket: std::env::var("PANEFLOW_SOCKET_PATH").ok(),
                _guard: guard,
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            // SAFETY: serialised by ENV_LOCK (still held via _guard).
            unsafe {
                match &self.socket {
                    Some(v) => std::env::set_var("PANEFLOW_SOCKET_PATH", v),
                    None => std::env::remove_var("PANEFLOW_SOCKET_PATH"),
                }
            }
        }
    }

    #[test]
    fn paneflow_socket_path_env_wins_for_named_pipe() {
        let _guard = EnvGuard::take();
        // SAFETY: ENV_LOCK held.
        unsafe {
            std::env::set_var("PANEFLOW_SOCKET_PATH", r"\\.\pipe\paneflow-isolated-test");
        }
        assert_eq!(
            socket_path(),
            Some(PathBuf::from(r"\\.\pipe\paneflow-isolated-test"))
        );
    }
}
