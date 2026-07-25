<#
.SYNOPSIS
运行 AgentWorkspace 十项稳定设置的真实 Windows Release 组合持久化验收。

.DESCRIPTION
脚本使用隔离 USERPROFILE、唯一命名管道、真实 AgentWorkspace GUI 与 PowerShell/ConPTY。
它先写入一次已知初始配置，随后只观察设置页产生的两轮真实写入；脚本不会直接写入两轮
目标值冒充 UI 操作。每轮均记录十个磁盘键、工作区与 Surface ID、PowerShell PID，
最后正常关闭并重启，核对第二轮值和未知字段仍然存在。

正常模式启动后会在证据目录生成“01-第一轮目标.json”和“02-第二轮目标.json”，并等待
设置页完成对应修改。A005 的自动化驱动或人工复跑者应在 TimeoutSeconds 内完成每轮操作。

.PARAMETER BinaryPath
待验收的 Release agent-workspace.exe。SelfCheck 模式也会校验该文件，以避免正式运行时
才发现路径或产品身份错误。

.PARAMETER OutputDirectory
保存运行结果、配置快照、目标值和日志的目录。每次运行会创建独立时间戳子目录。

.PARAMETER TimeoutSeconds
每轮等待设置页落盘的最长时间。默认 600 秒；轮询间隔固定为 200 毫秒，仅限验收进程。

.PARAMETER SelfCheck
只检查平台、参数、二进制、输出路径、十键契约和隔离路径，不启动 GUI、不创建证据目录。

.PARAMETER KeepFixture
成功后保留仓库外的隔离用户与工作区夹具，便于诊断；默认安全删除固定前缀目录。

.EXAMPLE
pwsh -NoProfile -File .\scripts\运行Windows十项设置组合验收.ps1 `
  -SelfCheck -BinaryPath .\target\release\agent-workspace.exe

.EXAMPLE
pwsh -NoProfile -File .\scripts\运行Windows十项设置组合验收.ps1 `
  -BinaryPath .\target\release\agent-workspace.exe `
  -OutputDirectory .\docs\验收\十项设置组合数据
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\十项设置组合数据'),

    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,

    [switch]$SelfCheck,

    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ExpectedKeys = @(
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

# 两轮值刻意交叉选择不同生命周期：主题、字体和密度即时生效；Shell 与命令只影响
# 后续启动；引用格式与 Git 策略只影响后续创建的工作区。
$RoundOneExpected = [ordered]@{
    theme_mode = 'dark'
    theme = 'Claude'
    font_family = 'Consolas'
    font_size = 14.0
    default_shell = 'powershell.exe'
    default_reference_format = 'claude'
    workspace_grid_density = 'compact'
    git_auto_init = $false
    claude_code_command = 'claude --model sonnet'
    codex_command = 'codex --sandbox workspace-write'
}
$RoundTwoExpected = [ordered]@{
    theme_mode = 'light'
    theme = 'Cursor'
    font_family = 'Cascadia Mono'
    font_size = 15.0
    default_shell = 'pwsh.exe'
    default_reference_format = 'codex'
    workspace_grid_density = 'comfortable'
    git_auto_init = $true
    claude_code_command = 'claude --model opus'
    codex_command = 'codex --sandbox read-only'
}

function Resolve-AcceptanceBinary {
    <# 校验 Release 二进制路径与公开产品身份，避免误验旧 Paneflow 程序。 #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Release 二进制不存在：$Path"
    }
    $Resolved = (Resolve-Path -LiteralPath $Path).Path
    if ([IO.Path]::GetFileName($Resolved) -ne 'agent-workspace.exe') {
        throw "二进制文件名必须是 agent-workspace.exe：$Resolved"
    }
    $Version = @(& $Resolved --version 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or
        -not (($Version -join "`n").Contains('agent-workspace'))) {
        throw "二进制版本输出没有确认 AgentWorkspace 身份：$($Version -join ' ')"
    }
    return $Resolved
}

