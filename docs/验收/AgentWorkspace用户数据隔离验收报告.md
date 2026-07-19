# AgentWorkspace 用户数据隔离验收报告

## 验收结论

通过。AgentWorkspace 的调试版和发布版均能在真实文件系统中独立创建、写入并读回配置、会话和缓存数据；测试预先布置的 Paneflow 旧数据哨兵没有被修改、迁移或删除。

## 验收范围

- 调试版数据根：`%USERPROFILE%\.agent-workspace-dev`。
- 发布版数据根：`%USERPROFILE%\.agent-workspace`。
- 配置文件：`config/settings.json`。
- 会话文件：`sessions/workspaces.json`。
- 缓存目录：`cache/`。
- 旧数据边界：模拟 Windows `AppData/Roaming` 与 `AppData/Local` 下的 `paneflow`、`paneflow-dev` 四个目录。

## 验收方法

运行 `scripts/运行Windows用户数据隔离验收.ps1`。脚本分别以 debug 和 release 构建执行同一个真实文件系统测试：

1. 创建临时用户主目录和四个 Paneflow 旧数据哨兵目录。
2. 通过产品路径函数解析 AgentWorkspace 配置、会话和缓存位置。
3. 创建父目录，写入真实字节，再从磁盘读回并逐项比对。
4. 检查四个旧目录仍只含原哨兵文件，且文件内容保持不变。
5. 保存 debug、release 原始输出和机器可读结果。

临时主目录由 Rust `TempDir` 创建并在测试结束后自动回收，不会写入当前用户真实的 `.agent-workspace` 或 Paneflow 数据目录。

## 本次结果

- 执行时间：2026-07-19 16:29（Asia/Shanghai）。
- debug：1 项通过，0 项失败，实际根目录末级为 `.agent-workspace-dev`。
- release：1 项通过，0 项失败，实际根目录末级为 `.agent-workspace`。
- Paneflow 旧目录：每种构建均检查 4 个哨兵目录，全部保持不变。
- 机器可读结果：`docs/验收/用户数据隔离数据/真实隔离-20260719-162937/运行结果.json`。
- 原始日志：同目录下的 `debug.txt` 与 `release.txt`。

## 重复验收

在仓库根目录运行：

```powershell
.\scripts\运行Windows用户数据隔离验收.ps1
```

脚本任一构建测试失败时会返回失败，并在错误中给出对应日志路径；只有 debug 与 release 都通过时才会写出 `result: passed`。
