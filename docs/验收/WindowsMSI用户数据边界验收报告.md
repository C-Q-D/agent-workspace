# Windows MSI 用户数据边界验收报告

## 结论

ATOM-36-02 于 2026-07-19 验收通过。真实 Windows 11 x64 环境完成 AgentWorkspace 0.7.10 初装、0.7.11 MajorUpgrade 和 0.7.11 卸载，三个 `msiexec` 事务退出码均为 0。升级与卸载前后，`.agent-workspace` 的设置、会话、状态和稳定辅助文件等 10 类数据指纹全部不变；卸载只清除了应用资源，没有删除用户目录、旧 Paneflow 数据、无关用户文件或外部项目。

可复核的精简机器结果见 [运行结果](Windows用户数据边界数据/MSI-20260719-200357/运行结果.json)。28 MB 测试 MSI 和完整 Windows Installer 日志只保留在本机忽略的 `target/` 验收目录，不进入 Git 历史。

## 原子目标

本原子验证安装器生命周期的删除边界，不重复验证应用运行时的数据选址。Release 应用真实启动与 `.agent-workspace` 写入归位已由 ATOM-36-01 完成；本原子预置稳定字节内容，通过升级与卸载逐阶段检查文件是否存在且 SHA-256 不变。

## 真实生命周期

| 阶段 | 真实结果 | 结果 |
| --- | --- | --- |
| 准备 | WiX 3.14 生成 0.7.10 与 0.7.11 MSI；UpgradeCode 相同，ProductCode 不同 | 通过 |
| 初装 | 0.7.10 注册成功；程序、法律材料、开始菜单和系统 PATH 存在；已安装 EXE 探针退出 0 | 通过 |
| 覆盖升级 | `FindRelatedProducts` 与 `RemoveExistingProducts` 完成；系统只保留一个 0.7.11 产品 | 通过 |
| 升级边界 | 10 个分类哨兵存在且摘要不变 | 通过 |
| 卸载 | 0.7.11 删除成功；程序目录、开始菜单、卸载注册项和系统 PATH 条目消失 | 通过 |
| 卸载边界 | 10 个分类哨兵仍存在且摘要不变；应用进程和产品注册残留均为 0 | 通过 |

两个测试 MSI 使用相同的当前 Release 主程序，只改变 Windows Installer 的 ProductVersion 和 ProductCode，以单变量验证 MajorUpgrade。因此低版本包中的 EXE 输出 `agent-workspace 0.7.11` 属于预期。

## 数据分类

| 分类 | 生命周期 | 位置含义 | 升级后 | 卸载后 |
| --- | --- | --- | --- | --- |
| `data-root` | durable | `.agent-workspace` 根目录用户数据 | 保留 | 保留 |
| `config` | durable | 用户设置 | 保留 | 保留 |
| `sessions` | durable | 工作区与会话索引 | 保留 | 保留 |
| `state` | durable | 窗口布局等运行状态 | 保留 | 保留 |
| `bin` | durable | 稳定辅助程序与资产 | 保留 | 保留 |
| `cache` | rebuildable | 可重建缓存 | 保留 | 保留 |
| `logs` | diagnostic | 诊断日志 | 保留 | 保留 |
| `legacy-paneflow` | legacy | 旧产品目录 | 保留 | 保留 |
| `unrelated-user-file` | external | 无关用户文件 | 保留 | 保留 |
| `external-project` | external | 用户 Git 项目 | 保留 | 保留 |

`cache` 虽允许应用按自身策略重建，安装器仍不应在升级或卸载时越权清理，因此本次也要求其字节不变。

## 回归结果

| 检查 | 结果 |
| --- | --- |
| PowerShell 语法解析 | 通过 |
| `git diff --check` | 通过 |
| Windows MSI 更新模块测试 | 15/15 通过 |
| 真实 MSI 初装、升级、卸载 | 全部通过 |

## 实现影响

本原子只增强 `scripts/运行WindowsMSI生命周期验收.ps1` 的分类哨兵和结果结构，没有修改 MSI 产品定义、卸载规则或应用运行时代码。结果结构升级为 schema version 2，失败信息会直接标出受损的数据分类。
