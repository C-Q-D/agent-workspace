# ATOM-36-01 Windows Release 用户数据写入清单验收报告

## 结论

ATOM-36-01 于 2026-07-19 验收通过。真实 Windows x64 Release 在隔离 `USERPROFILE` 中完成桌面启动、命名管道调用、工作区创建、PowerShell/ConPTY 启动、本地 `git init`、会话保存和正常退出。AgentWorkspace 自有新增写入全部位于隔离用户的 `.agent-workspace`，开发者现有 `.agent-workspace` 指纹未变化，旧 Paneflow 数据与外部目录哨兵保持不变，应用及其子进程零残留。

机器清单见 [Release-20260719-195902 运行结果](Windows用户数据边界数据/Release-20260719-195902/运行结果.json)。原始标准输出与错误输出保留在同一目录。

## 为何调整 Windows 主目录解析

审计确认 `dirs 6.0.0` 在 Windows 上直接调用 `SHGetKnownFolderPath(FOLDERID_Profile)`，不会采用子进程显式传入的 `USERPROFILE`。这意味着仅修改环境变量的完整 GUI 验收仍可能读写开发者真实数据。

本原子把 AgentWorkspace 自有数据主目录解析收敛到 `paneflow-config::data_layout::current_user_home()`：Windows 优先使用非空绝对 `USERPROFILE`，无效或缺失时回退系统 Known Folder；其他平台维持原有系统解析。正常登录环境两者指向同一用户目录，隔离 Release 则可以使用临时 profile。设置、会话和桌面运行时布局都复用同一入口。

## 真实写入清单

验收前预置合法设置与三个 durable 哨兵，验收后新增的 AgentWorkspace 文件如下：

| 路径 | 分类 | 原因 |
| --- | --- | --- |
| `.agent-workspace/bin/paneflow-mcp.exe` | durable | 启动时释放供外部 CLI 稳定引用的 MCP bridge |
| `.agent-workspace/cache/shell/pwsh/osc7.ps1` | rebuildable | 真实 PowerShell 终端按需生成 Shell 集成脚本 |
| `.agent-workspace/sessions/workspaces.json` | durable | 正常退出保存工作区会话 |

原有 `config/settings.json`、`state/durable-state-sentinel.txt` 和 `bin/durable-bin-sentinel.txt` 在运行前后 SHA-256 完全一致。

隔离用户目录还出现了 `AppData/Local/Microsoft/PowerShell` 目录。这是子 PowerShell 自身的运行时边界，不是 AgentWorkspace 自有持久化；脚本将其单独记录为 `externalPowerShellRuntime`，并拒绝其他未声明的 profile 顶层写入。

## 工作区与进程生命周期

- 验收夹具位于源码仓库之外，真实非 Git 目录由生产生命周期执行本地 `git init`。
- 工作区原文件字节不变，新增内容仅为标准 `.git` 元数据；没有 remote、commit 或 push。
- 运行时跟踪到 `agent-workspace`、`pwsh` 与 `conhost` 三个进程。
- 主窗口正常关闭后，三个受控进程全部退出；脚本没有用强制终止获得通过结果。
- 成功结果写入机器清单后，仓库外夹具通过固定卷根与固定前缀校验并清理。

## 边界结果

| 边界 | 结果 |
| --- | --- |
| AgentWorkspace 自有写入只位于隔离 `.agent-workspace` | 通过 |
| 开发者真实 `.agent-workspace` 指纹保持 | 通过 |
| 旧 Paneflow 数据哨兵保持 | 通过 |
| 外部目录哨兵保持 | 通过 |
| durable 哨兵逐字节保持 | 通过 |
| 非 Git 工作区本地初始化 | 通过 |
| 正常关闭与零残留 | 通过 |

## 失败诊断记录

首次运行把工作区夹具放在源码仓库的 `target/` 下，生产逻辑正确识别到它属于上层 Git 仓库，因此没有创建嵌套 `.git`，验收按规则失败。确认根因后只把夹具移动到仓库所在卷根，没有修改 Git 生命周期代码，第二次与最终复跑均通过。

完整回归首轮还出现一次 Markdown 100 KB 解析耗时 65.89 ms、略高于 60 ms 的性能门禁失败。该次采样紧随 7 分钟 Release LTO；在不修改代码的情况下，同一测试连续 5 次均约 20 ms 通过，系统负载稳定后完整桌面测试也通过，因此判定为单次调度抖动，没有放宽预算或修改解析器。

## 回归结果

| 检查 | 结果 |
| --- | --- |
| PowerShell 脚本语法检查 | 通过 |
| `cargo fmt --all -- --check` | 通过 |
| `cargo build --release --target x86_64-pc-windows-msvc -p paneflow-app --locked` | 通过 |
| 真实 Release GUI 写入清单 | 通过 |
| `cargo test -p paneflow-config --locked` | 106 个测试全部通过 |
| Markdown 性能门禁连续复核 | 5 次全部通过 |
| `cargo test -p paneflow-app --locked` | 1435 个主程序测试与 5 个布局集成测试全部通过 |

## 当前边界

本原子使用的是仓库构建的真实 Release 可执行文件，不是已安装或便携目录。错误输出中出现“打包 helper 目录不完整”的预期警告，因此没有把安装载荷中的 wrapper 计入本次清单；MSI 与便携包的打包 helper、升级、卸载、缓存重建和共同数据根由 ATOM-36-02、ATOM-36-03 继续真实验收。
