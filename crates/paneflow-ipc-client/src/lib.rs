#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::unwrap_in_result,
        clippy::panic
    )
)]
//! Paneflow 本地 IPC 的共享阻塞传输层。
//!
//! 本模块实现 `src-app/src/ipc.rs` 约定的换行分隔 JSON-RPC 2.0 协议，底层使用
//! `interprocess` 本地 socket（Unix domain socket 或 Windows named pipe）。既支持
//! CLI/MCP 所需的请求响应，也支持 AI hook 所需的单向 frame。
//!
//! 每次调用只建立一个连接，避免陈旧长连接拖住调用方。连接、写入与读取共享同一个
//! 绝对 deadline；Windows 使用可取消的重叠 I/O，禁止重新启用会触发 fast-fail 的
//! `PIPE_NOWAIT` 轮询组合。
//!
//! 该 crate 不依赖 GPUI 或 `src-app`，供 MCP bridge、CLI 和 AI hook 共同复用。

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
#[cfg(windows)]
use std::{
    os::windows::io::{AsHandle, AsRawHandle},
    ptr,
};

use interprocess::local_socket::{prelude::*, ConnectOptions, GenericFilePath, Stream};
use interprocess::ConnectWaitMode;
use serde_json::{json, Value};
#[cfg(windows)]
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_IO_PENDING, ERROR_NOT_FOUND, ERROR_OPERATION_ABORTED, HANDLE,
        WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT,
    },
    Storage::FileSystem::{ReadFile, WriteFile},
    System::{
        Threading::{CreateEventW, WaitForSingleObject},
        IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED},
    },
};

/// 单次请求响应的总时限。服务端总会返回结果或合成 `-32002` 超时响应，因此超过
/// 该时限可判定 IPC 链路已经失去响应。
const IPC_TIMEOUT: Duration = Duration::from_secs(10);

/// 单条响应的读取上限，与服务端 `MAX_REQUEST_LEN` 保持一致。deadline 只能约束时间，
/// 不能约束同 UID 对端持续发送造成的内存增长，因此还必须限制字节数；达到上限仍无
/// 换行符时按 framing 错误处理，禁止解析截断 JSON。
const MAX_RESPONSE_LEN: u64 = 256 * 1024;

/// “发送 JSON-RPC 请求并取得 `result`”的传输抽象，便于 MCP 与 CLI 隔离真实 socket
/// 进行单元测试。
pub trait IpcTransport {
    /// 调用 Paneflow IPC 方法。成功时返回 `result`；传输失败或收到 JSON-RPC
    /// `error` envelope 时返回面向调用方的错误文本。
    fn call(&self, method: &str, params: Value) -> Result<Value, String>;
}

/// 绑定到已解析 socket 路径的真实 IPC 客户端。
pub struct IpcClient {
    /// 当前 Paneflow 实例的本地 socket 或命名管道路径。
    socket: PathBuf,
    /// 单调递增的 JSON-RPC 请求编号，可供多线程调用方安全共享。
    next_id: AtomicU64,
}

impl IpcClient {
    /// 创建绑定到指定本地 IPC 路径的客户端，不会立即建立连接。
    pub fn new(socket: PathBuf) -> Self {
        Self {
            socket,
            next_id: AtomicU64::new(1),
        }
    }
}

impl IpcTransport for IpcClient {
    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = build_request(id, method, params);
        let line = send_and_receive(&self.socket, &request).map_err(|e| {
            format!(
                "paneflow IPC unreachable at {} ({e}); is Paneflow running?",
                self.socket.display()
            )
        })?;
        parse_response(&line)
    }
}

/// 构造 JSON-RPC 2.0 请求 frame。
pub(crate) fn build_request(id: u64, method: &str, params: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    })
}

/// 从单行 JSON-RPC 响应中提取 `result`，并将错误 envelope 或畸形响应转成错误文本。
pub(crate) fn parse_response(line: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(line.trim())
        .map_err(|e| format!("invalid JSON-RPC response from paneflow: {e}"))?;
    if let Some(message) = jsonrpc_error_message_from_value(&value) {
        return Err(message);
    }
    value
        .get("result")
        .cloned()
        .ok_or_else(|| "paneflow response missing both `result` and `error`".to_string())
}

pub fn jsonrpc_error_message(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    jsonrpc_error_message_from_value(&value)
}

fn jsonrpc_error_message_from_value(value: &Value) -> Option<String> {
    let err = value.get("error")?;
    let code = err.get("code").and_then(Value::as_i64).unwrap_or(0);
    let message = err
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown error");
    Some(format!("paneflow error {code}: {message}"))
}

/// 建立连接、写入以换行结尾的请求，并读取一行响应。
///
/// Unix 依赖 OS socket deadline；Windows 依赖可取消的重叠命名管道 I/O。旧的临时
/// 线程加 `recv_timeout` 方案会在每次超时时遗留一个永久阻塞线程和 socket 句柄；
/// 当前实现让读取本身返回超时，使拥有 stream 的栈帧可以正常释放资源。
/// `ErrorKind::Unsupported` 只用于兼容可选的 Unix socket timeout setter，其他错误
/// 必须原样上抛。
#[cfg(any(not(windows), test))]
fn tolerate_unsupported(r: io::Result<()>) -> io::Result<()> {
    match r {
        Err(e) if e.kind() == io::ErrorKind::Unsupported => Ok(()),
        other => other,
    }
}

