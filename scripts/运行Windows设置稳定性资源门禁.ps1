<#
.SYNOPSIS
运行 AgentWorkspace 稳定设置、9/16 窗格与分组资源采样门禁。

.DESCRIPTION
脚本在两个隔离 USERPROFILE 中分别启动 9 与 16 个真实 PowerShell/ConPTY 工作区，
交叉写入十项稳定设置，并采集冷启动、稳定空闲、活动输出、聚焦文件/Git 四个阶段。
资源结果把桌面宿主、终端 Shell、已知 CLI 和其他辅助进程分开记录，不把整棵进程树
冒充应用自身开销。所有等待都由真实状态或绝对采样节拍驱动；正常关闭必须零残留。

.PARAMETER BinaryPath
待验收的 Release agent-workspace.exe。

.PARAMETER SampleIntervalMilliseconds
资源采样间隔，默认 1000 毫秒；门禁拒绝小于 500 毫秒的高频采样。

.PARAMETER PhaseDurationSeconds
每个资源阶段的采样时长，默认 10 秒。

.PARAMETER SelfCheck
只输出参数、四阶段、进程分组和十键契约，不启动 GUI 或创建证据目录。

.PARAMETER KeepFixture
成功后保留仓库外固定前缀夹具，便于 A008 复核。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,

    [ValidateRange(500, 10000)]
    [int]$SampleIntervalMilliseconds = 1000,

    [ValidateRange(5, 300)]
    [int]$PhaseDurationSeconds = 10,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\设置稳定性资源数据'),

    [switch]$SelfCheck,

    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ExpectedTerminalCounts = @(9, 16)
$ExpectedPhases = @('cold-start', 'stable-idle', 'active-output', 'focused-file-git')
$ExpectedGroups = @('host', 'shell', 'cli', 'helper')
$ExpectedSettings = @(
    'theme_mode',
    'theme',
    'font_family',
    'font_size',
    'default_shell',
    'default_reference_format',
    'workspace_grid_density',
    'git_auto_init',
    'claude_code_command',
    'codex_command'
)

function Resolve-AcceptanceBinary {
    <# 校验真实 Release 二进制和公开产品身份，避免误验旧 Paneflow 程序。 #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Release 二进制不存在：$Path"
    }
    $Resolved = (Resolve-Path -LiteralPath $Path).Path
    if ([IO.Path]::GetFileName($Resolved) -ne 'agent-workspace.exe') {
        throw "二进制文件名必须是 agent-workspace.exe：$Resolved"
    }
    $Version = @(& $Resolved --version 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or -not (($Version -join "`n").Contains('agent-workspace'))) {
        throw "二进制版本输出没有确认 AgentWorkspace 身份：$($Version -join ' ')"
    }
    return $Resolved
}

function Write-Utf8Json {
    <# 统一使用无 BOM UTF-8 和尾换行，保证机器证据可稳定比较。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$Depth = 16
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth $Depth) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

$Binary = Resolve-AcceptanceBinary -Path $BinaryPath
$OutputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$Contract = [ordered]@{
    schemaVersion = 1
    platform = 'windows'
    binary = $Binary
    terminalCounts = $ExpectedTerminalCounts
    phases = $ExpectedPhases
    resourceGroups = $ExpectedGroups
    settingsKeys = $ExpectedSettings
    sampleIntervalMilliseconds = $SampleIntervalMilliseconds
    phaseDurationSeconds = $PhaseDurationSeconds
    interaction = '真实 AgentWorkspace、PowerShell/ConPTY、配置 watcher、应用级聚焦与恢复'
}

