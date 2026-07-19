<#
.SYNOPSIS
运行 AgentWorkspace CLI 优先公开界面的真实 Windows 验收。

.DESCRIPTION
脚本隔离用户状态，以真实 Release 应用和 PowerShell/ConPTY 依次验证旧 Agents
会话回退、Ctrl+Shift+A 失效、CLI/Review 往返、后台输出连续、资源占用和关闭零残留。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(3, 60)]
    [int]$SampleSeconds = 8,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\CLI优先界面数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实CLI优先界面-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWCliFirst-$timestamp"
$fixtureFile = Join-Path $fixtureRoot 'CLI_FIRST.txt'
$resultPath = Join-Path $runDirectory '运行结果.json'
$restoreScreenshot = Join-Path $runDirectory '旧Agents会话回退-CLI.png'
$shortcutScreenshot = Join-Path $runDirectory '快捷键后-仍为CLI.png'
$reviewScreenshot = Join-Path $runDirectory 'Review.png'
$returnScreenshot = Join-Path $runDirectory '返回CLI.png'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory, $fixtureRoot | Out-Null

function Invoke-PaneflowRpc {
    <# 通过一次一连接协议调用真实 Paneflow JSON-RPC。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][object]$Params)

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'paneflow', [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(([ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 12 -Compress))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { throw "Paneflow IPC 对 $Method 返回空响应。" }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "Paneflow IPC $Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待 GUI 命名管道就绪。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-PaneflowRpc -Method 'system.ping' -Params @{}).pong) { return }
        }
        catch {
            # 冷启动阶段命名管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存真实用户状态，保证验收不会污染日常会话。 #>
    if (Get-Process paneflow -ErrorAction SilentlyContinue) { throw '开始验收前仍存在 Paneflow 进程。' }
    $script:hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($script:hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    [ordered]@{ telemetry = [ordered]@{ enabled = $false } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $actualConfigPath -Encoding utf8
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 删除实验会话并原样恢复用户配置与会话。 #>
    if (-not $script:statePrepared) { return }
    if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) { Remove-Item -LiteralPath $actualSessionPath -Force }
    if ($script:hadSession -and (Test-Path -LiteralPath $sessionBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $sessionBackupPath -Destination $actualSessionPath -Force
    }
    if ($script:hadConfig -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $configBackupPath -Destination $actualConfigPath -Force
    }
    elseif (Test-Path -LiteralPath $actualConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $actualConfigPath -Force
    }
    $script:statePrepared = $false
}

function Initialize-FixtureRepository {
    <# 创建有真实提交和未提交改动的本地 Git 仓库供 Review 使用。 #>
    git -C $fixtureRoot init --quiet
    git -C $fixtureRoot config user.name 'AgentWorkspace CLI First Test'
    git -C $fixtureRoot config user.email 'cli-first@example.invalid'
    Set-Content -LiteralPath $fixtureFile -Encoding utf8 -Value 'baseline'
    git -C $fixtureRoot add -- 'CLI_FIRST.txt'
    git -C $fixtureRoot commit --quiet -m '建立CLI优先验收基线'
    Add-Content -LiteralPath $fixtureFile -Encoding utf8 -Value "changed-$timestamp"
    if ($LASTEXITCODE -ne 0) { throw '初始化真实 Git 仓库失败。' }
}

function Initialize-WindowAutomation {
    <# 注册真实鼠标、键盘、窗口定位和截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceCliFirstInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@
}

function Start-TestApp {
    <# 从真实仓库目录启动 Release 应用并等待 IPC 与主窗口就绪。 #>
    $process = Start-Process -FilePath $binary -WorkingDirectory $fixtureRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            [AgentWorkspaceCliFirstInput]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
            [AgentWorkspaceCliFirstInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 20, 20, 1280, 800, 0x0040) | Out-Null
            [AgentWorkspaceCliFirstInput]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 800
            return $process
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 主窗口在 15 秒内未就绪。'
}

function Get-WindowRectValue {
    <# 返回真实产品窗口的屏幕坐标。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = New-Object AgentWorkspaceCliFirstInput+RECT
    if (-not [AgentWorkspaceCliFirstInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    return $rect
}

function Save-WindowScreenshot {
    <# 只截取真实产品窗口，避免桌面其他内容污染证据。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)
    $rect = Get-WindowRectValue -Handle $Handle
    [AgentWorkspaceCliFirstInput]::SetCursorPos($rect.Left + 600, $rect.Top + 18) | Out-Null
    Start-Sleep -Milliseconds 450
    $bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Invoke-WorkspaceRowClick {
    <# 点击首个真实工作区卡片，使其进入稳定放大状态。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = Get-WindowRectValue -Handle $Handle
    [AgentWorkspaceCliFirstInput]::SetCursorPos($rect.Left + 120, $rect.Top + 104) | Out-Null
    [AgentWorkspaceCliFirstInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
}

function Invoke-CliModeClick {
    <# 点击左下角真实 CLI 模式按钮，验证 Review 可以返回公开终端界面。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = Get-WindowRectValue -Handle $Handle
    # 截图 API 之后显式恢复前台窗口；否则 Windows 可能只把第一次点击用于激活，
    # 不把它继续派发给 GPUI 元素。按钮中心需避开底部原生缩放边框。
    [AgentWorkspaceCliFirstInput]::SetForegroundWindow($Handle) | Out-Null
    [AgentWorkspaceCliFirstInput]::SetCursorPos($rect.Left + 60, $rect.Bottom - 28) | Out-Null
    Start-Sleep -Milliseconds 300
    foreach ($attempt in 1..2) {
        [AgentWorkspaceCliFirstInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [AgentWorkspaceCliFirstInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 3
}

function Invoke-Shortcut {
    <# 发送真实 Ctrl+Shift+字母组合键。 #>
    param([Parameter(Mandatory = $true)][byte]$VirtualKey)
    [AgentWorkspaceCliFirstInput]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::keybd_event($VirtualKey, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceCliFirstInput]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 3
}

function Get-ProcessTree {
    <# 返回根进程和全部后代的实时 PID、父 PID 与进程名。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($item in $all) {
        try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } } catch { $parentId = 0 }
        if (-not $children.ContainsKey($parentId)) { $children[$parentId] = [Collections.Generic.List[int]]::new() }
        $children[$parentId].Add([int]$item.Id)
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $seen.Add($current)) { continue }
        if ($children.ContainsKey($current)) { foreach ($child in $children[$current]) { $queue.Enqueue($child) } }
    }
    return @($seen | Sort-Object | ForEach-Object {
        $item = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } } catch { $parentId = 0 }
            [pscustomobject]@{ Id = [int]$item.Id; ParentId = $parentId; Name = [string]$item.ProcessName }
        }
    })
}

function Stop-TestApp {
    <# 正常关闭并核对完整实验进程树没有残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    $tree = @(Get-ProcessTree -RootProcessId $Process.Id)
    $Process.CloseMainWindow() | Out-Null
    if (-not $Process.WaitForExit(15000)) { Stop-Process -Id $Process.Id -Force }
    $remaining = @()
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $remaining = @($tree | Where-Object { $null -ne (Get-Process -Id $_.Id -ErrorAction SilentlyContinue) } | Select-Object -ExpandProperty Id)
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Tree = $tree; Remaining = $remaining }
}

function Get-PersistedMode {
    <# 读取真实应用关闭时写回的顶层模式。 #>
    if (-not (Test-Path -LiteralPath $actualSessionPath -PathType Leaf)) { throw '应用没有写出真实会话文件。' }
    return [string]((Get-Content -LiteralPath $actualSessionPath -Raw | ConvertFrom-Json).mode)
}

function Measure-AppShell {
    <# 采样桌面外壳 CPU 与内存；CPU 按逻辑处理器数量归一化。 #>
    param([Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][int]$Seconds)
    $rows = @()
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $previousCpu = $process.TotalProcessorTime.TotalSeconds
    $previousTime = [DateTimeOffset]::UtcNow
    for ($sample = 1; $sample -le $Seconds; $sample++) {
        Start-Sleep -Seconds 1
        $now = [DateTimeOffset]::UtcNow
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $cpu = (($process.TotalProcessorTime.TotalSeconds - $previousCpu) / [Math]::Max(0.001, ($now - $previousTime).TotalSeconds) / [Environment]::ProcessorCount) * 100
        $previousCpu = $process.TotalProcessorTime.TotalSeconds
        $previousTime = $now
        $rows += [pscustomobject]@{ Cpu = $cpu; WorkingSet = $process.WorkingSet64 / 1MB; Private = $process.PrivateMemorySize64 / 1MB }
    }
    return [pscustomobject]@{
        CpuAveragePercent = [Math]::Round((($rows | Measure-Object Cpu -Average).Average), 4)
        WorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object WorkingSet -Maximum).Maximum), 3)
        PrivatePeakMiB = [Math]::Round((($rows | Measure-Object Private -Maximum).Maximum), 3)
    }
}

