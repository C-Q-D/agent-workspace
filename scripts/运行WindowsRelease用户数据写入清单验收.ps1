<#
.SYNOPSIS
使用真实 Windows Release 生成 AgentWorkspace 用户数据写入清单。

.DESCRIPTION
脚本通过隔离 USERPROFILE、唯一命名管道、真实桌面进程、PowerShell/ConPTY
和本地 Git 执行一次完整启动、工作区创建与正常退出。验收只允许隔离用户目录
下的 .agent-workspace 和用户主动选择的工作区发生预期变化，并证明开发者数据、
旧 Paneflow 数据与外部哨兵不变。失败后的强制终止只负责保护测试环境，不计为通过。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\Windows用户数据边界数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Release-$Timestamp"
$EvidenceDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $RunId
# 夹具必须位于源码仓库之外，否则生产 Git 生命周期会正确复用上层仓库，
# 无法验证非 Git 目录的本地初始化。使用仓库所在卷根可避免跨卷路径差异。
$RepositoryVolumeRoot = [IO.Path]::GetPathRoot($RepositoryRoot)
$FixtureRoot = Join-Path $RepositoryVolumeRoot "AWUserDataBoundary-$RunId"
$IsolatedUser = Join-Path $FixtureRoot '隔离用户'
$UserDataRoot = Join-Path $IsolatedUser '.agent-workspace'
$WorkspaceRoot = Join-Path $FixtureRoot '真实工作区'
$LegacyRoot = Join-Path $FixtureRoot '旧Paneflow数据'
$ExternalRoot = Join-Path $FixtureRoot '外部目录'
$LegacySentinel = Join-Path $LegacyRoot '旧数据不得修改.txt'
$ExternalSentinel = Join-Path $ExternalRoot '外部数据不得修改.txt'
$DeveloperDataRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agent-workspace'
$PipeName = "agent-workspace-boundary-$Timestamp"
$PipePath = "\\.\pipe\$PipeName"
$StdoutPath = Join-Path $EvidenceDirectory 'Release标准输出.txt'
$StderrPath = Join-Path $EvidenceDirectory 'Release错误输出.txt'
$ResultPath = Join-Path $EvidenceDirectory '运行结果.json'

if (Test-Path -LiteralPath $EvidenceDirectory) {
    throw "验收证据目录必须是全新目录：$EvidenceDirectory"
}
if (Test-Path -LiteralPath $FixtureRoot) {
    throw "验收夹具目录必须是全新目录：$FixtureRoot"
}
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始验收前存在 AgentWorkspace 进程，无法可靠归属写入和子进程。'
}

New-Item -ItemType Directory -Force -Path @(
    $EvidenceDirectory,
    $IsolatedUser,
    $WorkspaceRoot,
    $LegacyRoot,
    $ExternalRoot,
    (Join-Path $UserDataRoot 'config'),
    (Join-Path $UserDataRoot 'state'),
    (Join-Path $UserDataRoot 'bin')
) | Out-Null

