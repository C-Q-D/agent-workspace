# Windows 本地 IPC 传输验收报告

## 结论

UNIT-23 通过。CLI/MCP 的 request/response 与 AI hook 的 one-way frame 已共用 `paneflow-ipc-client` 传输层；Windows 生产代码不再出现 `nonblocking_stream(true)`，连接、写入与读取使用一个绝对 deadline，超时会取消并同步回收重叠 I/O。

真实 Release GUI、CLI 与 hook 组合均正常工作。Prompt hook 用时 33.475ms、Stop hook 用时 16.790ms，均退出 0；GUI 的 `fleet.list` 观察到 `codex / thinking / hooked=true`。CLI 成功与错误路径保持约定退出码，关闭后 GUI、hook 和验收目录均零残留。

## 验收对象

- 实现提交：`fbb32cec4bce98e44c01872851e3004f6511e79c`。
- `paneflow.exe` SHA-256：`3613EAB39D772B88BCCBE57B484CC8D7DFAB0654DC70A48AEFDAF970639041FE`。
- `paneflow-ai-hook.exe` SHA-256：`B7AC624B93406324D6DEC4C5744C49B9A94E159908894DBEE9F245608B77BC7C`。
- 证据目录：`docs/验收/Windows本地IPC传输数据/Release-20260719-135910/`。

## 自动化验证

1. `cargo fmt --all -- --check`：通过。
2. `cargo check -p paneflow-ipc-client -p paneflow-ai-hook`：通过。
3. `cargo clippy -p paneflow-ipc-client -p paneflow-ai-hook --all-targets -- -D warnings`：通过。
4. `cargo test -p paneflow-ipc-client -p paneflow-ai-hook`：hook 单元 34/34、hook 真实进程集成 16/16、IPC client 16/16。
5. `cargo test --workspace`：全工作区通过，其中主应用 1414/1414、配置 95/95、IPC client 16/16；其余 crate 与 doc tests 全部通过。
6. `cargo build --release -p paneflow-app -p paneflow-ai-hook`：通过，耗时 5分04秒。

IPC client 的 Windows 实管道回归覆盖：

- 成功 request/response；
- 服务端不响应时读取取消；
- 单向 frame 换行 framing；
- 对端接受但不读取时的大 frame 写入超时；
- 连续四次超时后句柄数不增长，并能恢复成功发送；
- 连接、写入和读取共用一个总 deadline，而不是逐阶段重置。

## Release 真实进程结果

| 场景 | 结果 | 退出码 |
| --- | --- | ---: |
| 非 Git 目录创建工作区 | 工作区创建成功，后台初始化真实 `.git` | 0 |
| 已有 Git 目录创建工作区 | 工作区创建成功，保留仓库 | 0 |
| 空工作区列表 | 返回空 surfaces | 0 |
| 目标终端不存在 | 输出明确错误 | 3 |
| `new` 缺少 `--cwd` | clap 拒绝并显示用法 | 2 |
| GUI 未启动时执行 `ls` | 输出 IPC 不可达 | 1 |
| Prompt hook | GUI 观察到 `codex / thinking / hooked=true` | 0 |
| Stop hook | frame 正常发送 | 0 |

旧 CLI 验收脚本在本轮暴露了一个采样竞态：工作区响应会先返回 `terminal_status=starting`，Git 准备随后在后台完成，脚本却在同一瞬间断言 `.git`。修正后脚本有界等待真实仓库落盘，没有改变产品行为或放宽最终断言。

## 资源与清理

- `paneflow.exe` 残留：0。
- `paneflow-ai-hook.exe` 残留：0。
- `F:\AWCliExit-*` 残留：0。
- `F:\AWIpcHook-*` 残留：0。
- 用户配置与会话在验收后恢复。
- `paneflow/` 样本仓库未修改；未执行远端推送。

## 裁定

ATOM-23-03 通过。UNIT-23 可以关闭，P1.5 不再有 Windows 本地 IPC 阻塞项。
