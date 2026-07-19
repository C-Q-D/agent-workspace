# UNIT-31 Windows MSI 生命周期验收报告

## 结论

UNIT-31 于 2026-07-19 验收通过。真实 Windows 11 x64 环境完成了 AgentWorkspace 0.7.10 初装、0.7.11 MajorUpgrade 和 0.7.11 卸载闭环。安装、升级和卸载的 `msiexec` 退出码均为 0；升级后系统只保留一个 0.7.11 产品；卸载后程序目录、开始菜单、卸载注册项和系统 PATH 条目均已移除。外部项目文件与隔离用户目录下的 `.agent-workspace` 哨兵在升级和卸载后字节不变。

机器可复核结果见 [Windows MSI 生命周期数据](WindowsMSI生命周期数据/Release-20260719-185519/运行结果.json)。

## 验收环境

| 项目 | 实际值 |
| --- | --- |
| 操作系统 | Microsoft Windows 11 专业版，10.0.26200，64 位 |
| PowerShell | 7.6.3 |
| WiX | 3.14.1.8722 |
| cargo-wix | 0.3.9 |
| 安装范围 | per-machine，`C:\Program Files\AgentWorkspace` |
| 生命周期脚本 | `scripts/运行WindowsMSI生命周期验收.ps1` |

## MSI 身份与内容

| 产物 | ProductVersion | ProductCode | UpgradeCode | 大小 | SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| 低版本测试包 | 0.7.10 | `{C795E1C4-574A-40FB-A93A-08BED0E1CB93}` | `{7D0C2220-1B4E-4E86-9D5E-AC3479C95B23}` | 28,028,928 | `5827cbbf...4310a` |
| 当前版本包 | 0.7.11 | `{8DB0BE44-8087-4D22-88E7-F583FAB6ECAD}` | `{7D0C2220-1B4E-4E86-9D5E-AC3479C95B23}` | 28,028,928 | `de9856ae...dd2c` |

两个 MSI 使用同一真实 0.7.11 Release 载荷，只改变 Windows Installer 的 ProductVersion 和 ProductCode，以单变量验证 MajorUpgrade。因而 0.7.10 包安装后的真实 EXE 输出 `agent-workspace 0.7.11` 属于预期，不表示安装器版本替换失败。两个包都包含真实主程序和五份法律材料。

## 真实生命周期结果

| 阶段 | 可观察结果 | 结果 |
| --- | --- | --- |
| 安装前 | 管理员权限；无既有 AgentWorkspace 注册项；无既有安装目录 | 通过 |
| 0.7.10 初装 | `msiexec /i` 返回 0；注册表为 0.7.10；主程序、法律材料、开始菜单与系统 PATH 存在 | 通过 |
| 已安装程序探针 | 隔离 `USERPROFILE` 执行 `agent-workspace.exe --version`，退出码 0 | 通过 |
| 0.7.11 覆盖升级 | `FindRelatedProducts` 与 `RemoveExistingProducts` 执行；旧 ProductCode 被替换；系统只有一个 0.7.11 产品 | 通过 |
| 升级数据边界 | 项目哨兵与 `.agent-workspace` 哨兵 SHA-256 不变 | 通过 |
| 0.7.11 卸载 | `msiexec /x` 返回 0；日志记录 `Removal completed successfully` | 通过 |
| 卸载清理 | 安装目录、开始菜单、卸载注册项与系统 PATH 条目均不存在；进程残留为 0 | 通过 |
| 卸载数据边界 | 项目哨兵与 `.agent-workspace` 哨兵仍存在且 SHA-256 不变 | 通过 |

项目哨兵 SHA-256 为 `0fa586a90125be8ea707a04e2644668a8e9ab3f6eac4d09a81c7516a7883ee13`；用户数据哨兵 SHA-256 为 `8e2a93eadcf2da8511aa0e93775c0a9663d92bdca73bff394ed924a0a27d270a`。

## 总回归

| 测试 | 结果 |
| --- | --- |
| 上游归属声明门禁 | 通过；基线、首个派生提交、许可证 Blob 与公开元数据一致 |
| 第三方许可证只读门禁 | 通过；1109 个 Rust 包、36 个字体、0 个未澄清项 |
| 第三方许可证失败门禁测试 | 4/4 通过 |
| Windows 法律材料测试 | 4/4 通过 |
| `cargo test -p paneflow-app --locked` | 1426 个主程序测试与 5 个布局集成测试全部通过 |
| `cargo test -p paneflow-mcp-install --locked` | 97 个测试全部通过 |

## 根因诊断记录

1. PowerShell 7 不能直接绑定 Windows Installer 的 `OpenDatabase` 自动化方法。确认 COM 对象通过 `IDispatch` 暴露后，改为显式 `InvokeMember`，真实读取 Property 和 File 表通过。
2. `cargo wix --install-version` 的输出文件名跟随安装版本，而不是始终使用 Cargo 包版本。脚本改为在每次构建后定位对应版本文件并复制到固定生命周期目录。
3. 第一次升级验收在 ProductCode 比较处失败。注册表、已安装 EXE 和 MSI 日志都证明 MajorUpgrade 已成功；根因是期望值去掉了 GUID 花括号，而注册表值保留花括号。比较两侧统一规范化后，清理失败运行的测试安装并完整重跑，安装、升级和卸载闭环通过。

## 原子提交

- `38f0b49`：建立 MSI 生命周期前置验收与两个版本测试包。
- `e753034`：执行真实初装与覆盖升级，并验证应用文件、PATH 和数据哨兵。
- 本报告所在提交：执行真实卸载、总回归并保存机器证据。

所有原子提交均同步到 `origin/experiment/e01-pty-decoupling`。
