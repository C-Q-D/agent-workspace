# 新工作区默认值 Windows 验收报告

## 结论

UNIT-38 于 2026-07-19 验收通过。AgentWorkspace 已为 Windows 用户提供新工作区默认
引用格式与 Git 自动初始化开关；配置缺失时保持 `common` 和自动初始化开启的历史行为。
关闭开关只禁止为非 Git 根目录创建 `.git`，不会影响已有仓库；恢复工作区继续使用自己
保存在会话中的引用格式，不会被之后修改的全局默认覆盖。

## 精确构建

- 源码提交：`8860bb344777a43f44f9c9ecba1c4f76bd0dba91`。
- 构建命令：`cargo build --release -p paneflow-app`。
- 构建耗时：4 分 35 秒。
- Release 程序：`target/release/agent-workspace.exe`。
- 版本：`agent-workspace 0.7.11`。
- 文件大小：73,537,024 字节。
- SHA-256：`a0ef347d44220394846d63e96a5745716a6e3aa355125821c01a51afe6af518f`。

## 隔离与真实运行方式

验收脚本把 `USERPROFILE` 和 `HOME` 指向仓库外的全新隔离目录，并使用唯一命名管道
`\\.\pipe\agent-workspace-defaults-20260719-225223`。两次运行都启动真实 Windows GUI、
PowerShell/ConPTY 和生产 IPC；其中一个工作区由同一 Release 程序的真实 `new --cwd`
CLI 创建。非 Git 和已有 Git 夹具均为磁盘上的真实目录，不使用 mock 或内存替身。

可重复脚本：`scripts/运行Windows新工作区默认值验收.ps1`。

机器证据：`docs/验收/新工作区默认值数据/Release-20260719-225223/运行结果.json`。

## 场景与结果

| 场景 | 结果 | 证据 |
|---|---|---|
| `workspace.create` + `claude` 默认值 | 通过 | `RPC-Claude` 返回并持久化 `reference_format=claude` |
| `workspace.up` + `claude` 默认值 | 通过 | `UP-Claude` 返回并持久化 `reference_format=claude` |
| 真实 CLI `new --cwd` + `claude` 默认值 | 通过 | CLI 退出码 0，响应为 `reference_format=claude` |
| `git_auto_init=false` 的三个非 Git 根目录 | 通过 | 等待四秒后均不存在 `.git`，原项目文件保持存在 |
| 关闭开关时加载已有 Git 仓库 | 通过 | 仓库仍存在、终端运行，未删除或重写 `.git` |
| 全局默认由 `claude` 改为 `codex` 后重启 | 通过 | 四个恢复工作区仍全部为 `claude` |
| 新工作区使用重启后的 `codex` 默认值 | 通过 | `RPC-Codex` 为 `codex`，并真实创建 `.git` |
| 运行中配置 watcher 更新为 `powershell` | 通过 | 后续工作区为 `powershell`，并真实创建 `.git` |
| 运行中配置 watcher 更新为 `common` | 通过 | 后续工作区为 `common`，并真实创建 `.git` |
| 配置写入一致性 | 通过 | 创建期间时间戳不变；最后一次外部写入后无高频回写；未知字段保留 |
| 会话一致性 | 通过 | 两次正常退出均写入真实 `sessions/workspaces.json` |
| 进程生命周期 | 通过 | 两次 GUI 均正常退出码 0，所有记录的 PowerShell/ConPTY 后代归零 |

## 资源结果

| 阶段 | 工作区/终端 | 两秒 CPU 增量 | Working Set | Private Memory | 线程 | 句柄 |
|---|---:|---:|---:|---:|---:|---:|
| 禁用 Git 初始化 | 4 | 109.375 ms | 146.305 MiB | 128.516 MiB | 34 | 549 |
| 恢复并启用 Git | 7 | 218.750 ms | 155.973 MiB | 150.496 MiB | 47 | 597 |

两个设置仅在用户操作时写入配置，在创建或恢复工作区时读取一次。验收两秒窗口中的桌面
进程 CPU 增量远低于 1000 ms 门槛，没有发现由本功能引入的轮询、高频写盘或常驻服务。

## 自动化回归

- `cargo test -p paneflow-config`：111 项通过。
- `cargo test -p paneflow-app`：1453 项通过。
- `cargo test -p paneflow-app --test flex_nchild`：5 项通过。
- General 引用格式映射定向测试：3 项通过。
- 设置导航搜索定向测试：2 项通过。
- `cargo fmt --all -- --check` 与 `git diff --check`：通过。

## 日志说明

验收直接运行单个 Release EXE，没有复制发行包中的 AI hook helper，因此错误输出包含既有的
“packaged Windows helper dir missing”警告；隔离环境的更新检查也返回既有 404。两项均与
新工作区默认值无关，不影响终端、Git、配置或会话断言。正式 ZIP/MSI 会携带完整 helper，
其载荷边界已由 P2-03 与 P2-04 的发行验收覆盖。

## 完成判定

UNIT-38 的配置契约、三类显式创建入口、会话恢复、Git lifecycle、General 设置入口、
Windows Release、配置/应用/布局回归及资源边界全部通过，可以进入 UNIT-39 矩阵密度。