fn send_and_receive(socket: &Path, request: &Value) -> io::Result<String> {
    send_and_receive_with_timeout(socket, request, IPC_TIMEOUT)
}

/// 使用指定总时限完成一次请求，连接、写入和读取共享同一个绝对 deadline。
fn send_and_receive_with_timeout(
    socket: &Path,
    request: &Value,
    timeout: Duration,
) -> io::Result<String> {
    let deadline = deadline_after(timeout)?;
    let stream = connect_frame_stream(socket, deadline)?;
    let payload = serialize_frame(request)?;

    #[cfg(not(windows))]
    {
        let mut stream = stream;
        tolerate_unsupported(stream.set_send_timeout(Some(remaining(deadline)?)))?;
        stream.write_all(&payload)?;
        stream.flush()?;
        tolerate_unsupported(stream.set_recv_timeout(Some(remaining(deadline)?)))?;

        let mut reader = BufReader::new(stream);
        return read_capped_response_line(&mut reader);
    }

    #[cfg(windows)]
    {
        write_all_with_deadline(&stream, &payload, deadline)?;
        read_line_with_deadline(&stream, deadline)
    }
}

/// 向本地 IPC 端点发送一条换行分隔 JSON frame，不等待响应。
///
/// 调用方决定时限和失败语义；本函数保证连接与写入共享同一个绝对 deadline。
/// AI hook 使用该 interface 后无需复制任何 Windows 命名管道 implementation。
pub fn send_frame_with_timeout(socket: &Path, frame: &Value, timeout: Duration) -> io::Result<()> {
    let deadline = deadline_after(timeout)?;
    let stream = connect_frame_stream(socket, deadline)?;
    let payload = serialize_frame(frame)?;

    #[cfg(windows)]
    {
        write_all_with_deadline(&stream, &payload, deadline)
    }
    #[cfg(not(windows))]
    {
        let mut stream = stream;
        tolerate_unsupported(stream.set_send_timeout(Some(remaining(deadline)?)))?;
        stream.write_all(&payload)?;
        stream.flush()
    }
}

/// 将 JSON 值编码为服务端约定的单行 frame。
fn serialize_frame(frame: &Value) -> io::Result<Vec<u8>> {
    let mut payload =
        serde_json::to_vec(frame).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    payload.push(b'\n');
    Ok(payload)
}

/// 建立不会溢出的绝对 deadline。
fn deadline_after(timeout: Duration) -> io::Result<Instant> {
    Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "IPC timeout is too large"))
}

/// 返回绝对 deadline 的剩余时长；已经耗尽时统一返回 TimedOut。
fn remaining(deadline: Instant) -> io::Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "paneflow IPC deadline elapsed",
        ))
    } else {
        Ok(remaining)
    }
}

/// 用有界等待连接本地 IPC；Windows 连接保持阻塞 I/O 模式，避免 PIPE_NOWAIT。
fn connect_frame_stream(socket: &Path, deadline: Instant) -> io::Result<Stream> {
    let name = socket.to_fs_name::<GenericFilePath>()?;
    // interprocess 2.4 的同步重叠 I/O 不能与 PIPE_NOWAIT 安全组合：暂时无数据
    // 会穿过库的不可展开保护并触发 0xC0000409。保持 stream 为阻塞模式；Windows
    // 实际读写仍由下方可取消的重叠 I/O 执行。
    ConnectOptions::new()
        .name(name)
        .wait_mode(ConnectWaitMode::Timeout(remaining(deadline)?))
        .connect_sync()
}

/// 从带 BufRead interface 的 stream 读取一条有大小上限的响应。
#[cfg(not(windows))]
fn read_capped_response_line(reader: &mut impl BufRead) -> io::Result<String> {
    let mut line = String::new();
    match reader.by_ref().take(MAX_RESPONSE_LEN).read_line(&mut line) {
        Ok(n) if n as u64 >= MAX_RESPONSE_LEN && !line.ends_with('\n') => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "paneflow response exceeded the size cap",
        )),
        Ok(_) => Ok(line),
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ) =>
        {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "paneflow IPC deadline elapsed",
            ))
        }
        Err(e) => Err(e),
    }
}