function Assert-OutputPath {
    <# 输出目录必须可解析，且不得落在本轮稍后会删除的固定夹具前缀中。 #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $Full = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace([IO.Path]::GetPathRoot($Full))) {
        throw "输出目录不是绝对可解析路径：$Path"
    }
    if ($Full -match '[\\/]AWStableSettings-Release-') {
        throw "输出目录不得位于临时夹具内：$Full"
    }
    return $Full
}

function ConvertTo-StableSettings {
    <# 从真实配置对象提取十个稳定键；缺失键保留为 null，防止遗漏被误判成默认值。 #>
    param([Parameter(Mandatory = $true)][object]$Config)

    $Snapshot = [ordered]@{}
    foreach ($Key in $ExpectedKeys) {
        $Property = $Config.PSObject.Properties[$Key]
        $Snapshot[$Key] = if ($null -eq $Property) { $null } else { $Property.Value }
    }
    return $Snapshot
}

function Test-ExpectedSettings {
    <# 精确比较目标轮次；数值统一按 double 比较，其余值按 JSON 标量语义比较。 #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Expected
    )

    foreach ($Key in $Expected.Keys) {
        $Property = $Config.PSObject.Properties[[string]$Key]
        if ($null -eq $Property) { return $false }
        $Actual = $Property.Value
        $Wanted = $Expected[$Key]
        if ($Wanted -is [double] -or $Wanted -is [single] -or $Wanted -is [decimal]) {
            if ([double]$Actual -ne [double]$Wanted) { return $false }
        }
        elseif ($Actual -ne $Wanted) {
            return $false
        }
    }
    return $true
}

function Write-Utf8Json {
    <# 统一使用无 BOM UTF-8 和尾换行，保证机器证据稳定可比较。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$Depth = 12
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth $Depth) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

$Binary = Resolve-AcceptanceBinary -Path $BinaryPath
$OutputRoot = Assert-OutputPath -Path $OutputDirectory
$VolumeRoot = [IO.Path]::GetPathRoot($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($VolumeRoot)) { throw '无法解析仓库所在卷。' }

$Contract = [ordered]@{
    schemaVersion = 1
    platform = 'windows'
    repositoryRoot = $RepositoryRoot
    binary = $Binary
    outputDirectory = $OutputRoot
    timeoutSeconds = $TimeoutSeconds
    expectedKeys = $ExpectedKeys
    roundOne = $RoundOneExpected
    roundTwo = $RoundTwoExpected
    interactionRule = '初始配置由脚本建立；两轮目标值只能由真实设置页写入。'
}

if ($SelfCheck) {
    if (-not $IsWindows) { throw '十项设置组合验收只支持 Windows。' }
    if ($ExpectedKeys.Count -ne 10 -or @($ExpectedKeys | Sort-Object -Unique).Count -ne 10) {
        throw '十项设置契约必须恰好包含十个唯一磁盘键。'
    }
    if ($RoundOneExpected.Count -ne 10 -or $RoundTwoExpected.Count -ne 10) {
        throw '两轮目标必须分别覆盖全部十个设置键。'
    }
    $Contract.result = 'self-check-passed'
    $Contract | ConvertTo-Json -Depth 8
    return
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Release-$Timestamp"
$EvidenceDirectory = Join-Path $OutputRoot $RunId
$FixtureRoot = Join-Path $VolumeRoot "AWStableSettings-$RunId"
$IsolatedUser = Join-Path $FixtureRoot '隔离用户'
$WorkspaceRoot = Join-Path $FixtureRoot '真实工作区'
$DataRoot = Join-Path $IsolatedUser '.agent-workspace'
$ConfigPath = Join-Path $DataRoot 'config\settings.json'
$SessionPath = Join-Path $DataRoot 'sessions\workspaces.json'
$PipeName = "agent-workspace-stable-settings-$Timestamp"
$PipePath = "\\.\pipe\$PipeName"
$ResultPath = Join-Path $EvidenceDirectory '运行结果.json'

if (Test-Path -LiteralPath $EvidenceDirectory) { throw "证据目录必须全新：$EvidenceDirectory" }
if (Test-Path -LiteralPath $FixtureRoot) { throw "夹具目录必须全新：$FixtureRoot" }
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始验收前存在 AgentWorkspace 进程，无法可靠判断窗口与 PTY 身份。'
}

