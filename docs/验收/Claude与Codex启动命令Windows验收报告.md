# Claude 与 Codex 启动命令 Windows 验收报告

## 结论

UNIT-37 已在真实 Windows Release、真实 PowerShell 7 和真实 ConPTY 窗格中通过验收。Claude Code 与 Codex 的默认命令保持不变；自定义完整命令可包含带空格路径和参数，应用重启后仍由所有共享启动路径正确读取。设置功能没有引入轮询、常驻线程或逐键磁盘写入。

## 验收基线

- 日期：2026-07-19
- 分支：`experiment/e01-pty-decoupling`
- 业务代码提交：`e41b2b3f7f638edbd076638eadee304c73c87cfc`
- 操作系统：Microsoft Windows 11 专业版，版本 `10.0.26200`，Build `26200`
- CPU：13th Gen Intel Core i7-13700H
- 机器内存：31.6 GiB
- PowerShell：7.6.3
- Rust/Cargo：1.96.1
- Release 产物：`target/release/agent-workspace.exe`
- Release 大小：73,553,408 字节
- 版本输出：`agent-workspace 0.7.11`

## 隔离边界

验收使用仓库 `target/atom37-release-home` 作为临时 `USERPROFILE`，因此 Release 只读取 `target/atom37-release-home/.agent-workspace/config/settings.json`。IPC 使用独立命名管道 `\\.\pipe\agent-workspace-atom37-release`，未读取或修改当前登录用户的 `.agent-workspace` 数据。

测试配置保留一个运行时未知字段 `future_setting.preserved = true`，并为 Claude/Codex 分别配置以下等价命令：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "<带空格目录>\记录启动参数.ps1" -Agent <claude|codex> -Profile "Windows Release QA"
```

记录脚本只把收到的参数、PowerShell 进程 ID 和 `USERPROFILE` 写入隔离日志，然后以退出码 0 结束；没有调用真实模型或网络服务。

## 验收结果

| 场景 | 结果 | 证据 |
|---|---|---|
| 缺省配置 | 通过 | 全新隔离目录解析为 `Clear-Host; claude` 与 `Clear-Host; codex`，本机 PATH 探测成功 |
| 自定义配置读取 | 通过 | 新 Release CLI 进程逐字保留完整自定义命令；共享启动层只添加既有 `Clear-Host; ` 前缀 |
| 带空格脚本路径 | 通过 | 两个真实 PowerShell/ConPTY 收据均生成 |
| 带空格参数 | 通过 | Claude、Codex 均收到 `Windows Release QA` |
| Agent 区分 | 通过 | 收据分别为 `claude` 与 `codex` |
| 隔离用户目录 | 通过 | 两个子进程收到的 `USERPROFILE` 均为隔离目录 |
| Release 重启读取 | 通过 | 同一配置连续启动两次独立 Release，结果一致 |
| 子进程退出 | 通过 | 两轮 Claude/Codex 记录进程均已退出，残留记录脚本进程为 0 |
| 应用正常关闭 | 通过 | 两轮 `CloseMainWindow` 均以应用退出码 0 完成，无需强制终止 |
| 未知字段保留 | 通过 | 两轮结束后 `future_setting.preserved` 仍为 `true` |
| 启动阶段配置写入 | 通过 | 两轮运行前后 `settings.json` 时间戳不变 |
| Release 工作集采样 | 通过 | 两个测试窗格退出后分别为 140.7 MiB、146.1 MiB |

## 设置保存与性能证据

- 命令输入只更新内存中的单行输入实体，不在每个按键时写盘。
- 只有 Enter、真正失焦、离开 AI Agent 页面、关闭设置页或恢复默认会调度一次后台保存。
- 同一字段使用单调保存代次，旧异步任务在全局配置写锁内部确认自己仍是最新值；不同字段使用独立代次。
- 真实临时文件并发测试确认 Claude/Codex 同时保存不会互相覆盖，也不会丢弃未知字段。
- 生产差异中没有新增 `thread::spawn`、timer、interval、配置 watcher 或轮询；出现的两个 `std::thread::spawn` 仅用于并发文件写入测试。
- 生产保存使用现有 GPUI 异步执行器配合 `smol::unblock`，任务在用户提交后完成并释放，不形成常驻工作线程。

## 自动回归

- `cargo fmt --all -- --check`：通过。
- `cargo test -p paneflow-config`：109 通过，0 失败。
- `cargo test -p paneflow-app`：1447 通过，0 失败。
- `src-app/tests/flex_nchild.rs`：5 通过，0 失败。
- 定向设置测试：命令输入边界 2 项、导航搜索 1 项、配置写入 16 项全部通过。
- 既有真实 ConPTY 回归 `custom_agent_command_reaches_real_powershell_conpty` 与普通终端回归 `plain_terminal_echoes_without_paneflow_identity` 均通过。

## 已知非阻塞项

严格 `cargo clippy -p paneflow-app --tests -- -D warnings` 仍被仓库现有 6 项告警阻断，涉及旧测试字节串、上一原子的可省略生命周期和其他既有模块排版；本次设置界面最初产生的测试模块位置告警已经修复，复查后不再出现在告警列表。本单元未为通过验收而修改无关代码。

## 完成判定

ATOM-37-01～04 的配置契约、统一启动消费、轻量设置界面和真实 Windows 总验收均已完成。UNIT-37 可以关闭，下一交付单元进入“新工作区默认引用格式与 Git 自动初始化开关”。
