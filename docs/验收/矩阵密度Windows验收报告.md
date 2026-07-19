# 矩阵密度 Windows 验收报告

## 结论

UNIT-39 于 2026-07-19 验收通过。AgentWorkspace 已支持 Auto、Comfortable、Compact
三种工作区矩阵密度；密度切换只重新计算卡片几何和分页，不替换 Terminal Surface，
不重启 PowerShell/ConPTY，也不丢失终端输出。Compact 设置在正常退出和重启后保持，
16 个真实工作区与 16 个 PowerShell 会话均可恢复。

验收过程中发现并修复了 Windows 多终端启动缺陷：应用曾在每次创建 PowerShell 时重写
同一个 `osc7.ps1`，可能与已启动 PowerShell 的读取发生共享冲突。提交 `898d588` 改为
内容相同时直接复用缓存脚本，内容过期时仍正常刷新。

## 精确构建

- 源码提交：`898d588b8ba3a3123ea738997bd74789d1640788`。
- 构建命令：`cargo build --release -p paneflow-app`。
- 构建耗时：4 分 59 秒。
- Release 程序：`target/release/agent-workspace.exe`。
- 版本：`agent-workspace 0.7.11`。
- 文件大小：73,543,680 字节。
- SHA-256：`79a1362df0701485e38b3c0c294f524771e8f823aeb97e3ad932eace96128472`。

## 隔离与真实运行方式

验收脚本使用全新隔离 `USERPROFILE`、`HOME` 和唯一命名管道，启动真实 Windows GUI、
16 个 PowerShell/ConPTY 终端及生产 IPC。每个终端都真实执行独立标记命令；脚本逐个
回读标记，并比较切换前后的 Surface ID 与 PowerShell PID，不使用 mock 数据。

截图使用 Windows `PrintWindow(PW_RENDERFULLCONTENT)` 让 AgentWorkspace 窗口直接离屏
绘制自身内容，不截取桌面，也不抢占、置顶或激活用户正在使用的其他软件。

可重复脚本：`scripts/运行Windows矩阵密度验收.ps1`。

机器证据：`docs/验收/矩阵密度数据/Release-20260719-235552/运行结果.json`。

## 界面与容量结果

固定产品窗口外框为 `1400×820`，中央区域会扣除左侧工作区列表后再规划矩阵。

| 密度 | 卡片最小尺寸 | 实际首屏 | 16 个工作区分页 | 视觉结论 |
|---|---:|---:|---:|---|
| Auto | `320×190` | 3×3 | 2 页 | 保持历史默认，终端正文仍有较好可读性 |
| Comfortable | `400×240` | 2×3 | 3 页 | 输出区更宽更高，适合同时阅读少量任务 |
| Compact | `260×150` | 4×4 | 1 页 | 适合观察 16 个任务状态，正文会增加换行 |

Compact 的设计目标是高密度监控，不替代单窗格放大阅读。四张关键证据分别为
`01-Auto-16终端.png`、`02-comfortable-16终端.png`、`02-compact-16终端.png` 和
`03-Compact-重启恢复.png`；人工复核确认均为 AgentWorkspace 自身离屏画面。

## 连续性与持久化结果

| 场景 | 结果 |
|---|---|
| 创建 16 个真实工作区、Surface 和 PowerShell | 通过，数量均为 16 |
| 向 16 个终端分别提交并回读连续性标记 | 通过，16 个标记均存在 |
| Auto → Comfortable | Surface ID、PowerShell PID、输出均不变 |
| Comfortable → Compact | Surface ID、PowerShell PID、输出均不变 |
| Compact → Auto | Surface ID、PowerShell PID、输出均不变 |
| 最终写入 Compact 后正常退出并重启 | 通过，配置、16 个工作区和 16 个终端恢复 |
| 未知配置字段 | 重启后仍保留 |
| 配置时间戳 | 用户写入后稳定，无高频回写 |
| 两轮正常退出 | 退出码为 0，记录的应用与终端进程残留为 0 |

## 资源结果

下表只统计 AgentWorkspace 桌面主进程，不把 16 个用户 PowerShell 子进程的自身开销
归因给矩阵密度功能。

| 阶段 | 两秒 CPU 增量 | Working Set | Private Memory | 线程 | 句柄 |
|---|---:|---:|---:|---:|---:|
| 首轮 16 终端完成切换后 | 78.125 ms | 172.973 MiB | 202.859 MiB | 70 | 686 |
| Compact 重启恢复后 | 828.125 ms | 190.102 MiB | 240.164 MiB | 82 | 665 |

两轮都低于 1200 ms/2 秒的验收门槛。密度实现只读取内存配置快照并做常数时间几何映射，
没有增加轮询、常驻服务或逐帧文件访问。重启后采样更接近 16 个会话恢复后的收尾阶段，
因此 CPU 高于首轮稳定采样，但仍在边界内。

## 自动化回归

- `cargo test -p paneflow-config`：112 项通过。
- `cargo test -p paneflow-app`：1457 项通过。
- `cargo test -p paneflow-app --test flex_nchild`：5 项通过。
- Shell 缓存复用与过期刷新定向测试：12 项 Shell 测试通过。
- `cargo fmt --all -- --check`、PowerShell 语法解析和 `git diff --check`：通过。

完整应用回归第一次运行时，Markdown 100KB 墙钟性能测试受瞬时调度影响以 68.95 ms
超过 60 ms 固定门槛；该测试随后独立连续三次通过，第二次完整 1457 项回归也通过，未修改
实现或放宽阈值。

## 日志说明

验收直接运行单个 Release EXE，没有复制发行包中的 AI hook helper，因此错误输出包含既有的
“packaged Windows helper dir missing”警告；隔离环境更新检查也返回既有 404。正式 ZIP/MSI
会携带 helper。这些警告与矩阵密度、Shell 缓存复用、配置和终端连续性无关。

## 完成判定

UNIT-39 的配置契约、纯矩阵几何、设置入口、热切换、Windows Release、16 终端连续性、
Compact 重启恢复、离屏视觉证据、资源边界和完整回归均通过，可以进入 P2 设置联合验收。
