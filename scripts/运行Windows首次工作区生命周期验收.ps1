<#
.SYNOPSIS
运行 AgentWorkspace 首次工作区生命周期的真实 Windows 验收。

.DESCRIPTION
脚本隔离用户配置与会话，使用真实 Release 桌面程序、Win32 输入、命名管道、
PowerShell/ConPTY 和本地 Git，验证空首屏、取消目录选择、显式目录创建、非 Git
初始化、正常重启恢复、损坏会话降级以及关闭零残留。脚本不会使用模拟终端或模拟仓库。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\首次工作区生命周期数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实首启-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWFirstWorkspace-$timestamp"
$launchRoot = Join-Path $fixtureRoot '启动目录'
$workspaceRoot = Join-Path $fixtureRoot '显式工作区'
$resultPath = Join-Path $runDirectory '运行结果.json'
$emptyScreenshot = Join-Path $runDirectory '空工作区.png'
$cancelScreenshot = Join-Path $runDirectory '取消选目录后.png'
$narrowScreenshot = Join-Path $runDirectory '窄窗口空工作区.png'
$createdScreenshot = Join-Path $runDirectory '创建首个工作区.png'
$restoredScreenshot = Join-Path $runDirectory '重启恢复工作区.png'
$malformedScreenshot = Join-Path $runDirectory '损坏会话降级空工作区.png'
$savedSessionPath = Join-Path $runDirectory '创建后会话.json'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory, $launchRoot, $workspaceRoot | Out-Null
Set-Content -LiteralPath (Join-Path $workspaceRoot 'FIRST_WORKSPACE.txt') -Encoding utf8 -Value '真实首次工作区验收'

function Invoke-PaneflowRpc {
    <# 通过真实命名管道执行一次 JSON-RPC 调用。 #>
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
    <# 有界等待桌面实例完成真实命名管道初始化。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-PaneflowRpc -Method 'system.ping' -Params @{}).pong) { return }
        }
        catch {
            # 冷启动期间命名管道尚未创建属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存用户真实状态，使验收可重复且不污染日常工作区。 #>
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
    <# 删除实验状态，并把用户配置和会话原样放回。 #>
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

function Initialize-WindowAutomation {
    <# 注册窗口定位、真实鼠标键盘输入和截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceFirstWorkspaceInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@
}

function Start-TestApp {
    <# 从一个非 Git 目录启动真实 Release 应用，证明启动目录不会被隐式绑定。 #>
    $process = Start-Process -FilePath $binary -WorkingDirectory $launchRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            [AgentWorkspaceFirstWorkspaceInput]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
            [AgentWorkspaceFirstWorkspaceInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 20, 20, 1280, 800, 0x0040) | Out-Null
            [AgentWorkspaceFirstWorkspaceInput]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 900
            return $process
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 主窗口在 15 秒内未就绪。'
}

function Get-WindowRectValue {
    <# 返回主窗口当前屏幕坐标。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = New-Object AgentWorkspaceFirstWorkspaceInput+RECT
    if (-not [AgentWorkspaceFirstWorkspaceInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    return $rect
}

function Save-WindowScreenshot {
    <# 保存真实产品窗口截图，不包含桌面其他区域。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)
    $rect = Get-WindowRectValue -Handle $Handle
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

function Invoke-ChooseFolderAndCancel {
    <# 点击空首屏主操作，观察真实系统目录对话框后用 Escape 取消。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = Get-WindowRectValue -Handle $Handle
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    # 左栏约 248px；主操作位于剩余主区域的水平中心和空态文案下方。
    $x = $rect.Left + 248 + [Math]::Floor(($width - 248) / 2)
    $y = $rect.Top + [Math]::Floor($height / 2) + 52
    [AgentWorkspaceFirstWorkspaceInput]::SetForegroundWindow($Handle) | Out-Null
    [AgentWorkspaceFirstWorkspaceInput]::SetCursorPos($x, $y) | Out-Null
    [AgentWorkspaceFirstWorkspaceInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceFirstWorkspaceInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    $dialogObserved = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $foreground = [AgentWorkspaceFirstWorkspaceInput]::GetForegroundWindow()
        if ($foreground -ne [IntPtr]::Zero -and $foreground -ne $Handle) {
            $dialogObserved = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $dialogObserved) { throw '点击主操作后没有观察到系统目录选择对话框。' }
    [AgentWorkspaceFirstWorkspaceInput]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceFirstWorkspaceInput]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 1
    return $dialogObserved
}

function Get-ProcessTree {
    <# 返回应用根进程与当前全部后代，用于验证 PTY 数量和退出清理。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    $children = @{}
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
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
        $process = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($null -ne $process) { [pscustomobject]@{ Id = [int]$process.Id; Name = [string]$process.ProcessName } }
    })
}

function Get-WorkspaceSurfaces {
    <# 返回当前所有真实工作区根终端。 #>
    return @((Invoke-PaneflowRpc -Method 'surface.list' -Params @{}).surfaces | Where-Object { $_.scope -eq 'workspace' } | Sort-Object workspace)
}

function Get-WorkspaceList {
    <# 返回当前左侧工作区模型。 #>
    return @((Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}).workspaces | Sort-Object index)
}

function Stop-TestApp {
    <# 正常关闭应用，并等待本轮完整进程树归零。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    $tree = @(Get-ProcessTree -RootProcessId $Process.Id)
    $starts = @{}
    foreach ($item in $tree) {
        $live = Get-Process -Id $item.Id -ErrorAction SilentlyContinue
        if ($null -ne $live) { $starts[$item.Id] = $live.StartTime.ToUniversalTime().Ticks }
    }
    $Process.CloseMainWindow() | Out-Null
    if (-not $Process.WaitForExit(15000)) { Stop-Process -Id $Process.Id -Force }
    $remaining = @()
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $remaining = @(foreach ($item in $tree) {
            $live = Get-Process -Id $item.Id -ErrorAction SilentlyContinue
            if ($null -ne $live -and $starts.ContainsKey($item.Id) -and $live.StartTime.ToUniversalTime().Ticks -eq $starts[$item.Id]) { $item.Id }
        })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Tree = $tree; Remaining = $remaining }
}

