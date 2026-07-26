<#
.SYNOPSIS
验证多窗格 Grid 为零活动上下文、聚焦与 Review 至多一个上下文。

.DESCRIPTION
脚本创建多个互不相同的真实本地 Git 仓库和多个 PowerShell/ConPTY 窗口，
通过真实窗口点击进入聚焦、切换工作区并进入 Review。每个阶段从生产 IPC 读取
资源快照，采样桌面外壳 CPU/内存，最后验证终端 PID 稳定和进程零残留。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(1, 20)]
    [int]$WorkspaceCount = 16,

    [ValidateRange(3, 30)]
    [int]$SampleSeconds = 6,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\活动上下文性能数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实上下文-$timestamp"
$fixtureRoot = "F:\AWContext-$timestamp"
$dataRoot = Join-Path $env:USERPROFILE '.agent-workspace'
$configPath = Join-Path $dataRoot 'config\settings.json'
$sessionPath = Join-Path $dataRoot 'sessions\workspaces.json'
$backupDirectory = Join-Path $runDirectory '状态备份'
$configBackup = Join-Path $backupDirectory '用户配置.json'
$sessionBackup = Join-Path $backupDirectory '用户会话.json'
$pipeName = "agent-workspace-context-$timestamp"
$pipePath = "\\.\pipe\$pipeName"
$resultPath = Join-Path $runDirectory '运行结果.json'
$gridScreenshot = Join-Path $runDirectory ('{0}窗格矩阵.png' -f $WorkspaceCount)
$focusedScreenshot = Join-Path $runDirectory '单一聚焦上下文.png'
$reviewScreenshot = Join-Path $runDirectory '单一Review上下文.png'

New-Item -ItemType Directory -Force -Path $runDirectory, $backupDirectory, $fixtureRoot | Out-Null

function Invoke-AgentWorkspaceRpc {
    <# 使用一次一连接命名管道协议调用真实应用。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][object]$Params)

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(([ordered]@{
            jsonrpc = '2.0'; method = $Method; params = $Params; id = 1
        } | ConvertTo-Json -Depth 12 -Compress))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { throw "IPC $Method 返回空响应。" }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "IPC $Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-AgentWorkspaceReady {
    <# 有界等待命名管道完成启动。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-AgentWorkspaceRpc -Method 'system.ping' -Params @{}).pong) { return }
        }
        catch {
            # 冷启动时管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'AgentWorkspace IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存用户配置与会话，验收只使用临时状态。 #>
    if (Get-Process agent-workspace -ErrorAction SilentlyContinue) {
        throw '开始验收前仍存在 AgentWorkspace 进程。'
    }
    $script:hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $sessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $configPath -Parent), (Split-Path $sessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $configPath -Destination $configBackup }
    if ($script:hadSession) { Move-Item -LiteralPath $sessionPath -Destination $sessionBackup }
    '{"telemetry":{"enabled":false}}' | Set-Content -LiteralPath $configPath -Encoding utf8
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 删除实验状态并原样恢复用户文件。 #>
    if (-not $script:statePrepared) { return }
    if (Test-Path -LiteralPath $sessionPath -PathType Leaf) { Remove-Item -LiteralPath $sessionPath -Force }
    if ($script:hadSession -and (Test-Path -LiteralPath $sessionBackup -PathType Leaf)) {
        Move-Item -LiteralPath $sessionBackup -Destination $sessionPath -Force
    }
    if ($script:hadConfig -and (Test-Path -LiteralPath $configBackup -PathType Leaf)) {
        Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
    }
    elseif (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force
    }
    $script:statePrepared = $false
}

function Initialize-Repository {
    <# 创建独立真实 Git 仓库，防止共享 root 掩盖按窗口扇出的 watcher。 #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$Index)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    git -C $Path init --quiet
    git -C $Path config user.name 'AgentWorkspace Context Test'
    git -C $Path config user.email 'context-test@example.invalid'
    "repo-$Index" | Set-Content -LiteralPath (Join-Path $Path 'README.md') -Encoding utf8
    git -C $Path add -- README.md
    git -C $Path commit --quiet -m '建立上下文验收基线'
    if ($LASTEXITCODE -ne 0) { throw "Git 仓库初始化失败：$Path" }
}

function Get-ProcessTreeIds {
    <# 用实时父子关系返回根进程与全部后代。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $children = @{}
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } }
        catch { $parentId = 0 }
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
    return @($seen | Sort-Object)
}

