# AgentWorkspace 代码仓库开发规则

## 1. 规则优先级与恢复入口

本仓库是 AgentWorkspace 的自研代码仓库。执行任务时按以下顺序恢复事实：

1. 用户当前明确要求。
2. 本文件。
3. 绝对计划文档
   `F:\workspace\projects\AgentWorkspaceLab\agent-workspace\docs\ai-project\v1完整代码原子任务方案.md`。
4. 外层项目工作台
   `F:\workspace\projects\AgentWorkspaceLab\agent-workspace\docs\ai-project\项目工作台.md`。
5. 仓库内事实审查 `docs/当前仓库事实审查.md`。
6. 当前源码、测试、Git 和构建产物。

发生冲突时，以可重复验证的源码、测试和 Git 事实为准，并在当前原子边界内修正文档。
`README.md`、`ARCHITECTURE.md` 和部分 `.github/` 文件仍包含上游产品说明，在 A077
及后续公开资料原子完成前不能作为当前开发范围的事实源。

每次上下文恢复或压缩后，必须重新读取计划文档、项目工作台、本文件和当前原子卡，
不得仅凭对话记忆继续。

## 2. 仓库与同步边界

- 代码仓库根目录：
  `F:\workspace\projects\AgentWorkspaceLab\agent-workspace\app`。
- 自研远端：`git@github.com:C-Q-D/agent-workspace.git`，通常命名为 `origin`。
- 每次开始原子前都要实际检查当前分支、upstream、工作树和 remote，不得假设它们未变化。
- 当前分支存在 upstream 时，每个原子验证并独立提交后立即推送该 upstream。
- 没有 upstream 时优先推送 `origin` 并为当前分支建立 upstream；远端不唯一时停止选择，
  不得猜测。
- 禁止强制推送、覆盖用户修改、自动 amend 旧提交或把多个原子合并为一次提交。
- `F:\workspace\projects\AgentWorkspaceLab\paneflow` 和其他样本仓库只读，禁止修改、
  提交、建分支或推送。
- 不得向 Paneflow 或其他上游远端推送 AgentWorkspace 修改，也不得自动创建上游 PR。
- 需要读取上游实现时只做证据对照；产品实现、测试、脚本和公开资料必须留在本仓库。

当前自研仓库基于 Paneflow v0.7.11 / `040f71a` 的历史建立，并采用兼容
GPL-3.0-or-later 的开源分发方式。保留上游版权、许可证和修改声明，不得把法律归属中的
Paneflow 名称当作需要清除的品牌残留。

## 3. 产品与平台边界

- v1 是面向 Windows 用户的开源原生桌面应用。
- 核心是多个真实 Windows ConPTY/PowerShell 终端组成的动态 N×N 工作区。
- 每个窗口绑定稳定 `workspaceRoot`；终端内临时 `cd` 不改变文件、引用和 Git 审查边界。
- 总览态不加载文件/Git ActiveContext；只有聚焦态按需加载当前窗口上下文。
- Codex CLI、Claude Code CLI 和未知 CLI 继续作为真实终端程序运行，应用不重新实现聊天。
- v1 不开发或承诺 macOS、Linux、WSL、SSH、LSP、AI 聊天、Agent 自动编排或 Git 自动写操作。
- Windows 最低正式支持版本要到 A118～A120 依据真实验收确定；在此之前不要新增未经验证的
  Windows 版本承诺。
- 继承源码中的 macOS/Linux 分支可以暂留，但跨平台兼容不是 Windows v1 原子的退出条件，
  不得因此扩大任务或阻塞 Windows 核心交付。
- 修改共享代码时避免无理由破坏现有 `cfg` 分支；若为了 Windows v1 必须改变通用边界，
  要在原子计划和验证限制中明确记录。

## 4. 用户数据与工作区边界

用户数据路径以 `crates/paneflow-config/src/data_layout.rs` 为代码事实源：