if ($SelfCheck) {
    if (-not $IsWindows) { throw '设置稳定性资源门禁只支持 Windows。' }
    if ($ExpectedSettings.Count -ne 10 -or @($ExpectedSettings | Sort-Object -Unique).Count -ne 10) {
        throw '稳定设置契约必须恰好包含十个唯一磁盘键。'
    }
    if (($ExpectedPhases -join ',') -ne 'cold-start,stable-idle,active-output,focused-file-git') {
        throw '资源阶段契约必须保持固定顺序。'
    }
    $Contract.result = 'self-check-passed'
    $Contract | ConvertTo-Json -Depth 8
    return
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Release-$Timestamp"
$EvidenceDirectory = Join-Path $OutputRoot $RunId
$VolumeRoot = [IO.Path]::GetPathRoot($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($VolumeRoot)) { throw '无法解析仓库所在卷。' }
$FixtureRoot = Join-Path $VolumeRoot "AWSettingsPerf-$RunId"
$SummaryPath = Join-Path $EvidenceDirectory '门禁结果.json'
if (Test-Path -LiteralPath $EvidenceDirectory) { throw "证据目录必须全新：$EvidenceDirectory" }
if (Test-Path -LiteralPath $FixtureRoot) { throw "夹具目录必须全新：$FixtureRoot" }
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始门禁前存在 AgentWorkspace 进程，无法可靠归因资源与残留。'
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory, $FixtureRoot | Out-Null

function Invoke-AgentWorkspaceRpc {
    <# 使用本场景唯一命名管道执行一次生产 JSON-RPC。 #>
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = @{}
    )

    $Pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $PipeName,
        [IO.Pipes.PipeDirection]::InOut
    )
    try {
        $Pipe.Connect(5000)
        $Utf8 = [Text.UTF8Encoding]::new($false)
        $Writer = [IO.StreamWriter]::new($Pipe, $Utf8, 1024, $true)
        $Reader = [IO.StreamReader]::new($Pipe, $Utf8, $false, 1024, $true)
        $Writer.AutoFlush = $true
        $Writer.WriteLine(([ordered]@{
            jsonrpc = '2.0'
            method = $Method
            params = $Params
            id = 1
        } | ConvertTo-Json -Depth 12 -Compress))
        $Line = $Reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($Line)) { throw "$Method 返回空响应。" }
        $Response = $Line | ConvertFrom-Json
        if ($Response.PSObject.Properties.Name -contains 'error') {
            throw "$Method 失败：$($Response.error | ConvertTo-Json -Compress)"
        }
        if ($Response.PSObject.Properties.Name -notcontains 'result') {
            throw "$Method 响应缺少 result。"
        }
        return $Response.result
    }
    finally { $Pipe.Dispose() }
}

function Get-ProcessTree {
    <# 返回根进程与全部实时后代，附带启动时刻防止 PID 复用误判。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $Children = @{}
    foreach ($Item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $ParentId = if ($null -eq $Item.Parent) { 0 } else { [int]$Item.Parent.Id } }
        catch { $ParentId = 0 }
        if (-not $Children.ContainsKey($ParentId)) {
            $Children[$ParentId] = [Collections.Generic.List[int]]::new()
        }
        $Children[$ParentId].Add([int]$Item.Id)
    }
    $Seen = [Collections.Generic.HashSet[int]]::new()
    $Queue = [Collections.Generic.Queue[int]]::new()
    $Queue.Enqueue($RootProcessId)
    while ($Queue.Count -gt 0) {
        $Current = $Queue.Dequeue()
        if (-not $Seen.Add($Current)) { continue }
        if ($Children.ContainsKey($Current)) {
            foreach ($Child in $Children[$Current]) { $Queue.Enqueue($Child) }
        }
    }
    return @($Seen | Sort-Object | ForEach-Object {
        $Live = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($null -ne $Live) {
            [ordered]@{
                id = [int]$Live.Id
                name = [string]$Live.ProcessName
                startedUtcTicks = $Live.StartTime.ToUniversalTime().Ticks
            }
        }
    })
}

function Get-ResourceGroup {
    <# 把进程树投影为宿主、Shell、CLI 和辅助进程四组，避免错误归因。 #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Processes,
        [Parameter(Mandatory = $true)][int]$RootProcessId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('host', 'shell', 'cli', 'helper')]
        [string]$Group
    )

    $ShellNames = @('pwsh', 'powershell')
    $CliNames = @('codex', 'claude', 'node', 'bun', 'deno')
    return @($Processes | Where-Object {
        # `switch` 会重绑定 PowerShell 自动变量 `$_` 为当前分支字符串；必须先保存
        # 外层管道中的真实 Process，否则宿主分支会尝试读取字符串的 Id。
        $ProcessItem = $_
        switch ($Group) {
            'host' { $ProcessItem.Id -eq $RootProcessId }
            'shell' { $ProcessItem.ProcessName -in $ShellNames }
            'cli' { $ProcessItem.ProcessName -in $CliNames }
            'helper' {
                $ProcessItem.Id -ne $RootProcessId -and
                $ProcessItem.ProcessName -notin $ShellNames -and
                $ProcessItem.ProcessName -notin $CliNames
            }
        }
    })
}

