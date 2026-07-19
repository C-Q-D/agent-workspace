# Windows 本地 IPC 传输复核

## 结论

UNIT-22 只关闭了 CLI 请求响应路径的 `0xC0000409`，同一个 Windows 命名管道风险仍存在于 `paneflow-ai-hook`。这不是理论上的代码风格问题：hook 仍调用 `ConnectOptions::nonblocking_stream(true)`，随后通过 interprocess 2.4 的同步 `WriteFileEx` 路径写入并以 `WouldBlock` 轮询；该组合与 UNIT-22 已证实的 fast-fail 根因相同。

请求客户端本身还有三个 deadline 契约缺口：

1. 默认 `ConnectWaitMode::Unbounded`，10 秒限制不覆盖命名管道繁忙时的连接等待。
2. 写入和读取分别从当前时间新建 deadline，单次往返理论上可以接近 20 秒。
3. 取消后虽然调用 `GetOverlappedResult(..., TRUE)` 回收内核引用，但没有检查最终返回值，无法区分预期取消与异常回收失败。

因此 P1.5 不能在 UNIT-22 后直接结束，应建立 UNIT-23，把 request/response 与 one-way hook frame 收敛到同一个本地 IPC transport seam。

## 源码证据

- 请求客户端的深 interface：`crates/paneflow-ipc-client/src/lib.rs` 中 `IpcTransport::call`。
- Windows 重叠 I/O implementation：同文件 `windows_pipe_io` 与 `cancel_and_drain_windows_io`。
- hook 复制的危险连接：`crates/paneflow-ai-hook/src/main.rs` 中 `connect_frame_stream`。
- hook 复制的轮询写入：同文件 `write_all_with_deadline`。
- interprocess 2.4 默认连接策略：Windows `connect_by_path` 使用 `ConnectWaitMode::Unbounded`。

全仓修复完成后，生产代码中不应再出现 `nonblocking_stream(true)`，也不应存在第二份 Windows named-pipe deadline loop。

## 正确 seam

共享 transport module 应隐藏：

- Windows 命名管道与 Unix local socket adapter；
- 绝对 deadline 的建立和剩余时间计算；
- 连接等待、重叠读写、事件句柄、取消与同步回收；
- newline-delimited JSON frame 的序列化和写入；
- request/response 的响应大小上限。

调用方只保留两种真实 interface：一次 request/response，以及一次 one-way frame。hook 的 500 ms fail-silent 契约与 CLI 的 10 秒错误返回语义由调用方决定，不复制传输 implementation。

## 回归边界

- Windows 实管道成功 request/response。
- 服务端读请求但不响应时，读取在绝对 deadline 取消。
- 服务端接受连接但不读取时，大 frame 写入在绝对 deadline 取消。
- 管道繁忙时，连接等待受同一 deadline 约束。
- 连续超时后仍能成功完成下一次传输，且句柄数量不持续增长。
- 真实 hook 子进程仍保持失败静默、事件可达和退出码 0。
