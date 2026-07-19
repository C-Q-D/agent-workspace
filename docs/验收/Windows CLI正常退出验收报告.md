# Windows CLI 正常退出验收报告

## 验收结论

UNIT-22 通过。Windows Release CLI 在成功完成本地 IPC 请求后能够输出完整结果并以退出码 `0` 结束，不再出现 `0xC0000409`。业务错误、参数错误和服务端不可达仍保持原有非零退出语义，桌面服务端关闭后无 Paneflow 进程残留。

## 修复边界

- 根因：`interprocess 2.4` 的同步重叠 I/O 与 `PIPE_NOWAIT` 组合会在成功请求路径触发 Windows fast-fail。
- 修复：连接保持阻塞命名管道模式，读写改为带事件的原生 Windows 重叠 I/O。
- 截止时间：读写方向均保留 10 秒截止时间；超时会调用 `CancelIoEx`，随后同步回收完成通知。
- 未改变：JSON-RPC 协议、256 KiB 响应上限、CLI 命令语义、工作区创建流程和 GUI 生命周期。

## Release 真实进程结果

验收二进制：`target/release/paneflow.exe`，大小 `73,209,856` 字节，SHA-256 为 `13BA1A84C9ED77957C9F5E94DCDFCE9D7B2B0FC560EF2D4FB14DE34EACE34BDE`。

| 场景 | 预期 | 结果 |
| --- | --- | --- |
| 非 Git 目录执行 `new --cwd`，第 1 次 | 创建工作区、初始化 Git、退出 0 | 退出 0，工作区 1，Git 存在，约 348 ms |
| 非 Git 目录执行 `new --cwd`，第 2 次 | 可重复成功 | 退出 0，工作区 1，Git 存在，约 305 ms |
| 已有 Git 目录执行 `new --cwd` | 复用仓库并创建工作区 | 退出 0，工作区 1，Git 存在，约 310 ms |
| 空服务端执行 `ls` | 输出空列表、退出 0 | 退出 0，完整 JSON 输出，约 306 ms |
| 执行 `status 不存在的终端` | 保持业务错误语义 | 退出 3，错误信息完整，约 312 ms |
| `new` 缺少 `--cwd` | 参数错误 | 退出 2，usage 信息完整 |
| 未启动服务端执行 `ls` | 连接错误 | 退出 1，IPC 不可达信息完整 |

每次 GUI 场景都使用隔离的真实用户配置、真实命名管道、真实目录、真实 Git 和真实 PowerShell 终端，不使用模拟服务端或模拟数据。

## 自动化回归

- `cargo clippy -p paneflow-ipc-client --all-targets -- -D warnings`：通过。
- `cargo test --workspace`：全部通过；其中桌面应用 `1414/1414`、配置 `95/95`、IPC 客户端 `13/13`。
- Windows 实管道成功往返测试：通过。
- Windows 服务端静默时的 100 ms 取消与回收测试：通过。
- Debug 真实进程补充验证：成功命令退出 0，目标不存在退出 3，缺少参数退出 2，服务端不可达退出 1。

## 残留复核

首次汇总发现一个创建于修复前诊断阶段的空目录 `F:\AWCliExit-20260719-125349605`。该目录时间早于本轮 Release 验收且内容为空，不属于当前运行残留。核对固定绝对路径后删除，再次检查结果为：

- Paneflow 进程：`0`；
- `F:\AWCliExit-*` 验收目录：`0`。

完整结构化证据位于 `docs/验收/WindowsCLI正常退出数据/Release-20260719-131627/`。