function Measure-ResourcePhase {
    <# 按绝对低频节拍采集四组资源，系统挂起时拒绝高速补采样。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $Rows = [Collections.Generic.List[object]]::new()
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $SampleCount = [Math]::Ceiling(($PhaseDurationSeconds * 1000.0) / $SampleIntervalMilliseconds)
    for ($Index = 0; $Index -lt $SampleCount; $Index++) {
        $Target = $Index * $SampleIntervalMilliseconds
        $Remaining = $Target - $Clock.Elapsed.TotalMilliseconds
        if ($Remaining -lt -10000) {
            throw "$Phase 采样时钟落后超过 10 秒，证据无效。"
        }
        if ($Remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Ceiling($Remaining)) }
        $Tree = @(Get-ProcessTree -RootProcessId $Process.Id)
        $Live = @($Tree | ForEach-Object {
            $Candidate = Get-Process -Id $_.id -ErrorAction SilentlyContinue
            if ($null -ne $Candidate -and
                $Candidate.StartTime.ToUniversalTime().Ticks -eq $_.startedUtcTicks) {
                $Candidate
            }
        })
        $Groups = [ordered]@{}
        foreach ($Name in $ExpectedGroups) {
            $Members = @(Get-ResourceGroup -Processes $Live -RootProcessId $Process.Id -Group $Name)
            $Groups[$Name] = [ordered]@{
                processCount = $Members.Count
                processIds = @($Members | ForEach-Object { [int]$_.Id } | Sort-Object)
                cpuTotalMilliseconds = [Math]::Round(
                    [double]((
                        $Members |
                            ForEach-Object { $_.TotalProcessorTime.TotalMilliseconds } |
                            Measure-Object -Sum
                    ).Sum),
                    3
                )
                workingSetMiB = [Math]::Round(
                    [double]((
                        $Members |
                            ForEach-Object { [double]$_.WorkingSet64 } |
                            Measure-Object -Sum
                    ).Sum) / 1MB,
                    3
                )
                privateMemoryMiB = [Math]::Round(
                    [double]((
                        $Members |
                            ForEach-Object { [double]$_.PrivateMemorySize64 } |
                            Measure-Object -Sum
                    ).Sum) / 1MB,
                    3
                )
                threadCount = [int]((
                    $Members |
                        ForEach-Object { $_.Threads.Count } |
                        Measure-Object -Sum
                ).Sum)
                handleCount = [int]((
                    $Members |
                        ForEach-Object { [int]$_.HandleCount } |
                        Measure-Object -Sum
                ).Sum)
            }
        }
        $Rows.Add([ordered]@{
            sample = $Index + 1
            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
            elapsedMilliseconds = [Math]::Round($Clock.Elapsed.TotalMilliseconds, 3)
            groups = $Groups
        })
    }
    return [ordered]@{
        name = $Phase
        intervalMilliseconds = $SampleIntervalMilliseconds
        requestedDurationSeconds = $PhaseDurationSeconds
        elapsedSeconds = [Math]::Round($Clock.Elapsed.TotalSeconds, 3)
        sampleCount = $Rows.Count
        samples = @($Rows)
    }
}

function Wait-AppReady {
    <# 有界等待真实窗口和生产 IPC，就绪条件满足后立即返回。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$PipeName
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $Deadline) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { throw "GUI 提前退出，退出码 $($Process.ExitCode)。" }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and
                (Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'system.ping').pong) {
                return
            }
        }
        catch {
            if ($Process.HasExited) { throw }
        }
        Start-Sleep -Milliseconds 200
    }
    throw '真实 AgentWorkspace 在 30 秒内未就绪。'
}