function Get-PowerShellIds {
    <# 返回实验进程树中的真实 PowerShell PID。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    return @(Get-ProcessTreeIds -RootProcessId $RootProcessId | ForEach-Object {
        Get-Process -Id $_ -ErrorAction SilentlyContinue
    } | Where-Object { $null -ne $_ -and $_.ProcessName -in @('pwsh', 'powershell') } |
        Select-Object -ExpandProperty Id | Sort-Object)
}

function Initialize-WindowAutomation {
    <# 注册仅作用于产品窗口的点击、快捷键和截图 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceContextInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@
}

function Get-MainWindow {
    <# 获取并固定真实产品窗口尺寸。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            $handle = $Process.MainWindowHandle
            [AgentWorkspaceContextInput]::ShowWindow($handle, 9) | Out-Null
            [AgentWorkspaceContextInput]::SetWindowPos($handle, [IntPtr](-1), 20, 20, 1440, 900, 0x0040) | Out-Null
            [AgentWorkspaceContextInput]::SetForegroundWindow($handle) | Out-Null
            Start-Sleep -Milliseconds 800
            return $handle
        }
        Start-Sleep -Milliseconds 250
    }
    throw '真实产品窗口在 15 秒内未就绪。'
}

function Invoke-WorkspaceRowClick {
    <# 点击左栏可见工作区行；索引 0/1 足以验证 A→B 资源换绑。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [ValidateRange(0, 1)][int]$Index)
    $rect = New-Object AgentWorkspaceContextInput+RECT
    if (-not [AgentWorkspaceContextInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取窗口坐标。' }
    [AgentWorkspaceContextInput]::SetCursorPos($rect.Left + 120, $rect.Top + 104 + ($Index * 52)) | Out-Null
    [AgentWorkspaceContextInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 2
}

function Invoke-ReviewShortcut {
    <# 发送产品默认 Ctrl+Shift+G 进入真实 Review。 #>
    [AgentWorkspaceContextInput]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::keybd_event(0x47, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::keybd_event(0x47, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceContextInput]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 3
}

function Save-ProductScreenshot {
    <# 只截取 AgentWorkspace 窗口，不读取用户当前使用的其他软件。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)
    $rect = New-Object AgentWorkspaceContextInput+RECT
    if (-not [AgentWorkspaceContextInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取窗口坐标。' }
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

function Measure-AppShell {
    <# 按一秒节拍采样桌面外壳与子进程树资源，避免只看主进程而漏掉 PowerShell 成本。 #>
    param([Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][int]$Seconds)

    function Get-MemorySumMiB {
        <# Windows PowerShell 严格模式下空集合的 Measure-Object 结果不稳定，显式累加保证 0 值可读。 #>
        param([object[]]$Items = @(), [Parameter(Mandatory = $true)][string]$PropertyName)
        $sum = 0.0
        foreach ($item in $Items) {
            if ($item.PSObject.Properties.Name -contains $PropertyName) {
                $sum += [double]$item.$PropertyName
            }
        }
        return $sum / 1MB
    }

    $rows = @()
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $previousCpu = $process.TotalProcessorTime.TotalSeconds
    $previousTime = [DateTimeOffset]::UtcNow
    for ($sample = 0; $sample -lt $Seconds; $sample++) {
        Start-Sleep -Seconds 1
        $now = [DateTimeOffset]::UtcNow
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $tree = @(Get-ProcessTreeIds -RootProcessId $ProcessId | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue
        } | Where-Object { $null -ne $_ })
        $powerShell = @($tree | Where-Object { $_.ProcessName -in @('pwsh', 'powershell') })
        $conhost = @($tree | Where-Object { $_.ProcessName -eq 'conhost' })
        $cpu = (($process.TotalProcessorTime.TotalSeconds - $previousCpu) /
            [Math]::Max(0.001, ($now - $previousTime).TotalSeconds) /
            [Environment]::ProcessorCount) * 100
        $rows += [pscustomobject]@{
            Cpu = $cpu
            WorkingSetMiB = $process.WorkingSet64 / 1MB
            PrivateMiB = $process.PrivateMemorySize64 / 1MB
            Handles = $process.HandleCount
            TreeProcessCount = $tree.Count
            TreeWorkingSetMiB = Get-MemorySumMiB -Items $tree -PropertyName 'WorkingSet64'
            TreePrivateMiB = Get-MemorySumMiB -Items $tree -PropertyName 'PrivateMemorySize64'
            PowerShellCount = $powerShell.Count
            PowerShellWorkingSetMiB = Get-MemorySumMiB -Items $powerShell -PropertyName 'WorkingSet64'
            PowerShellPrivateMiB = Get-MemorySumMiB -Items $powerShell -PropertyName 'PrivateMemorySize64'
            ConhostCount = $conhost.Count
            ConhostWorkingSetMiB = Get-MemorySumMiB -Items $conhost -PropertyName 'WorkingSet64'
            ConhostPrivateMiB = Get-MemorySumMiB -Items $conhost -PropertyName 'PrivateMemorySize64'
        }
        $previousCpu = $process.TotalProcessorTime.TotalSeconds
        $previousTime = $now
    }
    return [ordered]@{
        CpuAveragePercent = [Math]::Round((($rows | Measure-Object Cpu -Average).Average), 4)
        WorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object WorkingSetMiB -Maximum).Maximum), 3)
        PrivatePeakMiB = [Math]::Round((($rows | Measure-Object PrivateMiB -Maximum).Maximum), 3)
        HandlePeak = [int](($rows | Measure-Object Handles -Maximum).Maximum)
        TreeProcessCountPeak = [int](($rows | Measure-Object TreeProcessCount -Maximum).Maximum)
        TreeWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object TreeWorkingSetMiB -Maximum).Maximum), 3)
        TreePrivatePeakMiB = [Math]::Round((($rows | Measure-Object TreePrivateMiB -Maximum).Maximum), 3)
        PowerShellCountPeak = [int](($rows | Measure-Object PowerShellCount -Maximum).Maximum)
        PowerShellWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object PowerShellWorkingSetMiB -Maximum).Maximum), 3)
        PowerShellPrivatePeakMiB = [Math]::Round((($rows | Measure-Object PowerShellPrivateMiB -Maximum).Maximum), 3)
        ConhostCountPeak = [int](($rows | Measure-Object ConhostCount -Maximum).Maximum)
        ConhostWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object ConhostWorkingSetMiB -Maximum).Maximum), 3)
        ConhostPrivatePeakMiB = [Math]::Round((($rows | Measure-Object ConhostPrivateMiB -Maximum).Maximum), 3)
    }
}