/// Windows 重叠 I/O 的方向。读写共用相同的等待、取消和回收规则。
#[cfg(windows)]
enum WindowsPipeOperation<'a> {
    Read(&'a mut [u8]),
    Write(&'a [u8]),
}

/// 自动关闭单次重叠 I/O 使用的事件句柄。
#[cfg(windows)]
struct WindowsEvent(HANDLE);

#[cfg(windows)]
impl Drop for WindowsEvent {
    fn drop(&mut self) {
        // SAFETY: 句柄只由本结构拥有，且仅在 CreateEventW 成功后构造。
        unsafe { CloseHandle(self.0) };
    }
}

/// 将剩余时间转换为 WaitForSingleObject 的毫秒参数，保留 0 以执行立即检查。
#[cfg(windows)]
fn windows_wait_millis(remaining: Duration) -> u32 {
    u32::try_from(remaining.as_millis()).unwrap_or(u32::MAX - 1)
}

/// 取消超时或等待失败的操作，并同步回收完成通知。
///
/// `OVERLAPPED` 和读写缓冲区都位于调用栈；返回前必须确认内核不再访问它们，否则
/// 会形成释放后写入。`GetOverlappedResult(..., TRUE)` 是这里不可省略的安全边界。
#[cfg(windows)]
fn cancel_and_drain_windows_io(handle: HANDLE, overlapped: &mut OVERLAPPED) -> io::Result<()> {
    // SAFETY: handle 是当前 Stream 的有效重叠句柄，overlapped 对应本次未完成操作。
    let cancelled = unsafe { CancelIoEx(handle, overlapped) };
    let cancel_error = if cancelled == 0 {
        let error = io::Error::last_os_error();
        (error.raw_os_error() != Some(ERROR_NOT_FOUND as i32)).then_some(error)
    } else {
        None
    };

    let mut transferred = 0u32;
    // SAFETY: 等待直到操作完成或取消完成，确保返回后内核不再引用栈上状态。
    let drain_result =
        if unsafe { GetOverlappedResult(handle, overlapped, &mut transferred, 1) } != 0 {
            Ok(())
        } else {
            let drain_error = io::Error::last_os_error();
            if drain_error.raw_os_error() == Some(ERROR_OPERATION_ABORTED as i32) {
                Ok(())
            } else {
                Err(drain_error)
            }
        };
    if let Some(error) = cancel_error {
        Err(error)
    } else {
        drain_result
    }
}

/// 在一个 Windows 命名管道句柄上执行有截止时间的重叠读或写。
#[cfg(windows)]
fn windows_pipe_io(
    stream: &Stream,
    operation: WindowsPipeOperation<'_>,
    deadline: Instant,
) -> io::Result<usize> {
    // Windows 构建的 local_socket::Stream 只有 NamedPipe 变体。
    let Stream::NamedPipe(pipe) = stream;
    let handle = pipe.as_handle().as_raw_handle().cast();
    // SAFETY: 默认安全属性、手动复位、初始无信号，返回句柄由 WindowsEvent 独占。
    let event = WindowsEvent(unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) });
    if event.0.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: 全零是 Win32 OVERLAPPED 的规定初始化方式，随后只设置事件句柄。
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = event.0;

    let started = match operation {
        WindowsPipeOperation::Read(buffer) => {
            let length = u32::try_from(buffer.len()).unwrap_or(u32::MAX);
            // SAFETY: 缓冲区在操作被同步完成或取消前始终有效，句柄以 OVERLAPPED 打开。
            unsafe {
                ReadFile(
                    handle,
                    buffer.as_mut_ptr().cast(),
                    length,
                    ptr::null_mut(),
                    &mut overlapped,
                )
            }
        }
        WindowsPipeOperation::Write(buffer) => {
            let length = u32::try_from(buffer.len()).unwrap_or(u32::MAX);
            // SAFETY: 缓冲区在操作被同步完成或取消前始终有效，句柄以 OVERLAPPED 打开。
            unsafe {
                WriteFile(
                    handle,
                    buffer.as_ptr().cast(),
                    length,
                    ptr::null_mut(),
                    &mut overlapped,
                )
            }
        }
    };
    if started == 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
            return Err(error);
        }
    }

    let remaining = deadline.saturating_duration_since(Instant::now());
    // SAFETY: 事件句柄有效，等待时间由剩余截止时间有界转换。
    let wait_result = unsafe { WaitForSingleObject(event.0, windows_wait_millis(remaining)) };
    match wait_result {
        WAIT_OBJECT_0 => {
            let mut transferred = 0u32;
            // SAFETY: 事件已触发，GetOverlappedResult 读取同一个操作的最终结果。
            if unsafe { GetOverlappedResult(handle, &overlapped, &mut transferred, 0) } == 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(transferred as usize)
            }
        }
        WAIT_TIMEOUT => {
            cancel_and_drain_windows_io(handle, &mut overlapped)?;
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "paneflow IPC deadline elapsed",
            ))
        }
        WAIT_FAILED => {
            let error = io::Error::last_os_error();
            cancel_and_drain_windows_io(handle, &mut overlapped)?;
            Err(error)
        }
        other => {
            cancel_and_drain_windows_io(handle, &mut overlapped)?;
            Err(io::Error::other(format!(
                "unexpected Windows pipe wait result: {other}"
            )))
        }
    }
}