$process = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
Initialize-WindowAutomation

try {
    Initialize-FixtureRepository
    Initialize-IsolatedState
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'

    # 第一次真实启动只负责生成与当前 schema 完全一致的会话，随后改成旧 Agents 模式。
    $process = Start-TestApp
    Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'CLI优先验收'; cwd = $fixtureRoot } | Out-Null
    Start-Sleep -Seconds 2
    $seedClose = Stop-TestApp -Process $process
    $process = $null
    if ($seedClose.Remaining.Count -ne 0) { throw "种子启动关闭后仍有残留：$($seedClose.Remaining -join ',')" }
    $legacySession = Get-Content -LiteralPath $actualSessionPath -Raw | ConvertFrom-Json
    $legacySession.mode = 'agents'
    $legacySession | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $actualSessionPath -Encoding utf8

    # 第二次启动只验证旧 mode 在构造应用前回退，并把关闭时写回值作为机器证据。
    $process = Start-TestApp
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $restoreScreenshot
    $restoreClose = Stop-TestApp -Process $process
    $process = $null
    $modeAfterRestore = Get-PersistedMode
    if ($modeAfterRestore -ne 'cli') { throw "旧 Agents 会话没有回退到 CLI，实际为 $modeAfterRestore。" }

    # 第三次启动验证历史快捷键不能重新进入隐藏模式。
    $process = Start-TestApp
    Invoke-WorkspaceRowClick -Handle $process.MainWindowHandle
    Invoke-Shortcut -VirtualKey 0x41
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $shortcutScreenshot
    $shortcutClose = Stop-TestApp -Process $process
    $process = $null
    $modeAfterShortcut = Get-PersistedMode
    if ($modeAfterShortcut -ne 'cli') { throw "Ctrl+Shift+A 后模式异常：$modeAfterShortcut。" }

    # 第四次启动完成公开 CLI/Review 往返、真实后台输出和资源验收。
    $process = Start-TestApp
    $surfaces = @((Invoke-PaneflowRpc -Method 'surface.list' -Params @{}).surfaces | Where-Object { $_.scope -eq 'workspace' })
    if ($surfaces.Count -ne 1) { throw "预期一个真实工作区终端，实际为 $($surfaces.Count)。" }
    $surface = $surfaces[0]
    $command = '$i=0; while($i -lt 180){ Write-Output "CLI_FIRST_TICK_$i"; Start-Sleep -Milliseconds 500; $i++ }; Write-Output "CLI_FIRST_DONE"'
    Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{ surface_id = [uint64]$surface.surface_id; text = $command; submit = $true; paste = $false } | Out-Null
    Start-Sleep -Seconds 2
    Invoke-WorkspaceRowClick -Handle $process.MainWindowHandle
    Invoke-Shortcut -VirtualKey 0x47
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $reviewScreenshot
    Invoke-CliModeClick -Handle $process.MainWindowHandle
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $returnScreenshot

    $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = [uint64]$surface.surface_id; lines = 80; fenced = $false }
    $treeBeforeClose = @(Get-ProcessTree -RootProcessId $process.Id)
    $agentProcesses = @($treeBeforeClose | Where-Object { $_.Name -match '^(codex|claude|node|bun|deno)$' })
    $resources = Measure-AppShell -ProcessId $process.Id -Seconds $SampleSeconds
    $finalClose = Stop-TestApp -Process $process
    $process = $null
    $modeAfterReturn = Get-PersistedMode
    if ($modeAfterReturn -ne 'cli') { throw "点击 CLI 返回后模式异常：$modeAfterReturn。" }

    $result = [ordered]@{
        RunId = "真实CLI优先界面-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        LegacySessionModeWritten = 'agents'
        ModeAfterRestore = $modeAfterRestore
        OldAgentsSessionNormalized = ($modeAfterRestore -eq 'cli')
        ModeAfterCtrlShiftA = $modeAfterShortcut
        CtrlShiftACannotEnterAgents = ($modeAfterShortcut -eq 'cli')
        ModeAfterReviewReturn = $modeAfterReturn
        BackgroundOutputObserved = ([string]$read.text).Contains('CLI_FIRST_TICK_')
        OutputGeneration = [uint64]$read.output_generation
        ProcessTreeBeforeClose = $treeBeforeClose
        AgentsSpecificProcesses = $agentProcesses
        AppCpuAveragePercent = $resources.CpuAveragePercent
        AppWorkingSetPeakMiB = $resources.WorkingSetPeakMiB
        AppPrivatePeakMiB = $resources.PrivatePeakMiB
        RestoreScreenshot = $restoreScreenshot
        ShortcutScreenshot = $shortcutScreenshot
        ReviewScreenshot = $reviewScreenshot
        ReturnCliScreenshot = $returnScreenshot
        RestoreRemainingProcessIds = $restoreClose.Remaining
        ShortcutRemainingProcessIds = $shortcutClose.Remaining
        FinalTrackedProcessIds = @($finalClose.Tree | Select-Object -ExpandProperty Id)
        FinalRemainingProcessIds = $finalClose.Remaining
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
}
finally {
    try {
        if ($null -ne $process -and $null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            Stop-TestApp -Process $process | Out-Null
        }
    }
    finally {
        Restore-IsolatedState
        if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        if (Test-Path -LiteralPath $stateDirectory -PathType Container) { Remove-Item -LiteralPath $stateDirectory -Recurse -Force }
    }
}