function Close-AndCheck {
    <# 正常关闭并核对本轮完整进程树零残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    $tracked = @(Get-ProcessTreeIds -RootProcessId $Process.Id)
    $Process.CloseMainWindow() | Out-Null
    if (-not $Process.WaitForExit(15000)) { Stop-Process -Id $Process.Id -Force }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $remaining = @($tracked | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { return [pscustomobject]@{ Tracked = $tracked; Remaining = @() } }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Tracked = $tracked; Remaining = $remaining }
}

$process = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
Initialize-WindowAutomation

try {
    Initialize-IsolatedState
    $roots = @()
    for ($index = 1; $index -le $WorkspaceCount; $index++) {
        $root = Join-Path $fixtureRoot ('repo-{0:D2}' -f $index)
        Initialize-Repository -Path $root -Index $index
        $roots += $root
    }

    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $env:PANEFLOW_SOCKET_PATH = $pipePath
    $process = Start-Process -FilePath $binary -WorkingDirectory $repositoryRoot -WindowStyle Normal -PassThru
    Wait-AgentWorkspaceReady
    foreach ($index in 0..($WorkspaceCount - 1)) {
        Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
            name = 'context-{0:D2}' -f ($index + 1)
            cwd = $roots[$index]
        } | Out-Null
    }
    Start-Sleep -Seconds 4
    $handle = Get-MainWindow -Process $process
    $powerShellBefore = @(Get-PowerShellIds -RootProcessId $process.Id)

    $grid = Invoke-AgentWorkspaceRpc -Method 'workspace.context_resources' -Params @{}
    if ($grid.surface -ne 'grid' -or [int]$grid.active_contexts -ne 0 -or
        [int]$grid.git_watchers -ne 0 -or [int]$grid.files_watchers -ne 0 -or
        [int]$grid.review_hosts -ne 0) {
        throw "$WorkspaceCount 窗格 Grid 不是零活动上下文：$($grid | ConvertTo-Json -Compress)"
    }
    $gridResources = Measure-AppShell -ProcessId $process.Id -Seconds $SampleSeconds
    Save-ProductScreenshot -Handle $handle -Path $gridScreenshot

    Invoke-WorkspaceRowClick -Handle $handle -Index 0
    $focusedA = Invoke-AgentWorkspaceRpc -Method 'workspace.context_resources' -Params @{}
    if ($focusedA.surface -ne 'focused' -or [int]$focusedA.active_contexts -ne 1 -or
        [int]$focusedA.git_watchers -ne 1 -or [int]$focusedA.files_watchers -gt 1 -or
        [int]$focusedA.review_hosts -ne 0) {
        throw "聚焦 A 未形成单一上下文：$($focusedA | ConvertTo-Json -Compress)"
    }
    $focusedResources = Measure-AppShell -ProcessId $process.Id -Seconds $SampleSeconds
    Save-ProductScreenshot -Handle $handle -Path $focusedScreenshot

    $focusedB = $null
    $focusedReplacementChecked = $false
    if ($WorkspaceCount -gt 1) {
        Invoke-WorkspaceRowClick -Handle $handle -Index 1
        $focusedB = Invoke-AgentWorkspaceRpc -Method 'workspace.context_resources' -Params @{}
        if ($focusedB.surface -ne 'focused' -or [int]$focusedB.active_contexts -ne 1 -or
            [int]$focusedB.git_watchers -ne 1 -or [uint64]$focusedB.workspace_id -eq [uint64]$focusedA.workspace_id) {
            throw "聚焦 B 未确定性替换 A：$($focusedB | ConvertTo-Json -Compress)"
        }
        $focusedReplacementChecked = $true
    }

    Invoke-ReviewShortcut
    $review = Invoke-AgentWorkspaceRpc -Method 'workspace.context_resources' -Params @{}
    if ($review.surface -ne 'review' -or [int]$review.active_contexts -ne 1 -or
        [int]$review.git_watchers -ne 0 -or [int]$review.files_watchers -ne 0 -or
        [int]$review.review_hosts -ne 1) {
        throw "Review 未由专用审查资源独占上下文：$($review | ConvertTo-Json -Compress)"
    }
    $reviewResources = Measure-AppShell -ProcessId $process.Id -Seconds $SampleSeconds
    Save-ProductScreenshot -Handle $handle -Path $reviewScreenshot
    $powerShellAfter = @(Get-PowerShellIds -RootProcessId $process.Id)

    $close = Close-AndCheck -Process $process
    $process = $null
    $result = [ordered]@{
        Commit = (git -C $repositoryRoot rev-parse HEAD).Trim()
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        WorkspaceCount = $WorkspaceCount
        DistinctRepositoryCount = @($roots | Select-Object -Unique).Count
        Grid = $grid
        FocusedA = $focusedA
        FocusedB = $focusedB
        Review = $review
        GridResources = $gridResources
        FocusedResources = $focusedResources
        ReviewResources = $reviewResources
        PowerShellCount = $powerShellBefore.Count
        PowerShellIdsStable = (($powerShellBefore -join ',') -eq ($powerShellAfter -join ','))
        FocusedReplacementChecked = $focusedReplacementChecked
        WorkingSetWithin256MiB = ([double]$gridResources.WorkingSetPeakMiB -le 256.0 -and
            [double]$focusedResources.WorkingSetPeakMiB -le 256.0 -and
            [double]$reviewResources.WorkingSetPeakMiB -le 256.0)
        CpuWithinOnePercent = ([double]$gridResources.CpuAveragePercent -le 1.0 -and
            [double]$focusedResources.CpuAveragePercent -le 1.0 -and
            [double]$reviewResources.CpuAveragePercent -le 1.0)
        RemainingProcessIds = @($close.Remaining)
        Passed = $false
    }
    $result.Passed = (
        $result.DistinctRepositoryCount -eq $WorkspaceCount -and
        $result.PowerShellIdsStable -and
        $result.WorkingSetWithin256MiB -and
        $result.CpuWithinOnePercent -and
        @($result.RemainingProcessIds).Count -eq 0
    )
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    if (-not $result.Passed) { throw "活动上下文性能门禁失败：$resultPath" }
    Write-Output "活动上下文性能验收通过：$resultPath"
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try { $process.CloseMainWindow() | Out-Null; if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force } } catch {}
    }
    Remove-Item Env:PANEFLOW_SOCKET_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:PANEFLOW_IPC_SCRIPTING -ErrorAction SilentlyContinue
    Remove-Item Env:PANEFLOW_NO_TELEMETRY -ErrorAction SilentlyContinue
    Restore-IsolatedState
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if ($resolvedFixture.StartsWith('F:\AWContext-', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        }
    }
}