#[cfg(windows)]
fn write_all_with_deadline(
    stream: &Stream,
    mut payload: &[u8],
    deadline: Instant,
) -> io::Result<()> {
    while !payload.is_empty() {
        match windows_pipe_io(stream, WindowsPipeOperation::Write(payload), deadline) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "paneflow IPC write made no progress",
                ));
            }
            Ok(n) => payload = &payload[n..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[cfg(windows)]
fn read_line_with_deadline(stream: &Stream, deadline: Instant) -> io::Result<String> {
    let mut out = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match windows_pipe_io(stream, WindowsPipeOperation::Read(&mut chunk), deadline) {
            Ok(0) if out.is_empty() => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "paneflow closed the IPC connection without a response",
                ));
            }
            Ok(0) => break,
            Ok(n) => {
                out.extend_from_slice(&chunk[..n]);
                if let Some(pos) = out.iter().position(|&b| b == b'\n') {
                    out.truncate(pos + 1);
                    return String::from_utf8(out)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e));
                }
                if out.len() as u64 >= MAX_RESPONSE_LEN {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "paneflow response exceeded the size cap",
                    ));
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    String::from_utf8(out).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// EP-002 (agent-control-plane): open a persistent `events.subscribe` stream.
/// Writes the subscribe request, then invokes `on_line` for every newline-
/// delimited event the server pushes, until the connection closes (server side)
/// or `on_line` returns `false`. Unlike [`send_and_receive`], the read side is
/// NOT deadline-bounded: an idle stream is normal (the server heartbeats every
/// 30 s), so only a real disconnect (EOF / error) ends the loop.
pub fn subscribe_stream(
    socket: &Path,
    params: Value,
    mut on_line: impl FnMut(&str) -> bool,
) -> io::Result<()> {
    let name = socket.to_fs_name::<GenericFilePath>()?;
    let mut stream = Stream::connect(name)?;
    let request = build_request(1, "events.subscribe", params);
    let mut payload =
        serde_json::to_vec(&request).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    payload.push(b'\n');
    stream.write_all(&payload)?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut buf = Vec::new();
    while let Some(line) = read_capped_event_line(&mut reader, &mut buf)? {
        if line.trim().is_empty() {
            continue;
        }
        if !on_line(&line) {
            break;
        }
    }
    Ok(())
}

fn read_capped_event_line<R>(reader: &mut R, buf: &mut Vec<u8>) -> io::Result<Option<String>>
where
    R: BufRead,
{
    buf.clear();
    loop {
        let remaining = MAX_RESPONSE_LEN.saturating_sub(buf.len() as u64);
        if remaining == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "paneflow event line exceeded the size cap",
            ));
        }

        let read = reader.by_ref().take(remaining).read_until(b'\n', buf)?;
        if read == 0 {
            if buf.is_empty() {
                return Ok(None);
            }
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "paneflow event stream ended mid-line",
            ));
        }

        if buf.last() == Some(&b'\n') {
            if buf.ends_with(b"\r\n") {
                buf.truncate(buf.len().saturating_sub(2));
            } else {
                buf.truncate(buf.len().saturating_sub(1));
            }
            let line = String::from_utf8(buf.clone())
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            return Ok(Some(line));
        }
    }
}

/// What a single read slice of [`subscribe_stream_timed`] yielded.
pub enum StreamEvent<'a> {
    /// A complete, non-empty event line from the server (JSON).
    Line(&'a str),
    /// `slice` elapsed with no complete line: the caller's quiescence tick.
    /// This is the signal a bare [`subscribe_stream`] cannot deliver.
    Tick,
    /// EOF or a mid-stream socket error: the server vanished.
    Closed,
}