New-Item -ItemType Directory -Force -Path @(
    $EvidenceDirectory,
    $WorkspaceRoot,
    (Split-Path $ConfigPath -Parent)
) | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $WorkspaceRoot '验收文件.txt'),
    "AgentWorkspace 十项设置组合验收`n",
    [Text.UTF8Encoding]::new($false)
)

# 初始配置是公开的测试前置条件，不是两轮验收结果。future_setting 哨兵用于证明设置页
# 的十次窄写入不会覆盖未知兄弟字段。
$InitialConfig = [ordered]@{
    telemetry = [ordered]@{ enabled = $false }
    theme_mode = 'system'
    theme = $null
    font_family = $null
    font_size = 13.0
    default_shell = $null
    default_reference_format = 'common'
    workspace_grid_density = 'auto'
    git_auto_init = $true
    claude_code_command = $null
    codex_command = $null
    future_setting = [ordered]@{ preserved = $true }
}
Write-Utf8Json -Path $ConfigPath -Value $InitialConfig
Write-Utf8Json -Path (Join-Path $EvidenceDirectory '00-初始目标.json') -Value $InitialConfig
Write-Utf8Json -Path (Join-Path $EvidenceDirectory '01-第一轮目标.json') -Value $RoundOneExpected
Write-Utf8Json -Path (Join-Path $EvidenceDirectory '02-第二轮目标.json') -Value $RoundTwoExpected

