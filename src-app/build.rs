// 构建脚本遇到不可恢复错误时使用 `panic!`，让 Cargo 直接展示构建上下文。
// 工作区的 `clippy::panic = "deny"` 面向运行时代码；这里若改成
// `main() -> Result<…>` 只会由 `Termination` 输出更弱的错误信息。
#![allow(clippy::panic)]

//! AgentWorkspace 桌面主程序的构建脚本。
//!
//! 主要职责：
//! 1. 监听遥测相关编译期环境变量，确保 CI 更换密钥或主机后重新求值
//!    `option_env!`，不会继续嵌入旧值。
//!
//! 2. 为当前目标三元组构建并暂存 `paneflow-shim`、`paneflow-ai-hook` 和
//!    `paneflow-mcp` 三个内部辅助程序，供 `assets::Bins` 在编译期嵌入。
//!    主程序没有直接依赖这些 crate，因此必须由嵌套 Cargo 构建保证产物先
//!    存在；运行时再由提取模块写入稳定目录。
//!
//!    嵌套构建使用独立的 `<workspace>/target/embed-build`，避免与外层 Cargo
//!    争用目标目录锁。辅助程序依赖闭包很小，重复编译成本低于引入复杂共享
//!    构建图的维护成本。
//!
//!    每个目标三元组的嵌入总大小必须不超过 `EMBED_SIZE_LIMIT_BYTES`；超限
//!    直接使外层构建失败，禁止静默发布膨胀的 AgentWorkspace 主程序。
//!
//!    `PANEFLOW_SKIP_EMBED_BUILD=1` 是保留的内部兼容开关，可跳过嵌套构建；
//!    调用方必须预先填充暂存目录，否则 rust-embed 8.x 会因目录缺失失败。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Hard cap on the total bytes staged under `target/embed/bin/<target>/`.
/// Enforced to keep the main PaneFlow binary slim.
///
/// EP-001 US-002 - measured release-min sizes (Linux x86_64, 2026-05-29):
///
/// ```text
///   paneflow-shim      455_320 B
///   paneflow-ai-hook   360_448 B
///   paneflow-mcp       426_216 B   (added by EP-001 US-001)
///   ----------------------------
///   total            1_241_984 B  (~1.18 MB)
/// ```
///
/// The previous 1 MB cap (shim + ai-hook only ≈ 815 KB) no longer fits once
/// the MCP bridge is embedded. Raised to 1.75 MiB (1_835_008 B), leaving
/// ~593 KB / 48% headroom over the Linux total to absorb per-triple variance
/// (Windows `.exe` and macOS Mach-O binaries run larger than ELF). The guard
/// stays active: the outer build still fails if the staged total exceeds
/// this cap, so an unexpectedly bloated dependency cannot ship silently.
const EMBED_SIZE_LIMIT_BYTES: u64 = 1_835_008;