/// EP-003 US-007 (agent-control-plane-hardening): a [`subscribe_stream`] variant
/// whose read side IS deadline-bounded by `slice`. Where `subscribe_stream`
/// blocks forever between events, this wakes every `slice` with a
/// [`StreamEvent::Tick`] so the caller can detect the ABSENCE of events (output
/// quiescence) - the basis of `wait --idle`, with zero client-side polling of
/// pane content. A complete line yields [`StreamEvent::Line`]; EOF or a
/// mid-stream socket error yields [`StreamEvent::Closed`] then returns `Ok(())`
/// (the caller maps it to a clean "server gone" exit). Only a failed connect /
/// subscribe-write returns `Err` (no instance). `on_event` returns `false` to
/// stop.
///
/// Unlike [`send_and_receive`], the recv deadline here is REQUIRED, not
/// best-effort: the `Tick` contract is impossible without it, and a platform
/// that drops the timeout (Windows named pipes -> `Unsupported`) would block
/// forever in `read_line` instead of ticking - a hang past the caller's overall
/// deadline. So an `Unsupported` recv timeout is surfaced as `Err`; callers that
/// still need quiescence can fall back to another deterministic clock.
pub fn subscribe_stream_timed(
    socket: &Path,
    params: Value,
    slice: Duration,
    mut on_event: impl FnMut(StreamEvent<'_>) -> bool,
) -> io::Result<()> {
    let name = socket.to_fs_name::<GenericFilePath>()?;
    let mut stream = Stream::connect(name)?;
    // REQUIRED (see the doc note): without a recv deadline the read below would
    // block forever between events, so refuse rather than hang.
    stream.set_recv_timeout(Some(slice)).map_err(|e| {
        if e.kind() == io::ErrorKind::Unsupported {
            io::Error::new(
                io::ErrorKind::Unsupported,
                "the event stream needs a recv-timeout-capable socket (this \
                 platform's named pipe rejects it)",
            )
        } else {
            e
        }
    })?;
    let request = build_request(1, "events.subscribe", params);
    let mut payload =
        serde_json::to_vec(&request).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    payload.push(b'\n');
    stream.write_all(&payload)?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    // BYTES, not a `String`: `read_line` validates UTF-8 on every read, so a
    // multibyte codepoint bisected by a recv-slice boundary would surface as
    // `InvalidData` and be mis-read as a disconnect. `read_until(b'\n')` defers
    // validation to the complete line. Reused across slices so a split line is
    // reassembled rather than fed in halves.
    let mut buf: Vec<u8> = Vec::new();
    loop {
        // Bound each line at the same 256 KiB cap as a request/response reply,
        // so a same-UID server flooding one unterminated line can't grow `buf`
        // without bound (parity with `send_and_receive`). `remaining` shrinks as
        // the line accumulates across slices.
        let remaining = MAX_RESPONSE_LEN.saturating_sub(buf.len() as u64);
        if remaining == 0 {
            // One line exceeded the cap without terminating: framing abuse - the
            // server is not speaking our protocol, treat it as gone.
            on_event(StreamEvent::Closed);
            return Ok(());
        }
        match reader.by_ref().take(remaining).read_until(b'\n', &mut buf) {
            // Clean EOF: the server closed the stream.
            Ok(0) => {
                on_event(StreamEvent::Closed);
                return Ok(());
            }
            // A whole line landed (terminated by the newline).
            Ok(_) if buf.last() == Some(&b'\n') => {
                let keep = {
                    let line = String::from_utf8_lossy(&buf);
                    let line = line.trim();
                    line.is_empty() || on_event(StreamEvent::Line(line))
                };
                buf.clear();
                if !keep {
                    return Ok(());
                }
            }
            // `Ok(n>0)` with no trailing newline = EOF mid-line (or the cap was
            // hit, handled by `remaining == 0` next pass): server gone.
            Ok(_) => {
                on_event(StreamEvent::Closed);
                return Ok(());
            }
            // The recv slice elapsed with no (further) bytes: a quiescence tick.
            // Any partial bytes already read stay in `buf` for the next slice.
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                if !on_event(StreamEvent::Tick) {
                    return Ok(());
                }
            }
            // A mid-stream socket error means the peer vanished; surface it as
            // Closed (a clean caller exit), not Err (which means "no instance").
            Err(_) => {
                on_event(StreamEvent::Closed);
                return Ok(());
            }
        }
    }
}

/// Resolve the Paneflow IPC socket path. `PANEFLOW_SOCKET_PATH` (inherited
/// from the Paneflow PTY through the agent that launched this process) is
/// authoritative - it carries the exact path the running instance bound.
/// Falls back to the current build profile's default (`paneflow-dev` in debug,
/// `paneflow` in release), mirroring `src-app/src/runtime_paths.rs`.
pub fn resolve_socket_path() -> Option<PathBuf> {
    if let Some(p) = socket_path_from_env(std::env::var("PANEFLOW_SOCKET_PATH").ok().as_deref()) {
        return Some(p);
    }
    default_socket_path()
}

/// Validate a `PANEFLOW_SOCKET_PATH` value: present and absolute. A relative
/// path means the env was clobbered or we're outside a Paneflow PTY.
pub(crate) fn socket_path_from_env(raw: Option<&str>) -> Option<PathBuf> {
    let path = PathBuf::from(raw?);
    path.is_absolute().then_some(path)
}

/// Best-effort default socket path, mirroring `src-app/src/runtime_paths.rs`.
/// Uses raw env (no `dirs` dep) to keep the dependency tree minimal.
#[cfg(unix)]
fn default_socket_path() -> Option<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| {
            std::env::var_os("TMPDIR")
                .map(PathBuf::from)
                .filter(|p| !p.as_os_str().is_empty())
        })
        // 4th level, mirroring the server's `dirs::cache_dir().join("run")`
        // (`runtime_paths::runtime_dir`). Without this, a client whose $TMPDIR
        // is stripped (launchd/cron) returned None - "IPC unreachable" - even
        // though the server had bound under the cache dir.
        .or_else(cache_run_dir)?;
    let subdir = if cfg!(debug_assertions) {
        "paneflow-dev"
    } else {
        "paneflow"
    };
    let socket_file = if cfg!(debug_assertions) {
        "paneflow-dev.sock"
    } else {
        "paneflow.sock"
    };
    Some(runtime.join(subdir).join(socket_file))
}

/// Compute `<cache_dir>/run` from raw env, mirroring the server's last-resort
/// fallback without taking a `dirs` dependency (the whole point of this crate's
/// minimal tree). Linux: `$XDG_CACHE_HOME` or `$HOME/.cache`; macOS:
/// `$HOME/Library/Caches`.
#[cfg(unix)]
fn cache_run_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(|h| PathBuf::from(h).join("Library").join("Caches").join("run"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .filter(|p| !p.as_os_str().is_empty())
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .map(|c| c.join("run"))
    }
}

