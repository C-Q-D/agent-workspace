<#
.SYNOPSIS
运行 AgentWorkspace 中文终端可读性的真实 Windows 验收。

.DESCRIPTION
脚本隔离用户状态，通过真实 Release 应用、PowerShell 与 ConPTY 输出中英文混排，
机器校验终端回读内容，并在 14pt、17pt、21pt 三档字号下保存视觉证据。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\中文终端数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实中文终端-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWCjk-$timestamp"
$resultPath = Join-Path $runDirectory '运行结果.json'
$defaultScreenshot = Join-Path $runDirectory '中文终端-14pt.png'
$mediumScreenshot = Join-Path $runDirectory '中文终端-17pt.png'
$largeScreenshot = Join-Path $runDirectory '中文终端-21pt.png'
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
    [ordered]@{ telemetry = [ordered]@{ enabled = $false }; font_size = 14.0 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $actualConfigPath -Encoding utf8
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

function Initialize-WindowAutomation {
    <# 注册窗口定位、键盘输入、DPI 读取和截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceCjkInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
'@
}

function Get-WindowRectValue {
    <# 返回真实产品窗口的屏幕坐标。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)
    $rect = New-Object AgentWorkspaceCjkInput+RECT
    if (-not [AgentWorkspaceCjkInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    return $rect
}

function Start-TestApp {
    <# 从真实中文工作目录启动 Release 应用并等待主窗口就绪。 #>
    $process = Start-Process -FilePath $binary -WorkingDirectory $fixtureRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            [AgentWorkspaceCjkInput]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
            [AgentWorkspaceCjkInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 20, 20, 1280, 800, 0x0040) | Out-Null
            [AgentWorkspaceCjkInput]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 800
            return $process
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 主窗口在 15 秒内未就绪。'
}

function Invoke-MouseClick {
    <# 在真实产品窗口内点击指定客户区位置。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [int]$OffsetX, [int]$OffsetY)
    $rect = Get-WindowRectValue -Handle $Handle
    [AgentWorkspaceCjkInput]::SetForegroundWindow($Handle) | Out-Null
    [AgentWorkspaceCjkInput]::SetCursorPos($rect.Left + $OffsetX, $rect.Top + $OffsetY) | Out-Null
    Start-Sleep -Milliseconds 200
    [AgentWorkspaceCjkInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceCjkInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

function Invoke-FontIncrease {
    <# 向当前终端发送真实 Ctrl+=，每次增加 1pt。 #>
    param([Parameter(Mandatory = $true)][int]$Count)
    foreach ($step in 1..$Count) {
        [AgentWorkspaceCjkInput]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
        [AgentWorkspaceCjkInput]::keybd_event(0xBB, 0, 0, [UIntPtr]::Zero)
        [AgentWorkspaceCjkInput]::keybd_event(0xBB, 0, 2, [UIntPtr]::Zero)
        [AgentWorkspaceCjkInput]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 150
    }
    Start-Sleep -Seconds 1
}

function Save-WindowScreenshot {
    <# 只截取真实产品窗口，避免桌面其他内容污染证据。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)
    $rect = Get-WindowRectValue -Handle $Handle
    [AgentWorkspaceCjkInput]::SetCursorPos($rect.Left + 600, $rect.Top + 18) | Out-Null
    Start-Sleep -Milliseconds 350
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

function Get-ProcessTree {
    <# 返回根进程和全部后代的实时 PID、父 PID与进程名。 #>
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

    $surfaces = @((Invoke-PaneflowRpc -Method 'surface.list' -Params @{}).surfaces | Where-Object { $_.scope -eq 'workspace' })
    if ($surfaces.Count -ne 1) { throw "预期一个真实工作区终端，实际为 $($surfaces.Count)。" }
    $surface = $surfaces[0]
    $lines = @(
        '=== 中文宽字符真实验收 ===',
        'A中B文C',
        'A  B  C',
        '中文AB',
        '    AB',
        '路径：F:\中文目录\示例文件.rs',
        '标点：【测试】，“正常”。',
        'CJK_ACCEPTANCE_DONE'
    )
    $encodedLines = @($lines | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })
    $command = '$values=@(' + (($encodedLines | ForEach-Object { "'$($_)'" }) -join ',') + '); foreach($value in $values){[Console]::WriteLine([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)))}'
    Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{ surface_id = [uint64]$surface.surface_id; text = $command; submit = $true; paste = $false } | Out-Null

    $read = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = [uint64]$surface.surface_id; lines = 120; fenced = $false }
        if ([string]$read.text -match 'CJK_ACCEPTANCE_DONE') { break }
        Start-Sleep -Milliseconds 250
    }
    $terminalText = [string]$read.text
    $missingLines = @($lines | Where-Object { -not $terminalText.Contains($_) })
    if ($missingLines.Count -ne 0) { throw "真实终端回读缺少内容：$($missingLines -join ' | ')" }

    # 点击左侧工作区进入单窗格放大，再点击终端正文以确保字号快捷键落到目标终端。
    Invoke-MouseClick -Handle $process.MainWindowHandle -OffsetX 120 -OffsetY 104
    Invoke-MouseClick -Handle $process.MainWindowHandle -OffsetX 650 -OffsetY 400
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $defaultScreenshot
    Invoke-FontIncrease -Count 3
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $mediumScreenshot
    Invoke-FontIncrease -Count 4
    Save-WindowScreenshot -Handle $process.MainWindowHandle -Path $largeScreenshot

    $dpi = [AgentWorkspaceCjkInput]::GetDpiForWindow($process.MainWindowHandle)
    $close = Stop-TestApp -Process $process
    $process = $null
    if ($close.Remaining.Count -ne 0) { throw "关闭后仍有残留进程：$($close.Remaining -join ',')。" }

    $result = [ordered]@{
        RunId = "真实中文终端-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        WindowDpi = $dpi
        WindowScalePercent = [Math]::Round(($dpi / 96.0) * 100, 2)
        FontSizesTestedPt = @(14, 17, 21)
        ExactReadbackPassed = ($missingLines.Count -eq 0)
        OutputGeneration = [uint64]$read.output_generation
        ExpectedLines = $lines
        DefaultScreenshot = $defaultScreenshot
        MediumScreenshot = $mediumScreenshot
        LargeScreenshot = $largeScreenshot
        TrackedProcesses = $close.Tree
        RemainingProcessIds = $close.Remaining
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
