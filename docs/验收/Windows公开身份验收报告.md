# AgentWorkspace Windows 公开身份验收报告

## 验收结论

通过。最新 Release 产物、顶层 CLI、MCP/Hook 子命令、Windows AUMID、WiX 安装器身份和公开仓库链接已经统一为 AgentWorkspace；隔离构建目录中不存在旧的 `paneflow.exe` 主程序。

## 验收范围

- Release 主程序：`agent-workspace.exe`。
- 顶层帮助、版本与未知命令错误。
- `agent-workspace mcp` 和 `agent-workspace hooks` 公开帮助。
- Windows AUMID：`CQD.AgentWorkspace`。
- WiX 产品名、快捷方式目标和安装主程序名。
- 开源仓库与最新 Release API。
- 旧主程序名排除。

内部 crate 名、`PANEFLOW_*` 兼容环境变量、`paneflow-mcp.exe`、`paneflow-ai-hook.exe` 和 `_paneflow_managed` 标记不属于公开主程序身份，按兼容约束保留。

## 验收方法

运行 `scripts/运行Windows公开身份验收.ps1`。脚本执行以下真实检查：

1. 在 `target/identity-atom` 隔离目标目录构建最新 Release 主程序。
2. 确认 `agent-workspace.exe` 存在，且同目录不存在 `paneflow.exe`。
3. 运行 Release 程序的 `--help`、`--version`、未知命令、`mcp` 和 `hooks` 命令，检查输出与退出码。
4. 检查 Windows 身份源码和 WiX 清单中的 AUMID、产品名、快捷方式目标与主程序名。
5. 检查帮助仓库地址和默认更新 API 均指向 `C-Q-D/agent-workspace`。
6. 记录程序大小、SHA-256、原始输出和机器可读 JSON。

## 本次结果

- 执行时间：2026-07-19 17:18（Asia/Shanghai）。
- Release 主程序：`agent-workspace.exe`，73,209,344 字节。
- SHA-256：`5e820067d27155168c94a57689a182f6dc05ee432f41dcf94605f81dfa97d2f3`。
- `--help`：退出码 0，显示 AgentWorkspace、`agent-workspace` 和新仓库地址。
- `--version`：退出码 0，输出 `agent-workspace 0.7.11`。
- 未知命令：退出码 2，错误提示和帮助命令均使用 `agent-workspace`。
- MCP 帮助：退出码 2，公开服务名为 AgentWorkspace。
- Hook 帮助：退出码 2，公开产品名为 AgentWorkspace。
- Windows AUMID 与 WiX 快捷方式：均为 `CQD.AgentWorkspace`。
- WiX 产品名：`AgentWorkspace`；主程序：`agent-workspace.exe`。
- 公开仓库：`https://github.com/C-Q-D/agent-workspace`。
- 最新 Release API：`https://api.github.com/repos/C-Q-D/agent-workspace/releases/latest`。
- 旧主程序 `paneflow.exe`：不存在。

机器可读结果和原始输出位于 `docs/验收/Windows公开身份数据/Release-20260719-171828/`。

## 重复验收

在仓库根目录运行：

```powershell
.\scripts\运行Windows公开身份验收.ps1
```

如果确认隔离目标目录已经包含当前提交构建的 Release 程序，只想重复检查公开身份，可运行：

```powershell
.\scripts\运行Windows公开身份验收.ps1 -SkipBuild
```

任一程序输出、退出码、AUMID、WiX 身份或公开链接不符合约定时，脚本都会立即失败，并保留当次原始输出供根因分析。