fn main() {
    // 1. Telemetry env vars (unchanged behavior - preserved so a key
    //    rotation forces the downstream `option_env!` to be re-resolved).
    println!("cargo:rerun-if-env-changed=POSTHOG_API_KEY");
    println!("cargo:rerun-if-env-changed=POSTHOG_HOST");
    println!("cargo:rerun-if-env-changed=PANEFLOW_SKIP_EMBED_BUILD");

    // 2. US-008 - stage the AI-hook binaries into a dir that
    //    `assets::Bins` (rust-embed) will ingest.
    let target = std::env::var("TARGET").expect("cargo always sets TARGET for build scripts");
    // Expose the triple to source code via `env!("PANEFLOW_TARGET_TRIPLE")`
    // so `ai_hooks::extract` can locate the correct sub-folder under
    // `bin/<triple>/` at runtime without re-deriving it from `std::env::consts`.
    println!("cargo:rustc-env=PANEFLOW_TARGET_TRIPLE={target}");

    let manifest_dir = PathBuf::from(
        std::env::var("CARGO_MANIFEST_DIR")
            .expect("cargo always sets CARGO_MANIFEST_DIR for build scripts"),
    );
    let workspace_root = manifest_dir
        .parent()
        .expect("src-app manifest dir has a parent (the workspace root)")
        .to_path_buf();

    // Windows：把 AgentWorkspace 多尺寸应用图标嵌入 agent-workspace.exe，
    // 供 Explorer 和任务栏读取；否则裸可执行文件会显示系统通用图标。
    // GPUI 运行时窗口图标仍由同源的内嵌 PNG 设置。
    #[cfg(windows)]
    embed_windows_app_icon(&workspace_root);

    // The folder `RustEmbed` points at, relative to CARGO_MANIFEST_DIR.
    // Keep the in-memory/on-disk folder layout aligned with the macro.
    let embed_root = manifest_dir.join("target").join("embed").join("bin");
    let embed_dir = embed_root.join(&target);
    fs::create_dir_all(&embed_dir).unwrap_or_else(|e| {
        panic!(
            "US-008: cannot create embed staging dir {}: {e}",
            embed_dir.display()
        )
    });

    // Rerun when the shim / hook crate sources change. Cargo watches
    // directories recursively when a directory path is emitted.
    println!(
        "cargo:rerun-if-changed={}",
        workspace_root.join("crates/paneflow-shim").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        workspace_root.join("crates/paneflow-ai-hook").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        workspace_root.join("crates/paneflow-mcp").display()
    );
    // Also rerun if the root manifest changes (workspace-wide lint policy,
    // dep version bumps, etc., affect the staged binaries).
    println!(
        "cargo:rerun-if-changed={}",
        workspace_root.join("Cargo.toml").display()
    );
    // Explicit per-FILE watches for the shim's `include_str!`'d plugin assets.
    // A directory `rerun-if-changed` only catches add/remove/rename (the dir
    // mtime), NOT a content edit of a nested file on Windows - so without these
    // an edited `*-paneflow-status.ts` would silently not be re-embedded.
    for asset in [
        "crates/paneflow-shim/assets/opencode-paneflow-status.ts",
        "crates/paneflow-shim/assets/pi-paneflow-status.ts",
    ] {
        println!(
            "cargo:rerun-if-changed={}",
            workspace_root.join(asset).display()
        );
    }

    let skip_nested_build = std::env::var_os("PANEFLOW_SKIP_EMBED_BUILD").is_some();
    if !skip_nested_build {
        stage_ai_hook_binaries(&workspace_root, &target, &embed_dir);
    } else {
        println!(
            "cargo:warning=PANEFLOW_SKIP_EMBED_BUILD is set - assuming {} is already populated",
            embed_dir.display()
        );
    }

    // Whether the nested build ran or not, enforce the size budget so a
    // pre-populated staging dir also honors the PRD cap.
    enforce_embed_size_budget(&embed_dir);
}

/// Invoke a child `cargo build` against the workspace to produce the
/// `paneflow-shim`, `paneflow-ai-hook` and `paneflow-mcp` binaries for
/// `target`, then copy them into `embed_dir`. Panics (fails the outer
/// build) on any non-success exit, non-existent artifact, or IO error.
fn stage_ai_hook_binaries(workspace_root: &Path, target: &str, embed_dir: &Path) {
    // Use a dedicated `--target-dir` so we do not fight the outer cargo
    // for `target/debug/.cargo-lock` or `target/release/.cargo-lock`.
    // `embed-build` is a sibling of the outer `target/<profile>/` tree.
    let nested_target_dir = workspace_root.join("target").join("embed-build");

    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let profile = "release-min";

    // Run the nested cargo from the workspace root so `-p <crate>` is
    // resolved unambiguously and the workspace's `[patch.crates-io]`
    // block is honored.
    let mut cmd = Command::new(&cargo);
    cmd.current_dir(workspace_root)
        .arg("build")
        .arg("--profile")
        .arg(profile)
        .arg("--target")
        .arg(target)
        .arg("--target-dir")
        .arg(&nested_target_dir)
        .arg("-p")
        .arg("paneflow-shim")
        .arg("-p")
        .arg("paneflow-ai-hook")
        .arg("-p")
        .arg("paneflow-mcp")
        // Prevent the nested cargo from inheriting the outer cargo's
        // target-dir via `CARGO_TARGET_DIR` - the explicit `--target-dir`
        // above already pins it, but removing the env avoids confusion if
        // the parent environment sets it.
        .env_remove("CARGO_TARGET_DIR")
        // `RUSTFLAGS` changes (e.g. `-C link-arg=...` from sccache setups)
        // would invalidate the nested cache on every outer build. Leave
        // them alone; Cargo deals with that via its own fingerprinting.
        ;

    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("US-008: failed to spawn nested cargo build: {e}"));
    if !status.success() {
        panic!(
            "US-008: nested `cargo build --profile {profile} -p paneflow-shim -p paneflow-ai-hook -p paneflow-mcp --target {target}` \
             failed with {status}. Re-run the outer build with verbose logging to see the child cargo output."
        );
    }

    // Cargo lays artifacts out at
    // `<target-dir>/<triple>/<profile-dir>/<binary>[.exe]`.
    // For custom profiles the `<profile-dir>` equals the profile name
    // (release-min → release-min).
    let artifact_dir = nested_target_dir.join(target).join(profile);

    let bin_exe = if target.contains("windows") {
        ".exe"
    } else {
        ""
    };

    // Copy only the three binaries we need; anything else in
    // `artifact_dir` is a transitive build product we don't want to embed.
    for bin in ["paneflow-shim", "paneflow-ai-hook", "paneflow-mcp"] {
        let src = artifact_dir.join(format!("{bin}{bin_exe}"));
        let dst = embed_dir.join(format!("{bin}{bin_exe}"));

        if !src.exists() {
            panic!(
                "US-008: expected nested build artifact {} is missing - \
                 did the child cargo build silently skip this binary?",
                src.display()
            );
        }
        // `fs::copy` preserves mode on Unix; embedded bytes don't need
        // the executable bit (the extractor sets it), but a 0o755 here
        // keeps `ls -l target/embed/bin/<triple>/` self-documenting.
        fs::copy(&src, &dst).unwrap_or_else(|e| {
            panic!(
                "US-008: copy {} → {} failed: {e}",
                src.display(),
                dst.display()
            )
        });
    }
}

