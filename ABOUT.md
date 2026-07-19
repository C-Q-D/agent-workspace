# AgentWorkspace

AgentWorkspace 是一个面向 Windows 开源用户的原生多终端工作区，用于在同一桌面窗口中并行运行 Codex CLI、Claude Code CLI 和普通 PowerShell 会话。

## 一句话定位

用动态终端矩阵总览多个 AI 编程 CLI，在需要时放大单个终端，并围绕当前终端提供文件引用、代码行引用和 Git 改动审查。

## 核心特点

- **保留真实 CLI。** 每个窗格本质上仍是 Windows PowerShell/ConPTY 终端，不重新实现 Codex 或 Claude 对话协议。
- **多窗格总览与显式聚焦。** 动态 N×N 矩阵用于观察多个会话，只有用户主动选择时才进入或退出单窗口放大。
- **聚焦上下文。** 文件树、路径引用、代码行引用和 Git Review 只围绕当前放大的稳定 `workspaceRoot` 展示。
- **面向 16GB 设备。** 产品和验收把 CPU、内存、切换延迟、长稳与进程零残留作为硬指标。
- **Windows 优先。** 当前只承诺 Windows 10/11 x64，不承诺 macOS、Linux、WSL、SSH 或远程工作区。

## 上游关系

AgentWorkspace 基于 [Paneflow](https://github.com/ArthurDEV44/paneflow) 修改，不是 Paneflow 官方发行版。派生基线、修改日期、双方版权和责任边界见[《上游归属与修改说明》](上游归属与修改说明.md)。

## 许可证

AgentWorkspace 整体按 [GPL-3.0-or-later](LICENSE) 发布。本程序按“现状”提供，不附带任何明示或默示担保。第三方组件继续受各自许可证约束。

当前源码仓库：<https://github.com/C-Q-D/agent-workspace>

## 本地开发

```powershell
cargo run -p paneflow-app
cargo test -p paneflow-app
```

内部 `paneflow-*` crate 名用于保留上游可追溯性，不代表公开产品仍使用 Paneflow 身份。架构与仓库约定见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [AGENTS.md](AGENTS.md)。