# durable 哨兵使用真实文件，设置文件保持可被生产加载器读取的合法结构。
[IO.File]::WriteAllText(
    (Join-Path $UserDataRoot 'config\settings.json'),
    "{`"telemetry`":{`"enabled`":false}}`n",
    [Text.UTF8Encoding]::new($false)
)
Set-Content -LiteralPath (Join-Path $UserDataRoot 'state\durable-state-sentinel.txt') -Encoding utf8 -Value 'durable-state'
Set-Content -LiteralPath (Join-Path $UserDataRoot 'bin\durable-bin-sentinel.txt') -Encoding utf8 -Value 'durable-bin'
Set-Content -LiteralPath (Join-Path $WorkspaceRoot '真实项目文件.txt') -Encoding utf8 -Value '真实 Release 用户数据边界验收'
Set-Content -LiteralPath $LegacySentinel -Encoding utf8 -Value 'legacy-paneflow-sentinel'
Set-Content -LiteralPath $ExternalSentinel -Encoding utf8 -Value 'external-sentinel'

function Get-DirectoryManifest {
    <# 返回稳定排序的真实目录清单；文件包含字节数和 SHA-256。 #>
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }
    $FullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $FullRoot -Force -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                $Relative = $_.FullName.Substring($FullRoot.Length).TrimStart('\').Replace('\', '/')
                if ($_.PSIsContainer) {
                    [ordered]@{ type = 'directory'; path = $Relative }
                }
                else {
                    [ordered]@{
                        type = 'file'
                        path = $Relative
                        length = $_.Length
                        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            }
    )
}

function Get-DirectoryFingerprint {
    <# 将目录清单序列化为稳定指纹；目录不存在也有明确值。 #>
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return '__ABSENT__'
    }
    return (Get-DirectoryManifest -Root $Root | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentWorkspaceRpc {
    <# 使用本轮唯一生产命名管道执行一次真实 JSON-RPC 调用。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = @{}
    )

    $Pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $Pipe.Connect(5000)
        $Utf8 = [Text.UTF8Encoding]::new($false)
        $Writer = [IO.StreamWriter]::new($Pipe, $Utf8, 1024, $true)
        $Reader = [IO.StreamReader]::new($Pipe, $Utf8, $false, 1024, $true)
        $Writer.AutoFlush = $true
        $Request = [ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 }
        $Writer.WriteLine(($Request | ConvertTo-Json -Depth 12 -Compress))
        $Line = $Reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($Line)) { throw "$Method 返回空响应。" }
        $Response = $Line | ConvertFrom-Json
        if ($Response.PSObject.Properties.Name -contains 'error') {
            throw "$Method 失败：$($Response.error | ConvertTo-Json -Compress)"
        }
        return $Response.result
    }
    finally {
        $Pipe.Dispose()
    }
}

function Wait-AgentWorkspaceReady {
    <# 有界等待真实 Release 完成命名管道初始化。 #>
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        try {
            if ((Invoke-AgentWorkspaceRpc -Method 'system.ping').pong) { return }
        }
        catch {
            # 冷启动期间管道尚未建立属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw '真实 Release 在 30 秒内未就绪。'
}

function Get-ProcessTree {
    <# 返回根进程及其全部实时后代，并保存启动时间以防 PID 复用。 #>
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
    return @(
        $Seen | Sort-Object | ForEach-Object {
            $Live = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($null -ne $Live) {
                [ordered]@{
                    id = [int]$Live.Id
                    name = [string]$Live.ProcessName
                    startedUtcTicks = $Live.StartTime.ToUniversalTime().Ticks
                }
            }
        }
    )
}

function Stop-TestAppGracefully {
    <# 正常关闭窗口并要求已记录的完整进程树归零；不以强杀替代通过。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) {
        throw '真实 Release 没有接受正常窗口关闭请求。'
    }
    if (-not $Process.WaitForExit(15000)) {
        throw '真实 Release 在正常关闭后 15 秒仍未退出。'
    }
    $Remaining = @()
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $Remaining = @(
            foreach ($Entry in $Tracked) {
                $Live = Get-Process -Id $Entry.id -ErrorAction SilentlyContinue
                if ($null -ne $Live -and $Live.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) {
                    $Entry
                }
            }
        )
        if ($Remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($Remaining.Count -ne 0) {
        throw "正常关闭后仍有残留进程：$(@($Remaining | ForEach-Object { $_.name + ':' + $_.id }) -join ', ')"
    }
    return $Tracked
}

$DeveloperFingerprintBefore = Get-DirectoryFingerprint -Root $DeveloperDataRoot
$DurablePaths = @(
    (Join-Path $UserDataRoot 'config\settings.json'),
    (Join-Path $UserDataRoot 'state\durable-state-sentinel.txt'),
    (Join-Path $UserDataRoot 'bin\durable-bin-sentinel.txt')
)
$DurableHashesBefore = [ordered]@{}
foreach ($Path in $DurablePaths) {
    $DurableHashesBefore[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$LegacyHashBefore = (Get-FileHash -LiteralPath $LegacySentinel -Algorithm SHA256).Hash.ToLowerInvariant()
$ExternalHashBefore = (Get-FileHash -LiteralPath $ExternalSentinel -Algorithm SHA256).Hash.ToLowerInvariant()
$UserManifestBefore = @(Get-DirectoryManifest -Root $IsolatedUser)
$Process = $null
$TrackedProcesses = @()
$PreviousEnvironment = [ordered]@{
    USERPROFILE = $env:USERPROFILE
    HOME = $env:HOME
    PANEFLOW_SOCKET_PATH = $env:PANEFLOW_SOCKET_PATH
    PANEFLOW_IPC_SCRIPTING = $env:PANEFLOW_IPC_SCRIPTING
    PANEFLOW_NO_TELEMETRY = $env:PANEFLOW_NO_TELEMETRY
}

try {
    $env:USERPROFILE = $IsolatedUser
    $env:HOME = $IsolatedUser
    $env:PANEFLOW_SOCKET_PATH = $PipePath
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $env:PANEFLOW_NO_TELEMETRY = '1'

    $Process = Start-Process `
        -FilePath $Binary `
        -WorkingDirectory $WorkspaceRoot `
        -WindowStyle Normal `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -PassThru
    Wait-AgentWorkspaceReady

    $Created = Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'Release 数据边界工作区'
        cwd = $WorkspaceRoot
    }
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $Workspaces = @((Invoke-AgentWorkspaceRpc -Method 'workspace.list').workspaces)
        $Surfaces = @((Invoke-AgentWorkspaceRpc -Method 'surface.list').surfaces | Where-Object { $_.scope -eq 'workspace' })
        if ($Workspaces.Count -eq 1 -and $Surfaces.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.git'))) {
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($Workspaces.Count -ne 1 -or $Surfaces.Count -ne 1) {
        throw '真实 Release 没有创建唯一工作区和终端。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.git') -PathType Container)) {
        throw '真实 Release 没有为非 Git 工作区执行本地初始化。'
    }
    $TrackedProcesses = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null

    foreach ($Path in $DurablePaths) {
        $AfterHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($AfterHash -ne $DurableHashesBefore[$Path]) {
            throw "真实 Release 修改了 durable 哨兵：$Path"
        }
    }
    if ((Get-FileHash -LiteralPath $LegacySentinel -Algorithm SHA256).Hash.ToLowerInvariant() -ne $LegacyHashBefore) {
        throw '真实 Release 修改了旧 Paneflow 数据哨兵。'
    }
    if ((Get-FileHash -LiteralPath $ExternalSentinel -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExternalHashBefore) {
        throw '真实 Release 修改了外部目录哨兵。'
    }
    if ((Get-DirectoryFingerprint -Root $DeveloperDataRoot) -ne $DeveloperFingerprintBefore) {
        throw '真实 Release 修改了开发者现有 .agent-workspace。'
    }

    $UnexpectedProfileEntries = @(
        Get-ChildItem -LiteralPath $IsolatedUser -Force |
            Where-Object { $_.Name -notin @('.agent-workspace', 'AppData') }
    )
    if ($UnexpectedProfileEntries.Count -ne 0) {
        throw "隔离用户目录出现契约外顶层条目：$($UnexpectedProfileEntries.Name -join ', ')"
    }
    $UnexpectedAppDataEntries = @(
        Get-ChildItem -LiteralPath (Join-Path $IsolatedUser 'AppData') -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.FullName.StartsWith(
                    (Join-Path $IsolatedUser 'AppData\Local\Microsoft\PowerShell'),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                $_.FullName -notin @(
                    (Join-Path $IsolatedUser 'AppData\Local'),
                    (Join-Path $IsolatedUser 'AppData\Local\Microsoft')
                )
            }
    )
    if ($UnexpectedAppDataEntries.Count -ne 0) {
        throw "隔离 AppData 出现 PowerShell 运行时之外的写入：$($UnexpectedAppDataEntries.FullName -join ', ')"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $UserDataRoot 'sessions\workspaces.json') -PathType Leaf)) {
        throw '正常退出后没有写入统一 sessions/workspaces.json。'
    }

    $UserManifestAfter = @(Get-DirectoryManifest -Root $IsolatedUser)
    $AgentWorkspaceManifest = @(
        $UserManifestAfter | Where-Object { $_.path -eq '.agent-workspace' -or $_.path.StartsWith('.agent-workspace/') }
    )
    $PowerShellRuntimeManifest = @(
        $UserManifestAfter | Where-Object { $_.path -eq 'AppData' -or $_.path.StartsWith('AppData/') }
    )
    $WorkspaceManifestAfter = @(Get-DirectoryManifest -Root $WorkspaceRoot)
    # 证据已经包含完整清单和哈希，成功后清除仓库外夹具，避免重复验收积累用户目录。
    # 删除前同时核对卷根和固定前缀；失败路径不执行这里，因此仍会保留现场。
    $ExpectedFixturePrefix = Join-Path $RepositoryVolumeRoot 'AWUserDataBoundary-Release-'
    $ResolvedFixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
    if (-not $ResolvedFixtureRoot.StartsWith($ExpectedFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理不符合验收前缀的目录：$ResolvedFixtureRoot"
    }
    Remove-Item -LiteralPath $ResolvedFixtureRoot -Recurse -Force
    if (Test-Path -LiteralPath $ResolvedFixtureRoot) {
        throw "成功验收后夹具目录仍存在：$ResolvedFixtureRoot"
    }

    $Result = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        executedAt = (Get-Date).ToString('o')
        baseCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
        binary = [ordered]@{
            path = $Binary
            length = (Get-Item -LiteralPath $Binary).Length
            sha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        isolation = [ordered]@{
            userProfile = $IsolatedUser
            expectedDataRoot = $UserDataRoot
            onlyExpectedProfileRootsWritten = $true
            developerDataFingerprintPreserved = $true
            uniquePipe = $PipePath
        }
        workspace = [ordered]@{
            path = $WorkspaceRoot
            index = [int]$Created.index
            gitInitialized = $true
            manifest = $WorkspaceManifestAfter
        }
        data = [ordered]@{
            before = $UserManifestBefore
            after = $UserManifestAfter
            agentWorkspace = $AgentWorkspaceManifest
            externalPowerShellRuntime = $PowerShellRuntimeManifest
            durableSentinelsPreserved = $true
            sessionWritten = $true
        }
        boundaries = [ordered]@{
            legacyPaneflowSentinelPreserved = $true
            externalSentinelPreserved = $true
        }
        process = [ordered]@{
            tracked = $TrackedProcesses
            gracefulExit = $true
            residueCount = 0
        }
        cleanup = [ordered]@{
            fixtureRemoved = $true
        }
        result = 'passed'
    }
    $Utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 12) + "`n", $Utf8NoBom)

    Write-Output 'Windows Release 用户数据写入清单验收通过'
    Write-Output "隔离数据根：$UserDataRoot"
    Write-Output "真实工作区：$WorkspaceRoot"
    Write-Output "证据：$ResultPath"
}
finally {
    foreach ($Name in $PreviousEnvironment.Keys) {
        $Value = $PreviousEnvironment[$Name]
        if ($null -eq $Value) {
            Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item "Env:$Name" $Value
        }
    }
    if ($null -ne $Process) {
        $Live = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if ($null -ne $Live) {
            # 仅在验收失败或异常中断后保护测试环境；此路径不会生成通过结果。
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