$process = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
Initialize-WindowAutomation

try {
    Initialize-IsolatedState
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'

    $process = Start-TestApp
    $emptyWorkspaces = @(Get-WorkspaceList)
    $emptySurfaces = @(Get-WorkspaceSurfaces)
    $emptyTree = @(Get-ProcessTree -RootProcessId $process.Id)
    $emptyShells = @($emptyTree | Where-Object { $_.Name -in @('pwsh', 'powershell') })
    $emptyConhosts = @($emptyTree | Where-Object { $_.Name -eq 'conhost' })
    if ($emptyWorkspaces.Count -ne 0 -or $emptySurfaces.Count -ne 0) { throw '首次启动没有保持零工作区。' }
    if ($emptyShells.Count -ne 0 -or $emptyConhosts.Count -ne 0) { throw '空首屏意外创建了 PowerShell 或 conhost。' }
    if (Test-Path -LiteralPath (Join-Path $launchRoot '.git')) { throw '启动目录被隐式初始化为 Git 仓库。' }
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $emptyScreenshot

    $dialogObserved = Invoke-ChooseFolderAndCancel -Handle $process.MainWindowHandle
    if (@(Get-WorkspaceList).Count -ne 0 -or @(Get-WorkspaceSurfaces).Count -ne 0) { throw '取消目录选择后意外创建了工作区。' }
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $cancelScreenshot
    # 新空态必须在常见窄桌面窗口中仍保持主操作可见且不发生层级重叠。
    [AgentWorkspaceFirstWorkspaceInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 20, 20, 900, 600, 0x0040) | Out-Null
    Start-Sleep -Milliseconds 750
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $narrowScreenshot
    [AgentWorkspaceFirstWorkspaceInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 20, 20, 1280, 800, 0x0040) | Out-Null
    Start-Sleep -Milliseconds 750

    $createWatch = [Diagnostics.Stopwatch]::StartNew()
    $create = Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = '首次显式工作区'; cwd = $workspaceRoot }
    $createWatch.Stop()
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ((Test-Path -LiteralPath (Join-Path $workspaceRoot '.git')) -and @(Get-WorkspaceSurfaces).Count -eq 1) { break }
        Start-Sleep -Milliseconds 100
    }
    $createdWorkspaces = @(Get-WorkspaceList)
    $createdSurfaces = @(Get-WorkspaceSurfaces)
    $createdTree = @(Get-ProcessTree -RootProcessId $process.Id)
    $createdShells = @($createdTree | Where-Object { $_.Name -in @('pwsh', 'powershell') })
    if ($createdWorkspaces.Count -ne 1 -or $createdSurfaces.Count -ne 1) { throw '显式目录没有创建唯一工作区终端。' }
    if ($createdShells.Count -ne 1) { throw "显式目录创建后应有一个 PowerShell，实际为 $($createdShells.Count)。" }
    if (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.git'))) { throw '非 Git 工作区没有完成本地 git init。' }
    if ([IO.Path]::GetFullPath([string]$createdWorkspaces[0].cwd) -ne [IO.Path]::GetFullPath($workspaceRoot)) { throw '工作区没有绑定选定的稳定目录。' }
    Start-Sleep -Seconds 2
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $createdScreenshot
    $firstShellPids = @($createdShells | ForEach-Object { [int]$_.Id })
    $firstClose = Stop-TestApp -Process $process
    $process = $null
    if ($firstClose.Remaining.Count -ne 0) { throw "首次关闭后仍有残留：$($firstClose.Remaining -join ',')。" }
    Copy-Item -LiteralPath $actualSessionPath -Destination $savedSessionPath -Force

    $process = Start-TestApp
    Start-Sleep -Seconds 3
    $restoredWorkspaces = @(Get-WorkspaceList)
    $restoredSurfaces = @(Get-WorkspaceSurfaces)
    $restoredTree = @(Get-ProcessTree -RootProcessId $process.Id)
    $restoredShells = @($restoredTree | Where-Object { $_.Name -in @('pwsh', 'powershell') })
    if ($restoredWorkspaces.Count -ne 1 -or $restoredSurfaces.Count -ne 1) { throw '正常重启没有恢复唯一工作区。' }
    if ([IO.Path]::GetFullPath([string]$restoredWorkspaces[0].cwd) -ne [IO.Path]::GetFullPath($workspaceRoot)) { throw '重启后稳定工作区目录发生变化。' }
    $restoredShellPids = @($restoredShells | ForEach-Object { [int]$_.Id })
    if (@($restoredShellPids | Where-Object { $firstShellPids -contains $_ }).Count -ne 0) { throw '重启后的 PTY 进程没有被重新构造。' }
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $restoredScreenshot
    $restoredClose = Stop-TestApp -Process $process
    $process = $null
    if ($restoredClose.Remaining.Count -ne 0) { throw "恢复关闭后仍有残留：$($restoredClose.Remaining -join ',')。" }

    Set-Content -LiteralPath $actualSessionPath -Encoding utf8 -Value '{损坏的会话'
    $process = Start-TestApp
    if (@(Get-WorkspaceList).Count -ne 0 -or @(Get-WorkspaceSurfaces).Count -ne 0) { throw '损坏会话没有降级为空工作区。' }
    $malformedTree = @(Get-ProcessTree -RootProcessId $process.Id)
    if (@($malformedTree | Where-Object { $_.Name -in @('pwsh', 'powershell', 'conhost') }).Count -ne 0) { throw '损坏会话降级时意外创建了终端进程。' }
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $malformedScreenshot
    $malformedClose = Stop-TestApp -Process $process
    $process = $null
    if ($malformedClose.Remaining.Count -ne 0) { throw "损坏会话关闭后仍有残留：$($malformedClose.Remaining -join ',')。" }

    $result = [ordered]@{
        RunId = "真实首启-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        EmptyWorkspaceCount = $emptyWorkspaces.Count
        EmptySurfaceCount = $emptySurfaces.Count
        EmptyPowerShellCount = $emptyShells.Count
        EmptyConhostCount = $emptyConhosts.Count
        LaunchDirectoryGitCreated = (Test-Path -LiteralPath (Join-Path $launchRoot '.git'))
        FolderDialogObserved = $dialogObserved
        WorkspaceCountAfterCancel = 0
        CreatedWorkspaceIndex = [int]$create.index
        CreateRpcMilliseconds = [Math]::Round($createWatch.Elapsed.TotalMilliseconds, 3)
        WorkspaceRoot = $workspaceRoot
        WorkspaceGitInitialized = (Test-Path -LiteralPath (Join-Path $workspaceRoot '.git'))
        FirstPowerShellProcessIds = $firstShellPids
        RestoredPowerShellProcessIds = $restoredShellPids
        PowerShellPidsFullyReplaced = $true
        MalformedSessionWorkspaceCount = 0
        EmptyScreenshot = $emptyScreenshot
        CancelScreenshot = $cancelScreenshot
        NarrowScreenshot = $narrowScreenshot
        CreatedScreenshot = $createdScreenshot
        RestoredScreenshot = $restoredScreenshot
        MalformedScreenshot = $malformedScreenshot
        FirstRemainingProcessIds = $firstClose.Remaining
        RestoredRemainingProcessIds = $restoredClose.Remaining
        MalformedRemainingProcessIds = $malformedClose.Remaining
        Passed = $true
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
