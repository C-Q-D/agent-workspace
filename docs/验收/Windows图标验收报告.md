# AgentWorkspace Windows 图标验收报告

## 结论

UNIT-27 独立 Windows 图标验收通过。AgentWorkspace 已使用独立的四窗格终端图标，Release 可执行文件、Windows 窗口、运行时内嵌 PNG 和 WiX 安装器引用保持一致，不再复用 Paneflow 图标。

## 验收对象

- 验收时间：2026-07-19 17:55（Asia/Shanghai）
- 分支：`experiment/e01-pty-decoupling`
- Release 程序：`target/icon-atom/release/agent-workspace.exe`
- Release 大小：73,426,944 字节
- Release SHA-256：`8b22f61fd6096e56162ad1d73ac8deb0885d414036e50fb28521777058d6e351`
- 主 ICO 与 WiX ICO SHA-256：`6b41cb0bf32decc2c4eb5cbad2059529aa25f846a3c976fe4d119832a158d433`
- 原始数据：`Windows图标数据/Release-20260719-175034/运行结果.json`

## 自动验收结果

| 检查项 | 结果 | 证据 |
| --- | --- | --- |
| ICO 尺寸层级 | 通过 | 包含 16、20、24、32、40、48、64、128、256px |
| 主 ICO 与 WiX ICO | 通过 | 两个文件 SHA-256 完全一致 |
| Release PE 关联图标 | 通过 | Windows Shell 提取 32×32 图标；与同尺寸源图平均通道差 0.0327 |
| 系统通用图标对照 | 通过 | 与 `where.exe` 图标平均通道差 91.7834，排除通用图标误判 |
| 真实窗口图标 | 通过 | 从真实 HWND 读取 16×16 图标；与同尺寸源图平均通道差 0.0576 |
| 真实 Release 启动 | 通过 | 应用主窗口成功出现，启动 Splash 显示 AgentWorkspace |

Windows 图标提取后存在极少量像素差异，来自 Windows 图标句柄转位图时的透明边缘转换；差值显著低于验收阈值 2.0，且图形轮廓、颜色和尺寸帧与源图一致。

## 实际视觉证据

- [真实 Release 启动窗口](Windows图标数据/Release-20260719-175034/真实AgentWorkspace窗口.png)
- [从 Release PE 提取的关联图标](Windows图标数据/Release-20260719-175034/PE关联图标.png)
- [从真实窗口句柄提取的图标](Windows图标数据/Release-20260719-175034/真实窗口图标.png)
- [系统普通程序对照图标](Windows图标数据/Release-20260719-175034/系统通用程序图标.png)

## 缺陷与根因记录

1. 首次验收把 HWND 返回的 16px 图标与 32px 基准缩放后比较，平均差值为 18.2119。根因是不同缩放插值核造成假失败；改为按实际返回尺寸选择同尺寸源帧后，逐像素结果吻合。
2. 首次窗口截图被其他前台窗口覆盖。根因是截图前没有将目标 HWND 置顶并切到前台；补充窗口定位与前台激活后，截图稳定来自 AgentWorkspace。
3. 有效截图发现启动 Splash 仍硬编码为 Paneflow。根因是动画将旧名称拆成 8 个字符常量，未被此前的连续字符串扫描覆盖；现已改为 AgentWorkspace，并增加拼接结果与统一产品名相等的单元测试。

## 复现方式

```powershell
./scripts/运行Windows图标验收.ps1
```

已有最新隔离 Release 产物时，可以只重复系统图标与真实窗口检查：

```powershell
./scripts/运行Windows图标验收.ps1 -SkipBuild
```

脚本使用真实 Release 程序、Windows Shell API 和真实 HWND，不使用 Mock 数据。
