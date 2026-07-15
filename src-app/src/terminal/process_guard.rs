//! 管理终端与应用进程的父进程死亡守护。
//!
//! 该模块属于通用终端基础设施，不依赖 Agent、MCP 或自动化功能。Windows 使用
//! Job Object 在主进程退出时清理整个进程树；Linux 与 macOS 为每个原始 PTY
//! 启动轻量守护进程，避免应用异常退出后遗留仍在运行的 shell。

#[cfg(unix)]
use std::process::{ChildStdin, Command, Stdio};

/// Unix PTY 守护子进程使用的内部命令名。
#[cfg(unix)]
pub const PTY_GUARD_SUBCOMMAND: &str = "__paneflow-pty-guard";

/// 保持 Unix PTY 守护控制管道存活的句柄。
///
/// 字段不对外暴露；句柄被丢弃时关闭标准输入管道，守护进程据此正常退出。
#[cfg(unix)]
pub struct PtyGuardHandle {
    /// 守护进程的控制管道，生命周期与对应 PTY 一致。
    _stdin: ChildStdin,
}

#[cfg(target_os = "windows")]
mod windows_impl {
    use win32job::{ExtendedLimitInfo, Job};

    /// 创建启用 `KILL_ON_JOB_CLOSE` 的 Job Object，并把当前进程加入其中。
    ///
    /// Job 句柄会被有意遗忘，使其生命周期等同于应用进程；应用退出导致最后一个
    /// 句柄关闭后，Windows 会清理所有继承该 Job 的终端及其后代进程。
    pub(super) fn install() -> Result<(), Box<dyn std::error::Error>> {
        let mut info = ExtendedLimitInfo::default();
        info.limit_kill_on_job_close().limit_breakaway_ok();
        let job = Job::create_with_limit_info(&info)?;
        job.assign_current_process()?;
        std::mem::forget(job);
        Ok(())
    }
}

/// 当前平台安装应用级进程守护后的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ParentGuardStatus {
    /// 已成功安装平台级进程守护。
    Installed,
    /// 当前平台没有应用级等价能力，PTY 仍使用逐会话守护。
    Unsupported,
}

/// 安装应用级父进程死亡守护。
///
/// 应在创建任何 PTY 前调用一次。Windows 安装 Job Object；其他平台返回
/// [`ParentGuardStatus::Unsupported`]。安装失败不会由本函数吞掉，调用方可以记录
/// 错误并按“尽力清理”方式继续启动。
pub fn install_process_job() -> Result<ParentGuardStatus, Box<dyn std::error::Error>> {
    #[cfg(target_os = "windows")]
    {
        windows_impl::install()?;
        Ok(ParentGuardStatus::Installed)
    }
    #[cfg(not(target_os = "windows"))]
    {
        Ok(ParentGuardStatus::Unsupported)
    }
}