/// Windows default: the named-pipe path for the current build profile. Mirrors
/// `runtime_paths::socket_path` on Windows.
#[cfg(windows)]
fn default_socket_path() -> Option<PathBuf> {
    Some(PathBuf::from(if cfg!(debug_assertions) {
        r"\\.\pipe\paneflow-dev"
    } else {
        r"\\.\pipe\paneflow"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tolerate_unsupported_swallows_only_unsupported() {
        // Regression (prd-windows-port): Windows named pipes reject I/O
        // deadlines with ErrorKind::Unsupported. That must NOT fail the IPC
        // call (it silently broke the MCP bridge + CLI on Windows); any other
        // error must still propagate.
        assert!(tolerate_unsupported(Ok(())).is_ok());
        assert!(
            tolerate_unsupported(Err(io::Error::from(io::ErrorKind::Unsupported))).is_ok(),
            "Unsupported (named-pipe timeout) must be tolerated"
        );
        let other = tolerate_unsupported(Err(io::Error::from(io::ErrorKind::PermissionDenied)));
        assert_eq!(
            other.unwrap_err().kind(),
            io::ErrorKind::PermissionDenied,
            "a real error must still propagate unchanged"
        );
    }

    #[test]
    fn build_request_has_jsonrpc_envelope() {
        let req = build_request(7, "surface.list", json!({}));
        assert_eq!(req["jsonrpc"], "2.0");
        assert_eq!(req["id"], 7);
        assert_eq!(req["method"], "surface.list");
        assert_eq!(req["params"], json!({}));
    }

    #[test]
    fn parse_response_extracts_result() {
        let line = r#"{"jsonrpc":"2.0","result":{"surfaces":[]},"id":1}"#;
        let result = parse_response(line).expect("ok");
        assert_eq!(result, json!({"surfaces": []}));
    }

    #[test]
    fn parse_response_translates_error_envelope() {
        let line = r#"{"jsonrpc":"2.0","error":{"code":-32602,"message":"surface_id 9 not found"},"id":1}"#;
        let err = parse_response(line).expect_err("err");
        assert!(err.contains("-32602"), "got: {err}");
        assert!(err.contains("not found"), "got: {err}");
    }

    #[test]
    fn jsonrpc_error_message_detects_stream_error_line() {
        let line = r#"{"jsonrpc":"2.0","error":{"code":-32602,"message":"bad filter"},"id":null}"#;
        let err = jsonrpc_error_message(line).expect("error");
        assert!(err.contains("-32602"), "got: {err}");
        assert!(err.contains("bad filter"), "got: {err}");
        assert!(jsonrpc_error_message(r#"{"type":"subscribed"}"#).is_none());
    }

    #[test]
    fn parse_response_rejects_missing_result_and_error() {
        let line = r#"{"jsonrpc":"2.0","id":1}"#;
        assert!(parse_response(line).is_err());
    }

    #[test]
    fn parse_response_rejects_malformed_json() {
        assert!(parse_response("not json").is_err());
    }

    #[test]
    fn capped_event_line_rejects_oversized_unterminated_frame() {
        let data = vec![b'x'; MAX_RESPONSE_LEN as usize];
        let mut reader = BufReader::new(std::io::Cursor::new(data));
        let mut buf = Vec::new();
        let err = read_capped_event_line(&mut reader, &mut buf).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn capped_event_line_reads_one_frame() {
        let mut reader = BufReader::new(std::io::Cursor::new(b"{\"type\":\"ai.stop\"}\nrest"));
        let mut buf = Vec::new();
        let line = read_capped_event_line(&mut reader, &mut buf)
            .expect("read")
            .expect("line");
        assert_eq!(line, "{\"type\":\"ai.stop\"}");
    }

    #[test]
    fn socket_path_from_env_requires_absolute() {
        // "Absolute" is platform-specific: a Unix domain-socket path on Unix,
        // the named-pipe device path on Windows (`Path::is_absolute` accepts
        // `\\.\pipe\…`). The previous Unix-only literal made this test fail on
        // Windows, where `/run/...` is NOT absolute (no drive) and
        // `socket_path_from_env` correctly returned None.
        #[cfg(not(windows))]
        let absolute = "/run/user/1000/paneflow/paneflow.sock";
        #[cfg(windows)]
        let absolute = r"\\.\pipe\paneflow";
        assert_eq!(
            socket_path_from_env(Some(absolute)),
            Some(PathBuf::from(absolute))
        );
        assert_eq!(socket_path_from_env(Some("relative/path.sock")), None);
        assert_eq!(socket_path_from_env(Some("")), None);
        assert_eq!(socket_path_from_env(None), None);
    }

    #[cfg(windows)]
    #[test]
    fn windows_default_socket_path_matches_build_profile() {
        let expected = if cfg!(debug_assertions) {
            r"\\.\pipe\paneflow-dev"
        } else {
            r"\\.\pipe\paneflow"
        };
        assert_eq!(default_socket_path(), Some(PathBuf::from(expected)));
    }

    /// Windows 回归：真实命名管道成功响应后，客户端必须正常返回而不是触发
    /// interprocess 的 PIPE_NOWAIT fast-fail。该测试覆盖生产使用的真实传输层。
    #[cfg(windows)]
    #[test]
    fn windows_ipc_client_round_trips_against_a_live_pipe() {
        use interprocess::local_socket::{Listener, ListenerOptions};

        let _guard = windows_ipc_test_lock();
        let path = unique_windows_test_pipe("roundtrip");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
        let client =
            std::thread::spawn(move || IpcClient::new(path).call("workspace.list", json!({})));

        let mut stream = listener.accept().expect("accept");
        let mut line = String::new();
        {
            let mut reader = BufReader::new(&mut stream);
            reader.read_line(&mut line).expect("read request");
        }
        let request: Value = serde_json::from_str(line.trim()).expect("parse request");
        let response = json!({
            "jsonrpc": "2.0",
            "id": request["id"].clone(),
            "result": {"workspaces": []},
        });
        let mut serialized = serde_json::to_vec(&response).unwrap();
        serialized.push(b'\n');
        stream.write_all(&serialized).expect("write response");
        let result = client.join().expect("client thread").expect("call ok");
        assert_eq!(result, json!({"workspaces": []}));
    }

    /// Windows 回归：服务端保持连接但不响应时，重叠读取必须在短截止时间后取消，
    /// 不能永久阻塞，也不能把持有缓冲区的遗留线程留在进程中。
    #[cfg(windows)]
    #[test]
    fn windows_ipc_read_deadline_cancels_pending_io() {
        use interprocess::local_socket::{Listener, ListenerOptions};

        let _guard = windows_ipc_test_lock();
        let path = unique_windows_test_pipe("timeout");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
        let request = build_request(1, "workspace.list", json!({}));
        let client = std::thread::spawn(move || {
            let started = Instant::now();
            let error = send_and_receive_with_timeout(&path, &request, Duration::from_millis(100))
                .expect_err("muted server must time out");
            (error, started.elapsed())
        });

        let mut stream = listener.accept().expect("accept");
        let mut line = String::new();
        BufReader::new(&mut stream)
            .read_line(&mut line)
            .expect("read request");
        let (error, elapsed) = client.join().expect("client thread");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_secs(2),
            "deadline cancellation took too long"
        );
    }

    /// Windows 回归：连接、背压写入和响应读取必须共用一个总 deadline，不能在每个
    /// 阶段重新获得完整时限。服务端分两段消耗时间，旧的分段 deadline 会错误成功。
    #[cfg(windows)]
    #[test]
    fn windows_round_trip_uses_one_absolute_deadline() {
        use interprocess::local_socket::{Listener, ListenerOptions};

        let _guard = windows_ipc_test_lock();
        let path = unique_windows_test_pipe("absolute-deadline");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
        let request = build_request(
            1,
            "workspace.list",
            json!({"payload": "x".repeat(240 * 1024)}),
        );
        let client = std::thread::spawn(move || {
            let started = Instant::now();
            let error = send_and_receive_with_timeout(&path, &request, Duration::from_millis(120))
                .expect_err("combined write and read delays must exhaust the total deadline");
            (error, started.elapsed())
        });

        let mut stream = listener.accept().expect("accept");
        std::thread::sleep(Duration::from_millis(80));
        let mut line = String::new();
        BufReader::new(&mut stream)
            .read_line(&mut line)
            .expect("read request after write backpressure");
        std::thread::sleep(Duration::from_millis(80));
        let response = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n";
        // interprocess 的同步 Write 在对端已关闭时会触发同类 fast-fail；测试服务端也用
        // 共享重叠 I/O primitive 发送迟到响应，确保失败只来自总 deadline 语义。
        let _ = windows_pipe_io(
            &stream,
            WindowsPipeOperation::Write(response),
            Instant::now() + Duration::from_secs(1),
        );

        let (error, elapsed) = client.join().expect("client thread");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(elapsed < Duration::from_millis(220));
    }

    /// Windows 回归：one-way frame 也必须经过共享 transport seam，并保持换行 framing。
    #[cfg(windows)]
    #[test]
    fn windows_one_way_frame_round_trips_on_shared_transport() {
        use interprocess::local_socket::{Listener, ListenerOptions};

        let _guard = windows_ipc_test_lock();
        let path = unique_windows_test_pipe("one-way");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
        let frame = json!({"jsonrpc": "2.0", "method": "ai.stop", "id": 7});
        let frame_for_client = frame.clone();
        let client = std::thread::spawn(move || {
            send_frame_with_timeout(&path, &frame_for_client, Duration::from_secs(1))
                .expect("send frame");
        });
        let stream = listener.accept().expect("accept");
        let mut line = String::new();
        BufReader::new(stream)
            .read_line(&mut line)
            .expect("read frame");
        client.join().expect("client thread");
        assert!(line.ends_with('\n'));
        assert_eq!(serde_json::from_str::<Value>(line.trim()).unwrap(), frame);
    }

    /// Windows 回归：对端接受但完全不读取时，大 frame 必须按绝对 deadline 取消。
    /// 连续超时后的句柄数不得持续增长，且同一 transport 仍能完成下一次成功发送。
    #[cfg(windows)]
    #[test]
    fn windows_one_way_write_timeout_releases_handles_and_recovers() {
        use interprocess::local_socket::{Listener, ListenerOptions};

        let _guard = windows_ipc_test_lock();
        let before = current_process_handle_count();
        let large_frame = json!({"payload": "x".repeat(240 * 1024)});
        for iteration in 0..4 {
            let path = unique_windows_test_pipe(&format!("write-timeout-{iteration}"));
            let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
            let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
            let frame = large_frame.clone();
            let client = std::thread::spawn(move || {
                let started = Instant::now();
                let error = send_frame_with_timeout(&path, &frame, Duration::from_millis(30))
                    .expect_err("peer that never drains must time out");
                (error, started.elapsed())
            });

            // 由当前线程立即进入 accept，避免客户端在服务端线程尚未调度时完成连接并关闭，
            // 导致测试夹具错过该连接后永久阻塞；接受后故意不读取以制造真实背压。
            let _stream = listener.accept().expect("accept");
            let (error, elapsed) = client.join().expect("client thread");
            assert_eq!(error.kind(), io::ErrorKind::TimedOut);
            assert!(elapsed < Duration::from_secs(1));
        }
        let after = current_process_handle_count();
        assert!(
            after <= before + 1,
            "repeated timeouts leaked handles: before={before}, after={after}"
        );

        let path = unique_windows_test_pipe("write-recovery");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();
        let recovery = json!({"type": "recovered"});
        let recovery_for_client = recovery.clone();
        let client = std::thread::spawn(move || {
            send_frame_with_timeout(&path, &recovery_for_client, Duration::from_secs(1))
                .expect("transport must recover after timeouts");
        });
        let stream = listener.accept().expect("accept");
        let mut line = String::new();
        BufReader::new(stream)
            .read_line(&mut line)
            .expect("read recovery frame");
        client.join().expect("client thread");
        assert_eq!(
            serde_json::from_str::<Value>(line.trim()).unwrap(),
            recovery
        );
    }

    /// 串行化会操作真实命名管道和进程句柄计数的 Windows 回归测试。
    #[cfg(windows)]
    fn windows_ipc_test_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        LOCK.lock().unwrap()
    }

    /// 读取当前进程句柄数，用于确认连续取消不会泄漏事件或管道句柄。
    #[cfg(windows)]
    fn current_process_handle_count() -> u32 {
        use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetProcessHandleCount};

        let mut count = 0u32;
        // SAFETY: GetCurrentProcess 返回伪句柄，count 指向可写 u32。
        let ok = unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut count) };
        assert_ne!(ok, 0, "GetProcessHandleCount failed");
        count
    }

    /// 生成进程内唯一的命名管道，避免并行测试之间争用固定名称。
    #[cfg(windows)]
    fn unique_windows_test_pipe(label: &str) -> PathBuf {
        static NEXT_PIPE_ID: AtomicU64 = AtomicU64::new(1);
        PathBuf::from(format!(
            r"\\.\pipe\paneflow-ipc-client-{label}-{}-{}",
            std::process::id(),
            NEXT_PIPE_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    /// US-005 AC: a full request/response round-trip over a real local socket
    /// (not just the pure helpers). Spins up an `interprocess` listener that
    /// speaks the Paneflow framing - read one newline-delimited request, echo
    /// its `id` back in a JSON-RPC `result` envelope. Unix-only: the test path
    /// is a filesystem socket, not a Windows `\\.\pipe\` name.
    #[cfg(unix)]
    #[test]
    fn ipc_client_round_trips_against_a_live_socket() {
        use interprocess::local_socket::{Listener, ListenerOptions};
        use interprocess::TryClone;

        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("paneflow-test.sock");
        let name = path.as_path().to_fs_name::<GenericFilePath>().unwrap();
        let listener: Listener = ListenerOptions::new().name(name).create_sync().unwrap();

        let server = std::thread::spawn(move || {
            let stream = listener.accept().expect("accept");
            let mut writer = stream.try_clone().expect("clone");
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).expect("read request");
            let request: Value = serde_json::from_str(line.trim()).expect("parse request");
            // Echo the client's id back, mirroring the real server contract.
            let response = json!({
                "jsonrpc": "2.0",
                "id": request["id"].clone(),
                "result": {"surfaces": [{"surface_id": 1u64, "name": "cargo-run"}]},
            });
            let mut serialized = serde_json::to_string(&response).unwrap();
            serialized.push('\n');
            writer
                .write_all(serialized.as_bytes())
                .expect("write response");
            writer.flush().expect("flush");
        });

        let client = IpcClient::new(path);
        let result = client.call("surface.list", json!({})).expect("call ok");
        assert_eq!(result["surfaces"][0]["name"], "cargo-run");

        server.join().expect("server thread");
    }

    #[cfg(unix)]
    #[test]
    fn ipc_client_call_errors_when_socket_missing() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("does-not-exist.sock");
        let client = IpcClient::new(path);
        let err = client
            .call("surface.list", json!({}))
            .expect_err("must fail with no listener");
        assert!(err.contains("unreachable"), "got: {err}");
    }
}