/// Enforce the `EMBED_SIZE_LIMIT_BYTES` total embedded-bytes cap.
/// Inspects only top-level files in `embed_dir` - there are no subdirs
/// in the per-target staging layout so a recursive walk is not warranted.
fn enforce_embed_size_budget(embed_dir: &Path) {
    let mut total: u64 = 0;
    let mut per_file: BTreeMap<String, u64> = BTreeMap::new();
    let iter = match fs::read_dir(embed_dir) {
        Ok(iter) => iter,
        Err(e) => panic!(
            "US-008: cannot read embed staging dir {}: {e}",
            embed_dir.display()
        ),
    };
    for entry in iter {
        let entry = entry
            .unwrap_or_else(|e| panic!("US-008: broken embed dir entry in {embed_dir:?}: {e}"));
        let metadata = entry
            .metadata()
            .unwrap_or_else(|e| panic!("US-008: cannot stat {}: {e}", entry.path().display()));
        if metadata.is_file() {
            let size = metadata.len();
            total = total.saturating_add(size);
            per_file.insert(entry.file_name().to_string_lossy().into_owned(), size);
        }
    }

    if total > EMBED_SIZE_LIMIT_BYTES {
        let mut details = String::new();
        for (name, size) in &per_file {
            details.push_str(&format!("  {name}: {size} bytes\n"));
        }
        panic!(
            "US-008/EP-001: embedded binaries exceed the {EMBED_SIZE_LIMIT_BYTES}-byte cap ({total} bytes).\n\
             Staging dir: {}\n\
             Per-file:\n{details}\
             Shrink shim/ai-hook/paneflow-mcp via smaller deps or a tighter release-min profile, \
             or raise EMBED_SIZE_LIMIT_BYTES with a fresh measurement note.",
            embed_dir.display()
        );
    }
}

/// 通过 Windows 资源编译器把多尺寸图标嵌入 `agent-workspace.exe`。
///
/// 这是尽力而为的构建增强：缺少图标或 Windows SDK 的 `rc.exe` 时只输出
/// `cargo:warning`，继续生成使用系统默认图标的程序，避免开发环境被阻塞。
/// `winresource` 受 `cfg(windows)` 约束，不会进入其他平台构建图。
#[cfg(windows)]
fn embed_windows_app_icon(workspace_root: &Path) {
    let icon = workspace_root.join("assets").join("AgentWorkspace.ico");
    let Some(icon_str) = icon.to_str() else {
        println!(
            "cargo:warning=winresource: icon path {} is not valid UTF-8; skipping exe icon embed",
            icon.display()
        );
        return;
    };
    if !icon.exists() {
        println!("cargo:warning=winresource: {icon_str} not found; skipping exe icon embed");
        return;
    }
    // Re-run the build script when the icon artwork changes.
    println!("cargo:rerun-if-changed={icon_str}");
    let mut res = winresource::WindowsResource::new();
    res.set_icon(icon_str);
    if let Err(e) = res.compile() {
        println!(
            "cargo:warning=winresource: failed to embed {icon_str} into agent-workspace.exe ({e}); \
             the exe will use the default Windows icon"
        );
    }
}