/// 运行 Unix PTY 守护子命令。
///
/// `args[2]` 是应用父进程 PID，`args[3]` 是 PTY 子进程组 ID。参数无效返回 2；
/// 正常监控和清理完成返回 0。Windows 不编译该入口。
#[cfg(unix)]
pub fn run_pty_guard_from_args(args: &[String]) -> i32 {
    let Some(parent_pid) = args.get(2).and_then(|arg| arg.parse::<u32>().ok()) else {
        return 2;
    };
    let Some(child_pgid) = args.get(3).and_then(|arg| arg.parse::<u32>().ok()) else {
        return 2;
    };
    if parent_pid <= 1 || child_pgid <= 1 {
        return 2;
    }

    set_control_pipe_nonblocking();
    while parent_still_attached(parent_pid) && process_group_alive(child_pgid) {
        if control_pipe_closed() {
            return 0;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    if !parent_still_attached(parent_pid) && process_group_alive(child_pgid) {
        terminate_process_group(child_pgid);
    }
    0
}

/// 为一个 Unix PTY 进程组启动父进程死亡守护。
///
/// 返回的句柄必须由 PTY 状态持有。任何启动失败都降级为 `None`，因为守护失败不应
/// 阻止用户打开终端；正常关闭时仍由 PTY 自己的销毁路径清理进程组。
#[cfg(unix)]
#[cfg_attr(test, allow(dead_code))]
pub fn spawn_pty_guard(child_pgid: u32) -> Option<PtyGuardHandle> {
    if child_pgid <= 1 {
        return None;
    }
    let Ok(exe) = std::env::current_exe() else {
        log::debug!("process_guard: 无法解析当前程序路径，跳过 PTY 守护");
        return None;
    };

    let mut cmd = Command::new(exe);
    cmd.arg(PTY_GUARD_SUBCOMMAND)
        .arg(std::process::id().to_string())
        .arg(child_pgid.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    use std::os::unix::process::CommandExt;
    cmd.process_group(0);

    match cmd.spawn() {
        Ok(mut child) => {
            let Some(stdin) = child.stdin.take() else {
                log::warn!("process_guard: PTY 守护进程组 {child_pgid} 没有控制管道");
                let _ = child.kill();
                return None;
            };
            // 守护进程只负责监控；独立等待线程用于回收退出状态，避免僵尸进程。
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            Some(PtyGuardHandle { _stdin: stdin })
        }
        Err(err) => {
            log::warn!("process_guard: 无法为进程组 {child_pgid} 启动 PTY 守护：{err}");
            None
        }
    }
}

/// 判断守护进程是否仍直接挂在预期父进程下。
#[cfg(unix)]
fn parent_still_attached(parent_pid: u32) -> bool {
    // SAFETY：`getppid` 没有调用前置条件。
    unsafe { libc::getppid() as u32 == parent_pid }
}

/// 探测 Unix 进程组是否仍然存在，不向目标发送实际信号。
#[cfg(unix)]
fn process_group_alive(pgid: u32) -> bool {
    let Ok(pgid) = i32::try_from(pgid) else {
        return false;
    };
    // SAFETY：信号 0 只探测进程组，不改变目标进程状态。
    let rc = unsafe { libc::kill(-pgid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// 先发送 SIGTERM，再在短暂宽限期后用 SIGKILL 清理 Unix 进程组。
#[cfg(unix)]
fn terminate_process_group(pgid: u32) {
    let Ok(pgid) = i32::try_from(pgid) else {
        return;
    };
    // SAFETY：负 PID 表示进程组；调用前已验证转换结果。
    unsafe {
        libc::kill(-pgid, libc::SIGTERM);
    }
    std::thread::sleep(std::time::Duration::from_millis(100));
    if process_group_alive(pgid as u32) {
        // SAFETY：再次探测存活后，仍只针对同一个进程组。
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
}

/// 把守护进程的标准输入改为非阻塞，避免控制管道读取卡住监控循环。
#[cfg(unix)]
fn set_control_pipe_nonblocking() {
    // SAFETY：fd 0 是本守护子命令约定的控制管道；失败时仍可轮询父进程。
    unsafe {
        let flags = libc::fcntl(0, libc::F_GETFL);
        if flags >= 0 {
            let _ = libc::fcntl(0, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
}

/// 判断控制管道是否已经关闭。
#[cfg(unix)]
fn control_pipe_closed() -> bool {
    let mut byte = [0u8; 1];
    // SAFETY：最多把一个字节读入有效的栈缓冲区。
    let rc = unsafe { libc::read(0, byte.as_mut_ptr().cast(), 1) };
    if rc == 0 {
        return true;
    }
    if rc > 0 {
        return false;
    }
    let err = std::io::Error::last_os_error().raw_os_error();
    !matches!(err, Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK || code == libc::EINTR)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 所有平台调用应用级守护安装都不得 panic；受限 Windows CI 允许返回错误。
    #[test]
    fn install_process_job_does_not_panic() {
        let _ = install_process_job();
        let _ = install_process_job();
    }

    /// Unix 平台必须明确报告不支持应用级 Job，而不是静默假装成功。
    #[cfg(not(target_os = "windows"))]
    #[test]
    fn unix_install_is_documented_unsupported() {
        assert_eq!(
            install_process_job().unwrap(),
            ParentGuardStatus::Unsupported
        );
    }

    /// 守护子命令必须拒绝无法解析的 PID 参数。
    #[cfg(unix)]
    #[test]
    fn pty_guard_rejects_invalid_args() {
        let args = vec![
            "paneflow".to_string(),
            PTY_GUARD_SUBCOMMAND.to_string(),
            "bad".to_string(),
            "2".to_string(),
        ];
        assert_eq!(run_pty_guard_from_args(&args), 2);
    }
}