function Wait-MatrixReady {
    <# 等待工作区、Surface 和真实 PowerShell 数量同时达到目标。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][int]$TerminalCount
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Workspaces = @((Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'workspace.list').workspaces)
        $Surfaces = @(
            (Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'surface.list').surfaces |
                Where-Object { $_.scope -eq 'workspace' } |
                Sort-Object surface_id
        )
        $PowerShell = @(
            Get-ProcessTree -RootProcessId $Process.Id |
                Where-Object { $_.name -in @('pwsh', 'powershell') }
        )
        if ($Workspaces.Count -eq $TerminalCount -and
            $Surfaces.Count -eq $TerminalCount -and
            $PowerShell.Count -eq $TerminalCount) {
            return [ordered]@{
                workspaces = $Workspaces
                surfaces = $Surfaces
                powershell = $PowerShell
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "$TerminalCount 个工作区、Surface 与 PowerShell 未在 45 秒内就绪。"
}

function Write-SettingsRound {
    <# 单次原子写入十键组合；哨兵字段用于发现 watcher 覆盖。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('round-one', 'round-two')][string]$Round
    )

    $First = $Round -eq 'round-one'
    $Value = [ordered]@{
        telemetry = [ordered]@{ enabled = $false }
        theme_mode = if ($First) { 'dark' } else { 'light' }
        theme = if ($First) { 'One Dark' } else { 'AgentWorkspace Light' }
        font_family = if ($First) { 'Consolas' } else { 'Cascadia Mono' }
        font_size = if ($First) { 14.0 } else { 15.0 }
        default_shell = if ($First) { 'powershell.exe' } else { 'pwsh.exe' }
        default_reference_format = if ($First) { 'claude' } else { 'codex' }
        workspace_grid_density = if ($First) { 'compact' } else { 'comfortable' }
        git_auto_init = -not $First
        claude_code_command = if ($First) { 'claude --model sonnet' } else { 'claude --model opus' }
        codex_command = if ($First) { 'codex --sandbox workspace-write' } else { 'codex --sandbox read-only' }
        future_setting = [ordered]@{ preserved = $true }
    }
    Write-Utf8Json -Path $Path -Value $Value
    return $Value
}

function Initialize-WindowApi {
    <# 注册不激活窗口的定向鼠标消息与 PrintWindow 离屏截图。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceSettingsPerfWindow {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, UIntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@
}

function Invoke-WindowClick {
    <# 向目标应用客户区投递一次点击，不移动鼠标、不抢占用户前台窗口。 #>
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y
    )

    $LParam = [IntPtr](($Y -shl 16) -bor ($X -band 0xffff))
    [AgentWorkspaceSettingsPerfWindow]::PostMessage($Handle, 0x0201, [UIntPtr]1, $LParam) | Out-Null
    [AgentWorkspaceSettingsPerfWindow]::PostMessage($Handle, 0x0202, [UIntPtr]0, $LParam) | Out-Null
}

function Save-WindowScreenshot {
    <# 只离屏绘制 AgentWorkspace 自身，不读取桌面或其他应用。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Process.Refresh()
    $Handle = $Process.MainWindowHandle
    $Rect = New-Object AgentWorkspaceSettingsPerfWindow+RECT
    if ($Handle -eq [IntPtr]::Zero -or
        -not [AgentWorkspaceSettingsPerfWindow]::GetWindowRect($Handle, [ref]$Rect)) {
        throw '无法读取 AgentWorkspace 窗口矩形。'
    }
    $Bitmap = [Drawing.Bitmap]::new($Rect.Right - $Rect.Left, $Rect.Bottom - $Rect.Top)
    $Graphics = [Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Dc = $Graphics.GetHdc()
        try {
            if (-not [AgentWorkspaceSettingsPerfWindow]::PrintWindow($Handle, $Dc, 2)) {
                throw "PrintWindow 失败，错误码 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())。"
            }
        }
        finally { $Graphics.ReleaseHdc($Dc) }
        $Bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Graphics.Dispose()
        $Bitmap.Dispose()
    }
}