function Invoke-AgentWorkspaceRpc {
    <# 每次建立生产命名管道连接并执行一次 JSON-RPC，不绕过 GUI 进程状态。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [object]$Params = @{})

    $Pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $Pipe.Connect(5000)
        $Utf8 = [Text.UTF8Encoding]::new($false)
        $Writer = [IO.StreamWriter]::new($Pipe, $Utf8, 1024, $true)
        $Reader = [IO.StreamReader]::new($Pipe, $Utf8, $false, 1024, $true)
        $Writer.AutoFlush = $true
        $Writer.WriteLine(([ordered]@{
            jsonrpc = '2.0'; method = $Method; params = $Params; id = 1
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

function Wait-AppReady {
    <# 有界等待真实主窗口和 IPC 就绪，不使用固定长等待掩盖启动失败。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { throw "GUI 提前退出，退出码 $($Process.ExitCode)。" }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and
                (Invoke-AgentWorkspaceRpc -Method 'system.ping').pong) { return }
        }
        catch {
            if ($Process.HasExited) { throw }
        }
        Start-Sleep -Milliseconds 200
    }
    throw '真实 AgentWorkspace 在 20 秒内未就绪。'
}

function Start-TestApp {
    <# 启动真实桌面程序，并把本阶段输出保存到证据目录。 #>
    param([Parameter(Mandatory = $true)][string]$Phase)

    $Started = Start-Process `
        -FilePath $Binary `
        -WorkingDirectory $RepositoryRoot `
        -WindowStyle Normal `
        -RedirectStandardOutput (Join-Path $EvidenceDirectory "$Phase-标准输出.txt") `
        -RedirectStandardError (Join-Path $EvidenceDirectory "$Phase-错误输出.txt") `
        -PassThru
    Wait-AppReady -Process $Started
    return $Started
}

function Get-ProcessTree {
    <# 返回根进程与全部实时后代，保存启动时刻以排除 PID 复用。 #>
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

function Get-LifecycleSnapshot {
    <# 记录设置切换前后的窗口、工作区、Surface 与真实 PowerShell 身份。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Process.Refresh()
    $Workspaces = @((Invoke-AgentWorkspaceRpc -Method 'workspace.list').workspaces | Sort-Object index)
    $Surfaces = @(
        (Invoke-AgentWorkspaceRpc -Method 'surface.list').surfaces |
            Where-Object { $_.scope -eq 'workspace' } |
            Sort-Object surface_id
    )
    $Tree = @(Get-ProcessTree -RootProcessId $Process.Id)
    return [ordered]@{
        windowHandle = $Process.MainWindowHandle.ToInt64()
        appPid = $Process.Id
        workspaceIds = @($Workspaces | ForEach-Object { [uint64]$_.id })
        surfaceIds = @($Surfaces | ForEach-Object { [uint64]$_.surface_id })
        powershellPids = @(
            $Tree |
                Where-Object { $_.name -in @('pwsh', 'powershell') } |
                ForEach-Object { [int]$_.id }
        )
        processTree = $Tree
    }
}

function Wait-SettingsRound {
    <# 只观察设置页落盘结果；本函数绝不写配置，因此不能伪造 UI 操作。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Expected
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $LastParseError = $null
    while ([DateTime]::UtcNow -lt $Deadline) {
        try {
            $Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
            if (Test-ExpectedSettings -Config $Config -Expected $Expected) {
                if (-not $Config.future_setting.preserved) {
                    throw "$Label 完成时未知字段已丢失。"
                }
                return $Config
            }
        }
        catch {
            $LastParseError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 200
    }
    $Actual = if (Test-Path -LiteralPath $ConfigPath) {
        Get-Content -Raw -LiteralPath $ConfigPath
    } else {
        '<missing>'
    }
    throw "$Label 在 $TimeoutSeconds 秒内未由设置页完整落盘。最后解析错误：$LastParseError；实际配置：$Actual"
}

function Assert-LifecycleIdentity {
    <# 即时设置不得替换当前窗口、工作区、Surface 或 PowerShell 进程。 #>
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Before,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$After,
        [Parameter(Mandatory = $true)][string]$Label
    )

    foreach ($Key in @('windowHandle', 'appPid')) {
        if ($Before[$Key] -ne $After[$Key]) { throw "$Label 改变了 $Key。" }
    }
    foreach ($Key in @('workspaceIds', 'surfaceIds', 'powershellPids')) {
        if (($Before[$Key] -join ',') -ne ($After[$Key] -join ',')) {
            throw "$Label 改变了 $Key：$($Before[$Key] -join ',') -> $($After[$Key] -join ',')"
        }
    }
}

function Stop-TestAppGracefully {
    <# 正常关闭真实窗口并要求完整进程树归零；强杀只用于 finally 清理，不计为通过。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) { throw '真实 GUI 没有接受正常关闭请求。' }
    if (-not $Process.WaitForExit(15000)) { throw '真实 GUI 正常关闭 15 秒后仍未退出。' }
    if ($Process.ExitCode -ne 0) { throw "真实 GUI 正常关闭退出码为 $($Process.ExitCode)。" }
    for ($Attempt = 0; $Attempt -lt 80; $Attempt++) {
        $Remaining = @(foreach ($Entry in $Tracked) {
            $Live = Get-Process -Id $Entry.id -ErrorAction SilentlyContinue
            if ($null -ne $Live -and
                $Live.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) { $Entry }
        })
        if ($Remaining.Count -eq 0) { return $Tracked }
        Start-Sleep -Milliseconds 100
    }
    throw "正常关闭后仍有进程残留：$($Remaining | ConvertTo-Json -Compress)"
}

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

    $Process = Start-TestApp -Phase '01-两轮设置'
    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'Stable Settings'
        cwd = $WorkspaceRoot
    } | Out-Null

    $InitialLifecycle = $null
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $Candidate = Get-LifecycleSnapshot -Process $Process
        if ($Candidate.workspaceIds.Count -eq 1 -and
            $Candidate.surfaceIds.Count -eq 1 -and
            $Candidate.powershellPids.Count -eq 1) {
            $InitialLifecycle = $Candidate
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $InitialLifecycle) { throw '真实工作区、Surface 与 PowerShell 未在 10 秒内就绪。' }

    $InitialRead = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    Write-Utf8Json -Path (Join-Path $EvidenceDirectory '00-初始实际.json') `
        -Value (ConvertTo-StableSettings -Config $InitialRead)

    Write-Output "第一轮目标：$(Join-Path $EvidenceDirectory '01-第一轮目标.json')"
    $RoundOneConfig = Wait-SettingsRound -Label '第一轮' -Expected $RoundOneExpected
    $RoundOneLifecycle = Get-LifecycleSnapshot -Process $Process
    Assert-LifecycleIdentity -Before $InitialLifecycle -After $RoundOneLifecycle -Label '第一轮即时设置'
    Write-Utf8Json -Path (Join-Path $EvidenceDirectory '01-第一轮实际.json') `
        -Value (ConvertTo-StableSettings -Config $RoundOneConfig)

    Write-Output "第二轮目标：$(Join-Path $EvidenceDirectory '02-第二轮目标.json')"
    $RoundTwoConfig = Wait-SettingsRound -Label '第二轮' -Expected $RoundTwoExpected
    $RoundTwoLifecycle = Get-LifecycleSnapshot -Process $Process
    Assert-LifecycleIdentity -Before $RoundOneLifecycle -After $RoundTwoLifecycle -Label '第二轮即时设置'
    Write-Utf8Json -Path (Join-Path $EvidenceDirectory '02-第二轮实际.json') `
        -Value (ConvertTo-StableSettings -Config $RoundTwoConfig)

    $FirstTree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null
    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        throw '首次正常退出后没有保存工作区会话。'
    }
    Copy-Item -LiteralPath $SessionPath -Destination (Join-Path $EvidenceDirectory '02-退出会话.json')

    $Process = Start-TestApp -Phase '02-重启恢复'
    $RestoredConfig = Wait-SettingsRound -Label '重启恢复' -Expected $RoundTwoExpected
    $RestoredLifecycle = $null
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $Candidate = Get-LifecycleSnapshot -Process $Process
        if ($Candidate.workspaceIds.Count -eq 1 -and
            $Candidate.surfaceIds.Count -eq 1 -and
            $Candidate.powershellPids.Count -eq 1) {
            $RestoredLifecycle = $Candidate
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $RestoredLifecycle) { throw '重启后工作区与 PTY 未在 10 秒内恢复。' }
    Write-Utf8Json -Path (Join-Path $EvidenceDirectory '03-重启实际.json') `
        -Value (ConvertTo-StableSettings -Config $RestoredConfig)
    $SecondTree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null

    $Result = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        executedAt = (Get-Date).ToString('o')
        baseCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
        binary = [ordered]@{
            path = $Binary
            sha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
            version = (& $Binary --version 2>&1 | Out-String).Trim()
        }
        isolation = [ordered]@{
            userProfile = $IsolatedUser
            dataRoot = $DataRoot
            workspaceRoot = $WorkspaceRoot
            pipe = $PipePath
        }
        settings = [ordered]@{
            keys = $ExpectedKeys
            initial = ConvertTo-StableSettings -Config $InitialRead
            roundOne = ConvertTo-StableSettings -Config $RoundOneConfig
            roundTwo = ConvertTo-StableSettings -Config $RoundTwoConfig
            restored = ConvertTo-StableSettings -Config $RestoredConfig
            unknownFieldPreserved = $true
        }
        lifecycle = [ordered]@{
            initial = $InitialLifecycle
            roundOne = $RoundOneLifecycle
            roundTwo = $RoundTwoLifecycle
            restored = $RestoredLifecycle
            currentIdentityPreservedAcrossBothRounds = $true
            firstTrackedProcesses = $FirstTree
            restoredTrackedProcesses = $SecondTree
            gracefulExitBothRuns = $true
            residueCount = 0
        }
        result = 'passed'
    }
    Write-Utf8Json -Path $ResultPath -Value $Result -Depth 16

    if (-not $KeepFixture) {
        $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
        $ExpectedPrefix = Join-Path $VolumeRoot 'AWStableSettings-Release-'
        if (-not $ResolvedFixture.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理不符合固定前缀的目录：$ResolvedFixture"
        }
        Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
    }
    Write-Output 'Windows 十项设置组合 Release 验收通过'
    Write-Output "证据：$ResultPath"
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
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            $Process.WaitForExit(5000) | Out-Null
        }
    }
}
