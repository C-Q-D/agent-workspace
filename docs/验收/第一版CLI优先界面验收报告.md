# 第一版 CLI 优先公开界面验收报告

## 结论

UNIT-18 验收通过。第一版公开界面只显示 CLI、Review 和设置；旧会话保存的
`mode: agents` 会在构造应用前回退到 CLI，历史 `Ctrl+Shift+A` 不能重新进入
隐藏界面。CLI/Review 运行期间没有发现 Agents 专属子进程，真实 PowerShell
后台输出连续，所有测试启动均正常关闭且零残留。

## 验收对象

- 测试代码提交：`2d9eca5b7f61b391f105cbb4ae1fed230a883c49`。
- Release SHA-256：`ECA985E4B65632F017CB894F4EA5CA1C392CF44AF0AF7D36A3AB45E8E4EF2A91`。
- 平台：Windows，真实 GPUI 主窗口、PowerShell、ConPTY 和本地 Git 仓库。
- 有效证据目录：`docs/验收/CLI优先界面数据/真实CLI优先界面-20260719-002906/`。

## 真实场景

1. 首次启动真实 Release 应用，生成当前 schema 的会话文件并正常关闭。
2. 只把真实会话的顶层 `mode` 改为 `agents`，再次启动并截图，正常关闭后检查写回模式。
3. 第三次启动后放大真实工作区，发送 `Ctrl+Shift+A`，截图并再次检查关闭时模式。
4. 第四次启动真实 PowerShell 循环输出，进入 Review 查看真实未提交改动，再点击 CLI 返回。
5. 采样完整进程树、应用 CPU、工作集和私有内存，最后检查全部后代进程残留。

## 结果

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 旧 Agents 会话回退 | 通过 | 写入 `agents`，关闭后为 `cli` |
| 历史快捷键不可进入 | 通过 | `Ctrl+Shift+A` 后关闭模式仍为 `cli` |
| 公开导航 | 通过 | 四张截图均只有 CLI、Review、设置 |
| Review 可用 | 通过 | `CLI_FIRST.txt` 的真实 `+1` 改动正确显示 |
| 返回 CLI | 通过 | 点击 CLI 后截图为终端，关闭模式为 `cli` |
| 后台终端连续 | 通过 | `OutputGeneration = 43`，观察到 `CLI_FIRST_TICK_` |
| Agents 专属进程 | 通过 | 空集合 |
| 进程树 | 通过 | 仅 `paneflow`、`pwsh`、`conhost` |
| 关闭残留 | 通过 | 三个验收阶段的剩余 PID 均为空 |

## 资源短测

- 应用平均 CPU：`0.2313%`，按逻辑处理器数量归一化。
- 应用工作集峰值：`149.641 MiB`。
- 应用私有内存峰值：`119.039 MiB`。

该数据是一个真实终端和一次 CLI/Review 往返的 8 秒短测，只用于证明 UNIT-18
没有引入明显退化。1、9、16 窗口以及 30 分钟长稳门禁归 UNIT-20，不在本报告中
提前作结论。

## 截图复核

- `旧Agents会话回退-CLI.png`：启动后直接显示终端矩阵，CLI 高亮，无 Agents 导航。
- `快捷键后-仍为CLI.png`：放大工作区并发送历史快捷键后仍是 CLI，右侧文件栏正常。
- `Review.png`：左侧工作区列表保留，中间真实 Diff、右侧 Changes 正常。
- `返回CLI.png`：点击 CLI 后恢复终端，后台输出持续增长。

终端截图包含用户 PowerShell profile 中缺少 `oh-my-posh` 的启动错误；该信息由真实
PowerShell 环境产生，与本单元的模式导航和后台资源行为无关，不影响验收结论。

## 自动化说明

验收脚本为 `scripts/运行WindowsCLI优先界面验收.ps1`。脚本会暂存并恢复用户配置和
会话，创建后删除真实临时 Git 仓库，并在异常路径上关闭应用及清理临时状态。