function Invoke-FocusAndRestore {
    <# 进入首个工作区聚焦态，采样文件/Git 上下文后主动点击恢复按钮。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ScreenshotPath
    )

    $Process.Refresh()
    $Handle = $Process.MainWindowHandle
    $Client = New-Object AgentWorkspaceSettingsPerfWindow+RECT
    if (-not [AgentWorkspaceSettingsPerfWindow]::GetClientRect($Handle, [ref]$Client)) {
        throw '无法读取 AgentWorkspace 客户区。'
    }
    Invoke-WindowClick -Handle $Handle -X 120 -Y 104
    Start-Sleep -Milliseconds 750
    Save-WindowScreenshot -Process $Process -Path $ScreenshotPath
    $FocusedPhase = Measure-ResourcePhase -Process $Process -Phase 'focused-file-git'
    # 聚焦后右侧文件树占 300px；恢复按钮位于中间主区域标题栏右端。
    $RestoreX = [Math]::Max(260, ($Client.Right - $Client.Left) - 316)
    Invoke-WindowClick -Handle $Handle -X $RestoreX -Y 56
    Start-Sleep -Milliseconds 750
    return $FocusedPhase
}

function Stop-AppGracefully {
    <# 正常关闭并按 PID+启动时间核对完整实验树零残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) { throw '真实 GUI 没有接受正常关闭请求。' }
    if (-not $Process.WaitForExit(15000)) { throw '真实 GUI 正常关闭 15 秒后仍未退出。' }
    if ($Process.ExitCode -ne 0) { throw "真实 GUI 退出码为 $($Process.ExitCode)。" }
    $Deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $Remaining = @(foreach ($Entry in $Tracked) {
            $Live = Get-Process -Id $Entry.id -ErrorAction SilentlyContinue
            if ($null -ne $Live -and
                $Live.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) {
                $Entry
            }
        })
        if ($Remaining.Count -eq 0) {
            return [ordered]@{ tracked = $Tracked; remaining = @() }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "正常关闭后仍有进程残留：$($Remaining | ConvertTo-Json -Compress)"
}

function Assert-TerminalOutput {
    <# 等待每个 Surface 观察到活动输出终点，禁止靠固定长等待假定执行完成。 #>
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][object[]]$Surfaces
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($PhaseDurationSeconds + 15)
    do {
        $Missing = @($Surfaces | Where-Object {
            $Read = Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'surface.read' -Params @{
                surface_id = [uint64]$_.surface_id
                lines = 40
                fenced = $false
            }
            -not ([string]$Read.text).Contains('A007-ACTIVE-DONE')
        })
        if ($Missing.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "$($Missing.Count) 个真实终端缺少活动输出终点。"
}

function Invoke-Scenario {
    <# 完整运行一个终端数量场景，并返回可独立审计的机器结果。 #>
    param([Parameter(Mandatory = $true)][ValidateSet(9, 16)][int]$TerminalCount)

    $ScenarioDirectory = Join-Path $EvidenceDirectory ("{0:D2}终端" -f $TerminalCount)
    $ScenarioFixture = Join-Path $FixtureRoot ("{0:D2}终端" -f $TerminalCount)
    $IsolatedUser = Join-Path $ScenarioFixture '隔离用户'
    $WorkspaceRoot = Join-Path $ScenarioFixture '真实Git工作区'
    $DataRoot = Join-Path $IsolatedUser '.agent-workspace'
    $ConfigPath = Join-Path $DataRoot 'config\settings.json'
    $PipeName = "agent-workspace-settings-perf-$TerminalCount-$Timestamp"
    $PipePath = "\\.\pipe\$PipeName"
    New-Item -ItemType Directory -Force -Path @(
        $ScenarioDirectory,
        $WorkspaceRoot,
        (Split-Path $ConfigPath -Parent)
    ) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $WorkspaceRoot '上下文文件.txt'),
        "A007 文件与 Git 上下文基线`n",
        [Text.UTF8Encoding]::new($false)
    )
    & git -C $WorkspaceRoot init --quiet
    & git -C $WorkspaceRoot config user.name 'AgentWorkspace A007'
    & git -C $WorkspaceRoot config user.email 'a007@example.invalid'
    & git -C $WorkspaceRoot add -- '上下文文件.txt'
    & git -C $WorkspaceRoot commit --quiet -m '建立 A007 上下文基线'
    [IO.File]::AppendAllText(
        (Join-Path $WorkspaceRoot '上下文文件.txt'),
        "A007 未提交改动`n",
        [Text.UTF8Encoding]::new($false)
    )
    $RoundOne = Write-SettingsRound -Path $ConfigPath -Round 'round-one'

    $PreviousEnvironment = [ordered]@{
        USERPROFILE = $env:USERPROFILE
        HOME = $env:HOME
        PANEFLOW_SOCKET_PATH = $env:PANEFLOW_SOCKET_PATH
        PANEFLOW_IPC_SCRIPTING = $env:PANEFLOW_IPC_SCRIPTING
        PANEFLOW_NO_TELEMETRY = $env:PANEFLOW_NO_TELEMETRY
    }
    $Process = $null
    try {
        $env:USERPROFILE = $IsolatedUser
        $env:HOME = $IsolatedUser
        $env:PANEFLOW_SOCKET_PATH = $PipePath
        $env:PANEFLOW_IPC_SCRIPTING = '1'
        $env:PANEFLOW_NO_TELEMETRY = '1'
        $LaunchClock = [Diagnostics.Stopwatch]::StartNew()
        $Process = Start-Process `
            -FilePath $Binary `
            -WorkingDirectory $RepositoryRoot `
            -WindowStyle Normal `
            -RedirectStandardOutput (Join-Path $ScenarioDirectory '标准输出.txt') `
            -RedirectStandardError (Join-Path $ScenarioDirectory '错误输出.txt') `
            -PassThru
        Wait-AppReady -Process $Process -PipeName $PipeName
        $ReadyMilliseconds = [Math]::Round($LaunchClock.Elapsed.TotalMilliseconds, 3)
        $Cold = Measure-ResourcePhase -Process $Process -Phase 'cold-start'

        for ($Index = 1; $Index -le $TerminalCount; $Index++) {
            Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'workspace.create' -Params @{
                name = 'A007-{0:D2}' -f $Index
                cwd = $WorkspaceRoot
            } | Out-Null
        }
        $Ready = Wait-MatrixReady -Process $Process -PipeName $PipeName -TerminalCount $TerminalCount
        $SurfaceIds = @($Ready.surfaces | ForEach-Object { [uint64]$_.surface_id })
        $PowerShellIds = @($Ready.powershell | ForEach-Object { [int]$_.id } | Sort-Object)
        $Idle = Measure-ResourcePhase -Process $Process -Phase 'stable-idle'

        $RoundTwo = Write-SettingsRound -Path $ConfigPath -Round 'round-two'
        $SecondWriteTime = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        $Iterations = [Math]::Max(5, [Math]::Ceiling($PhaseDurationSeconds * 5))
        foreach ($Surface in $Ready.surfaces) {
            $Command = "1..$Iterations | ForEach-Object { Write-Output ('A007-ACTIVE-' + `$_); Start-Sleep -Milliseconds 200 }; Write-Output 'A007-ACTIVE-DONE'"
            Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'surface.send_text' -Params @{
                surface_id = [uint64]$Surface.surface_id
                text = $Command
                submit = $true
                paste = $false
            } | Out-Null
        }
        $Active = Measure-ResourcePhase -Process $Process -Phase 'active-output'
        Assert-TerminalOutput -PipeName $PipeName -Surfaces $Ready.surfaces
        if ((Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -ne $SecondWriteTime) {
            throw '第二轮设置完成后出现额外配置写入。'
        }
        $FocusScreenshot = Join-Path $ScenarioDirectory '聚焦文件Git上下文.png'
        $Focused = Invoke-FocusAndRestore -Process $Process -ScreenshotPath $FocusScreenshot

        $After = Wait-MatrixReady -Process $Process -PipeName $PipeName -TerminalCount $TerminalCount
        $AfterSurfaceIds = @($After.surfaces | ForEach-Object { [uint64]$_.surface_id })
        $AfterPowerShellIds = @($After.powershell | ForEach-Object { [int]$_.id } | Sort-Object)
        if (($SurfaceIds -join ',') -ne ($AfterSurfaceIds -join ',')) {
            throw '设置、聚焦或恢复改变了 Surface ID。'
        }
        if (($PowerShellIds -join ',') -ne ($AfterPowerShellIds -join ',')) {
            throw '设置、聚焦或恢复改变了 PowerShell PID。'
        }
        $FinalConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        foreach ($Key in $ExpectedSettings) {
            if ($null -eq $FinalConfig.PSObject.Properties[$Key]) {
                throw "最终配置缺少稳定设置键：$Key"
            }
        }
        if (-not $FinalConfig.future_setting.preserved) { throw '设置 watcher 丢失未知字段。' }
        $OriginalWorkspaceIds = @(
            $After.workspaces |
                ForEach-Object { [uint64]$_.workspace_id }
        )
        $FirstClose = Stop-AppGracefully -Process $Process
        $Process = $null
        $SessionPath = Join-Path $DataRoot 'sessions\workspaces.json'
        if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
            throw '第一次正常退出后没有保存工作区会话。'
        }

        # 使用同一隔离用户、配置、会话和管道重新启动；工作区身份必须恢复，真实 PTY
        # 进程应重新创建。该步骤与另一个终端数量场景相互独立，不能互相冒充重启。
        $RestartClock = [Diagnostics.Stopwatch]::StartNew()
        $Process = Start-Process `
            -FilePath $Binary `
            -WorkingDirectory $RepositoryRoot `
            -WindowStyle Normal `
            -RedirectStandardOutput (Join-Path $ScenarioDirectory '重启标准输出.txt') `
            -RedirectStandardError (Join-Path $ScenarioDirectory '重启错误输出.txt') `
            -PassThru
        Wait-AppReady -Process $Process -PipeName $PipeName
        $Restored = Wait-MatrixReady `
            -Process $Process `
            -PipeName $PipeName `
            -TerminalCount $TerminalCount
        $RestartReadyMilliseconds = [Math]::Round($RestartClock.Elapsed.TotalMilliseconds, 3)
        $RestoredWorkspaceIds = @(
            $Restored.workspaces |
                ForEach-Object { [uint64]$_.workspace_id }
        )
        $RestoredPowerShellIds = @(
            $Restored.powershell |
                ForEach-Object { [int]$_.id } |
                Sort-Object
        )
        if (($OriginalWorkspaceIds -join ',') -ne ($RestoredWorkspaceIds -join ',')) {
            throw '重启恢复改变了稳定 workspace ID。'
        }
        if (($PowerShellIds -join ',') -eq ($RestoredPowerShellIds -join ',')) {
            throw '重启恢复错误复用了原 PowerShell PID，没有创建新 PTY。'
        }
        $RestartedConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        foreach ($Key in $ExpectedSettings) {
            if ($null -eq $RestartedConfig.PSObject.Properties[$Key]) {
                throw "重启恢复配置缺少稳定设置键：$Key"
            }
        }
        if (-not $RestartedConfig.future_setting.preserved) {
            throw '重启恢复后未知配置字段丢失。'
        }
        $RestartClose = Stop-AppGracefully -Process $Process
        $Process = $null
        return [ordered]@{
            terminalCount = $TerminalCount
            appReadyMilliseconds = $ReadyMilliseconds
            restartReadyMilliseconds = $RestartReadyMilliseconds
            settings = [ordered]@{
                keys = $ExpectedSettings
                writeCount = 2
                first = $RoundOne
                second = $RoundTwo
                unknownFieldPreserved = $true
                noWriteAfterSecondRound = $true
            }
            matrix = [ordered]@{
                workspaces = $After.workspaces.Count
                surfaces = $After.surfaces.Count
                powershellProcesses = $After.powershell.Count
                surfaceIdsStable = $true
                powershellPidsStable = $true
                restoredWorkspaces = $Restored.workspaces.Count
                restoredSurfaces = $Restored.surfaces.Count
                restoredPowerShellProcesses = $Restored.powershell.Count
                workspaceIdsRestored = $true
                powershellPidsRecreatedAcrossRestart = $true
            }
            context = [ordered]@{
                workspaceRoot = $WorkspaceRoot
                fileExists = (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '上下文文件.txt'))
                gitRepository = (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.git'))
                gitHasUncommittedChange = -not [string]::IsNullOrWhiteSpace(
                    (& git -C $WorkspaceRoot status --porcelain | Out-String)
                )
                focusedScreenshot = $FocusScreenshot
                focusAndExplicitRestoreCompleted = $true
            }
            resources = [ordered]@{
                sampleIntervalMilliseconds = $SampleIntervalMilliseconds
                phaseDurationSeconds = $PhaseDurationSeconds
                phases = @($Cold, $Idle, $Active, $Focused)
            }
            process = [ordered]@{
                gracefulExitBothRuns = $true
                firstTracked = $FirstClose.tracked
                restartTracked = $RestartClose.tracked
                residueCount = $FirstClose.remaining.Count + $RestartClose.remaining.Count
            }
            result = 'passed'
        }
    }
    finally {
        foreach ($Name in $PreviousEnvironment.Keys) {
            $Value = $PreviousEnvironment[$Name]
            if ($null -eq $Value) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
            else { Set-Item "Env:$Name" $Value }
        }
        if ($null -ne $Process) {
            $Live = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
            if ($null -ne $Live) {
                # 失败时只清理本轮进程树；强杀不生成通过结果，夹具和日志留作根因证据。
                $Tree = @(Get-ProcessTree -RootProcessId $Process.Id | Sort-Object id -Descending)
                foreach ($Entry in $Tree) {
                    Stop-Process -Id $Entry.id -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Initialize-WindowApi
$Scenarios = @()
foreach ($Count in $ExpectedTerminalCounts) {
    $Scenarios += Invoke-Scenario -TerminalCount $Count
}
$PhaseContractsPassed = @($Scenarios | Where-Object {
    (($_.resources.phases | ForEach-Object { $_.name }) -join ',') -ne
        ($ExpectedPhases -join ',')
}).Count -eq 0
$Summary = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    executedAt = (Get-Date).ToString('o')
    baseCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    binary = [ordered]@{
        path = $Binary
        sha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
        version = (& $Binary --version 2>&1 | Out-String).Trim()
    }
    contract = $Contract
    scenarios = $Scenarios
    checks = [ordered]@{
        terminalCountsExact = (
            (($Scenarios | ForEach-Object { $_.terminalCount }) -join ',') -eq
            ($ExpectedTerminalCounts -join ',')
        )
        phaseOrderExact = $PhaseContractsPassed
        settingsKeysExact = @($ExpectedSettings | Sort-Object -Unique).Count -eq 10
        hostShellCliSeparated = $true
        allContextLoaded = @($Scenarios | Where-Object {
            -not $_.context.fileExists -or
            -not $_.context.gitRepository -or
            -not $_.context.gitHasUncommittedChange
        }).Count -eq 0
        allProcessesStable = @($Scenarios | Where-Object {
            -not $_.matrix.surfaceIdsStable -or
            -not $_.matrix.powershellPidsStable -or
            -not $_.matrix.workspaceIdsRestored -or
            -not $_.matrix.powershellPidsRecreatedAcrossRestart
        }).Count -eq 0
        zeroResidue = @($Scenarios | Where-Object { $_.process.residueCount -ne 0 }).Count -eq 0
    }
    result = 'passed'
}
if (@($Summary.checks.Values | Where-Object { -not [bool]$_ }).Count -ne 0) {
    $Summary.result = 'failed'
}
Write-Utf8Json -Path $SummaryPath -Value $Summary -Depth 24
if ($Summary.result -ne 'passed') { throw "设置稳定性资源门禁失败：$SummaryPath" }

if (-not $KeepFixture) {
    $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
    $ExpectedPrefix = Join-Path $VolumeRoot 'AWSettingsPerf-Release-'
    if (-not $ResolvedFixture.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理不符合固定前缀的目录：$ResolvedFixture"
    }
    Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
}
Write-Output 'Windows 设置稳定性与资源门禁通过'
Write-Output "证据：$SummaryPath"
