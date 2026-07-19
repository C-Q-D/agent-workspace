# UNIT-32 Windows 便携包验收报告

## 结论

UNIT-32 于 2026-07-19 验收通过。AgentWorkspace 已能仅使用 PowerShell 与 .NET 标准库，从真实 Windows x64 Release 载荷生成确定性便携 ZIP 和 SHA-256 sidecar。相同输入由两个独立 PowerShell 进程连续生成的 ZIP 字节完全一致；真实解压后的 25 个文件逐项与 ZIP 哈希一致；隔离用户环境中的真实主程序输出 `agent-workspace 0.7.11` 并以退出码 0 结束。

便携版不修改系统 PATH、不创建开始菜单或安装注册项，也不启用专用数据模式。用户数据规则仍为 `%USERPROFILE%\.agent-workspace`；本次真实运行没有在解压目录创建 `.agent-workspace`，也没有改变开发者现有用户数据指纹。

机器可复核结果见 [Windows 便携包数据](Windows便携包数据/Release-20260719-190609/运行结果.json)。

## 便携产物

| 项目 | 实际值 |
| --- | --- |
| ZIP | `agent-workspace-0.7.11-windows-x64.zip` |
| 大小 | 30,943,990 字节 |
| SHA-256 | `2852a3c88dca9d92c09ef1b739f42e11c8e05746cef17cda8423a6a60c09b731` |
| ZIP 根目录 | `AgentWorkspace-0.7.11-windows-x64` |
| 条目数量 | 25 |
| 生成依赖 | PowerShell 7 与 .NET 标准库；不调用 Cargo、WiX 或安装器 |

载荷包括：

- 真实 `agent-workspace.exe` 主程序。
- `bin/` 下 17 个 CLI helper，其中包括 Codex、Claude Code、OpenCode 与 AI hook。
- 中文《便携版说明》与 GPL `License.rtf`。
- `licenses/` 下 `LICENSE.txt`、`UPSTREAM-NOTICE.md`、`THIRD-PARTY-RUST.md/json` 和 `THIRD-PARTY-ASSETS.md`。

## 确定性与失败门禁

| 场景 | 结果 |
| --- | --- |
| 两个独立进程连续生成 | ZIP 长度、SHA-256 和全部字节一致 |
| ZIP 条目元数据 | 顺序固定，DOS 时间固定为 1980-01-01 00:00:00 |
| 路径边界 | 无绝对路径、反斜杠、父目录越界或开发目录泄漏 |
| 非法版本 `0.7` | 生成器拒绝 |
| 空 helper 目录 | 生成器在写包前拒绝 |
| 真实 EXE 副本追加单字节 | 新 ZIP 哈希变化，输入漂移被识别 |
| SHA-256 sidecar | 文件名和实际 ZIP 哈希一致 |

## 真实解压与运行

1. 在全新目录使用 .NET ZIP 解压器解压产物。
2. 回读 ZIP 内全部 25 个条目，逐项比较解压文件长度与 SHA-256。
3. 验证主程序、17 个 helper、五份法律材料、GPL RTF 和中文便携说明均存在。
4. 把 `USERPROFILE` 与 `HOME` 指向隔离目录，从解压根目录真实执行 `agent-workspace.exe --version`。
5. 真实进程返回 0，标准输出为 `agent-workspace 0.7.11`，退出后 AgentWorkspace 进程残留为 0。
6. 解压目录没有生成 `.agent-workspace`；开发者原有 `%USERPROFILE%\.agent-workspace` 前后目录/文件指纹一致。

## 总回归

| 测试 | 结果 |
| --- | --- |
| 上游归属声明门禁 | 通过 |
| 第三方许可证只读门禁 | 通过；1109 个 Rust 包、36 个字体、0 个未澄清项 |
| 第三方许可证失败门禁测试 | 4/4 通过 |
| Windows 法律材料测试 | 4/4 通过 |
| `cargo test -p paneflow-app --locked` | 1426 个主程序测试与 5 个布局集成测试全部通过 |
| `cargo test -p paneflow-mcp-install --locked` | 97 个测试全部通过 |

## 根因诊断记录

1. 第一次固定时间戳检查把 ZIP 回读的 `DateTimeOffset` 与 UTC 瞬时值直接比较而失败。检查确认传统 ZIP DOS 时间不保存时区，本机回读会附加 `+08:00`，但存储的墙上时间始终是 1980-01-01 00:00:00；验收改为比较实际存储的日期时间字段，打包器无需修改。
2. 第一次逐字节重复构建测试尝试按 C# 写法调用 `byte[].AsSpan()`。PowerShell 不把该扩展方法作为数组实例方法暴露，并对数组执行了成员枚举；改用结构化字节数组比较后，完整正负场景重跑通过。

## 原子提交

- `ff94b17`：建立显式便携载荷清单、中文说明和确定性 ZIP 生成器。
- `8af6642`：建立两次重复构建、条目元数据与真实输入漂移门禁。
- 本报告所在提交：执行真实解压运行、数据边界与完整回归并保存机器证据。

所有原子提交均同步到 `origin/experiment/e01-pty-decoupling`。