- Release 根目录：`%USERPROFILE%\.agent-workspace`。
- Debug 根目录：`%USERPROFILE%\.agent-workspace-dev`。
- 主设置：`<数据根>\config\settings.json`。
- 工作区会话：`<数据根>\sessions\workspaces.json`。
- 内部状态、稳定二进制、可重建缓存和日志分别位于 `state\`、`bin\`、`cache\`、`logs\`。

禁止把用户数据重新写回 Paneflow 旧目录、进程当前目录或项目 `workspaceRoot`。用户项目、
Git 仓库、worktree 和 Codex/Claude 自有配置不属于 AgentWorkspace 用户数据目录。

如果文档、注释或测试 fixture 仍使用 `paneflow.json` 等旧名称，先判断它是运行时路径、
兼容输入还是纯遗留文字；只有当前原子允许且具备迁移/恢复证据时才能修改。

## 5. 连续原子开发协议

当前 Windows v1 使用连续执行模式，唯一原子计划为 A001～A142，其中：

- A001～A108 可以在用户不在线时连续执行。
- A109 是第一个人工策略门；未获得明确决定前不得进入或提前发布。
- 每个原子必须保持一个行为目标、一个变更原因和一个可独立回退的提交。
- 本原子完成验证、差异审查、提交和推送前，不得开始下一原子。
- 每完成 3 个原子以及每个阶段边界，更新外层项目工作台和阶段记录，并向用户同步：
  原子 ID、提交 SHA、测试、远端结果、阻塞和下一原子。

每个原子的固定顺序：

1. 读取计划文档、当前原子卡、相关事实和当前 Git 状态。
2. 用不超过 10 行说明唯一目标、允许修改、禁止修改和验证方法。
3. 先建立失败测试、特征测试或可重复的旧行为证据。
4. 只做完成当前行为所需的最小实现。
5. 先运行最窄测试，再运行受影响回归和必要的真实 Windows 路径。
6. 失败时先形成根因证据；根因未确定前禁止试改、放宽断言或增加任意等待。
7. 检查完整 diff，确认没有用户修改、调试残留和无关格式化。
8. 只暂存当前原子文件或代码块，创建独立中文提交并推送当前 upstream。
9. 记录命令、结果、证据、SHA 和下一原子。

发现两个独立行为、两个不同根因或需要跨多个无共同所有权模块时，继续拆成
`Axxx-S01`/`Axxx-S02` 或 `Axxx-F01`/`Axxx-F02`，不得扩大为大提交。

## 6. 项目结构

- `src-app/`：GPUI 桌面主程序、CLI、终端、窗口、设置、文件、Git Review 与更新边界。
- `crates/paneflow-config/`：配置 schema、用户数据布局、加载和 watcher。
- `crates/paneflow-*`：继承的 IPC、进程、Telemetry、ACP、shim、AI hook、MCP 等 crate；
  是否进入 Windows v1 默认构建必须依据 A010～A040 审查，不得仅凭目录名删除。
- `scripts/`：Windows 真实验收、打包和确定性检查脚本。
- `packaging/wix/`：Windows MSI。
- `packaging/windows/`：Windows 便携包说明和发行资料。
- `docs/`：可随代码仓库追踪的架构、用户、发行、法律和验收证据。
- `.github/`：社区入口和 CI/Release；在 A073～A108 前仍可能包含上游跨平台配置。

不要把外层实验管理资料复制成多份公开事实源。需要公开交付的文档和测试工具必须进入
本仓库；外层 `agent-workspace/docs/ai-project/` 只保存领航工作台、阶段记录和完整计划。

## 7. 构建与测试

所有命令默认从仓库根目录执行。当前基础命令：

```powershell
cargo build -p paneflow-app
cargo build --release -p paneflow-app
cargo run -p paneflow-app

cargo test -p paneflow-config
cargo test -p paneflow-app
cargo test -p paneflow-app --test flex_nchild

cargo fmt --all -- --check
```

2026-07-25 的 A009 可重复基线为：

- `paneflow-config`：113 passed。
- `paneflow-app` unit：1461 passed。
- `flex_nchild`：5 passed。

该数字只代表基线，不是永久成功标准。每次记录测试结果必须使用当前命令输出，不能复制旧计数。

修改 Rust 代码时，每次 commit 和 push 前必须运行：

```powershell
cargo fmt --all -- --check
```

到 A094 固化 Clippy 范围后，所有后续代码原子还必须通过带 `-D warnings` 的正式门禁；
在 A094 前不允许用全局 `allow(warnings)` 伪造零警告。

真实 Windows 验收优先复用 `scripts/` 中现有中文脚本。单元测试可以使用临时目录和确定性
fixture 验证错误路径，但 ConPTY、真实 Git、GUI、安装包和 CLI 闭环不能用 mock 替代。

## 8. 代码与文档规范

- 新增或实质修改的代码必须使用中文文件级、类型级、字段级、方法级和关键逻辑注释。
- 注释说明职责、设计意图、边界、异常、性能和技术取舍，不得逐字复述代码。
- 修改实现时同步修正失效注释；中文 `TODO`/`FIXME` 必须说明原因、限制和后续目标。
- Rust 遵循 `rustfmt`，文件和模块用 `snake_case`，类型用 `UpperCamelCase`。
- 优先深化现有模块，不创建未使用接口、空壳类、平行 manager 或第二份状态事实源。
- 不使用高频轮询检测终端、Git 或文件变化；优先使用事件、watcher、进程回调和显式刷新。
- 不解析 CLI 文本猜测模型是否思考、等待或完成。
- 新建文档使用中文文件名；README、AGENTS、LICENSE、CONTRIBUTING 等约定文件名除外。
- 公开资料的产品声明必须有源码、测试或真实 Windows 证据，禁止把计划写成已支持。

## 9. 工作树与失败处理

- 原子开始前工作树不干净时，先识别用户已有修改并保护它们。
- 与当前原子不重叠的用户修改保持原样，不整理、不格式化、不提交。
- 与当前原子重叠且无法安全分离时停止，说明文件和冲突，不得覆盖。
- 测试失败先建立最小复现，确定第一次偏离和根因所属边界，再计划修复。
- 远端 push 失败时保留本地提交并合理重试；持续失败则停止，不得积压后续原子。
- 禁止 `git reset --hard`、强制 push、删除用户数据、手工修改验收结果或重跑碰运气。

## 10. 当前状态入口

当前可验证仓库事实见：

- `docs/当前仓库事实审查.md`
- 外层 `docs/ai-project/项目工作台.md`
- 外层 `docs/ai-project/项目阶段记录.md`
- 外层 `docs/ai-project/v1完整代码原子任务方案.md`

每个入口职责不同：

- 本文件：有效开发规则。
- 当前仓库事实审查：A001 时点的证据基线。
- 项目工作台：当前停点和跨上下文恢复。
- 项目阶段记录：标准路线阶段与历史。
- v1 原子任务方案：A001～A142 的唯一执行顺序和完成标准。

当前检查点：A001～A009 已完成；最近三个原子为 A007 `2fe6376`、A008 `b62f7bb` 和
A009（使用 `git log -1 -- docs/当前开发状态.md` 定位本检查点提交）。A008/A009 的门禁
修复提交为 `ef115cd`、`1a130f5`、`c62ce8c`、`0572c6d`、`fc0b53d`、`7d31957`、
`97f3523`。UNIT-40 ATOM-40-04 与 P2-05 已关闭；下一原子为 A010。
