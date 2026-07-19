<#
.SYNOPSIS
在同一真实 Windows 用户下联合验证 AgentWorkspace 安装版与便携版的数据边界。

.DESCRIPTION
脚本安装真实 MSI、解压真实便携 ZIP，并让两种发行形态依次读取和写入同一个
`.agent-workspace`。验收覆盖会话互认、两次缓存删除与重建、便携目录只读、
便携目录删除和 MSI 卸载后的 durable 数据保留。失败时保留现场，不自动重试。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$MsiPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ZipPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\target\distribution-data-boundary')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Msi = (Resolve-Path -LiteralPath $MsiPath).Path
$Zip = (Resolve-Path -LiteralPath $ZipPath).Path
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Distribution-$Timestamp"
$EvidenceDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $RunId
$RepositoryVolumeRoot = [IO.Path]::GetPathRoot($RepositoryRoot)
$FixtureRoot = Join-Path $RepositoryVolumeRoot "AWDistributionBoundary-$RunId"
$IsolatedUser = Join-Path $FixtureRoot '隔离用户'
$UserDataRoot = Join-Path $IsolatedUser '.agent-workspace'
$CacheRoot = Join-Path $UserDataRoot 'cache'
$WorkspaceA = Join-Path $FixtureRoot '安装版工作区'
$WorkspaceB = Join-Path $FixtureRoot '便携版工作区'
$PortableExtractRoot = Join-Path $FixtureRoot '便携程序'
$InstallDirectory = Join-Path $env:ProgramFiles 'AgentWorkspace'
$InstalledExecutable = Join-Path $InstallDirectory 'agent-workspace.exe'
$ResultPath = Join-Path $EvidenceDirectory '运行结果.json'

function Assert-ElevatedAndUninstalled {
    <# 验收只在管理员且系统无既有同名产品时开始，防止覆盖用户真实安装。 #>
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '安装版与便携版联合验收需要管理员权限。'
    }
    if (@(Get-InstalledAgentWorkspace).Count -ne 0) {
        throw '检测到既有 AgentWorkspace 安装，为保护用户安装已停止验收。'
    }
    if (Test-Path -LiteralPath $InstallDirectory) {
        throw "检测到既有安装目录，为保护用户文件已停止验收：$InstallDirectory"
    }
}

function Get-InstalledAgentWorkspace {
    <# 同时读取 64 位与 32 位卸载注册表视图。 #>
    $Roots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @(
        Get-ItemProperty $Roots -ErrorAction SilentlyContinue |
            Where-Object {
                # 严格模式下注册表项缺少 DisplayName 时不能直接解引用。
                $_.PSObject.Properties.Name -contains 'DisplayName' -and
                $_.DisplayName -eq 'AgentWorkspace'
            }
    )
}

function Get-MsiProperty {
    <# 从真实 Windows Installer Property 表读取产品身份，不依赖文件名。 #>
    param([string]$Path, [string]$Name)
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Database = $null
    $View = $null
    try {
        $Database = $Installer.GetType().InvokeMember(
            'OpenDatabase', [Reflection.BindingFlags]::InvokeMethod, $null, $Installer, @($Path, 0)
        )
        $View = $Database.GetType().InvokeMember(
            'OpenView', [Reflection.BindingFlags]::InvokeMethod, $null, $Database,
            @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
        )
        $View.GetType().InvokeMember(
            'Execute', [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        ) | Out-Null
        $Record = $View.GetType().InvokeMember(
            'Fetch', [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        )
        if ($null -eq $Record) { throw "MSI Property 表缺少 $Name：$Path" }
        return $Record.GetType().InvokeMember(
            'StringData', [Reflection.BindingFlags]::GetProperty, $null, $Record, @(1)
        )
    }
    finally {
        if ($null -ne $View) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($View) }
        if ($null -ne $Database) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Database) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Installer)
    }
}

function Invoke-MsiTransaction {
    <# 执行带完整日志的单次安装或卸载；非零退出码保留现场并立即失败。 #>
    param(
        [ValidateSet('Install', 'Uninstall')][string]$Action,
        [string]$PackageOrProductCode,
        [string]$LogPath
    )
    $Mode = if ($Action -eq 'Install') { '/i' } else { '/x' }
    $Process = Start-Process `
        -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') `
        -ArgumentList @($Mode, ('"{0}"' -f $PackageOrProductCode), '/qn', '/norestart', '/l*v', ('"{0}"' -f $LogPath)) `
        -Wait `
        -PassThru
    if ($Process.ExitCode -ne 0) {
        throw "msiexec $Action 失败，退出码 $($Process.ExitCode)，日志：$LogPath"
    }
    return $Process.ExitCode
}

function Get-DirectoryManifest {
    <# 返回稳定排序的真实目录清单；文件记录长度和 SHA-256。 #>
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
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
    <# 将目录清单序列化为稳定指纹，供删除前后做字节级边界比较。 #>
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '__ABSENT__' }
    return (Get-DirectoryManifest -Root $Root | ConvertTo-Json -Depth 5 -Compress)
}

function Get-DurableDirectoryFingerprints {
    <# 分别记录四个 durable 目录，明确排除允许重建的 cache/ 与诊断 logs/。 #>
    param([string]$DataRoot)
    $Fingerprints = [ordered]@{}
    foreach ($Name in @('config', 'sessions', 'state', 'bin')) {
        $Fingerprints[$Name] = Get-DirectoryFingerprint -Root (Join-Path $DataRoot $Name)
    }
    return $Fingerprints
}

function Assert-DurableDirectoryFingerprints {
    <# 缓存重建不得借机改写任何 durable 目录，包括会话索引和稳定辅助文件。 #>
    param([string]$DataRoot, [object]$Expected, [string]$Stage)
    foreach ($Name in @('config', 'sessions', 'state', 'bin')) {
        $Actual = Get-DirectoryFingerprint -Root (Join-Path $DataRoot $Name)
        if ($Actual -ne $Expected[$Name]) {
            throw "$Stage 修改了 durable 目录：$Name"
        }
    }
}

function New-PreservationSentinel {
    <# 创建不应被发行形态切换或缓存重建修改的稳定 UTF-8 文件。 #>
    param([string]$Category, [string]$Path, [string]$Content)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
    return [ordered]@{
        category = $Category
        path = $Path
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-PreservationSentinels {
    <# 逐项验证 durable 与 diagnostic 哨兵，错误信息保留数据分类。 #>
    param([object[]]$Sentinels, [string]$Stage)
    foreach ($Sentinel in $Sentinels) {
        if (-not (Test-Path -LiteralPath $Sentinel.path -PathType Leaf)) {
            throw "$Stage 哨兵缺失 [$($Sentinel.category)]：$($Sentinel.path)"
        }
        $ActualHash = (Get-FileHash -LiteralPath $Sentinel.path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualHash -ne $Sentinel.sha256) {
            throw "$Stage 哨兵已变化 [$($Sentinel.category)]：$($Sentinel.path)"
        }
    }
}

function Expand-VerifiedPortablePackage {
    <# 校验 sidecar 和 ZIP 路径安全后解压真实便携包。 #>
    param([string]$ArchivePath, [string]$Destination)
    $SidecarPath = "$ArchivePath.sha256"
    if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        throw "便携 ZIP 缺少 SHA-256 sidecar：$SidecarPath"
    }
    $ArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ExpectedSidecar = "$ArchiveHash *$([IO.Path]::GetFileName($ArchivePath))"
    if ([IO.File]::ReadAllText($SidecarPath).Trim() -ne $ExpectedSidecar) {
        throw '便携 ZIP 的 SHA-256 sidecar 与真实文件不一致。'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($Entry in $Archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($Entry.FullName) -or
                $Entry.FullName.Contains('\') -or
                $Entry.FullName.StartsWith('/') -or
                $Entry.FullName.Split('/') -contains '..') {
                throw "便携 ZIP 包含不安全条目：$($Entry.FullName)"
            }
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($Archive, $Destination, $false)
    }
    finally {
        $Archive.Dispose()
    }
    return $ArchiveHash
}

function Invoke-AgentWorkspaceRpc {
    <# 通过指定的唯一生产命名管道执行一次真实 JSON-RPC 调用。 #>
    param([string]$PipeName, [string]$Method, [object]$Params = @{})
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
    <# 有界等待真实桌面进程完成命名管道初始化。 #>
    param([string]$PipeName)
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        try {
            if ((Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'system.ping').pong) { return }
        }
        catch {
            # 冷启动期间管道尚未建立属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw '真实桌面进程在 30 秒内未就绪。'
}

function Get-ProcessTree {
    <# 返回根进程及其全部实时后代，并保存启动时间以防 PID 复用。 #>
    param([int]$RootProcessId)
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
    <# 正常关闭窗口并要求完整进程树归零；强制终止不能作为通过条件。 #>
    param([Diagnostics.Process]$Process)
    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) { throw '真实桌面进程没有接受正常窗口关闭请求。' }
    if (-not $Process.WaitForExit(15000)) { throw '真实桌面进程在正常关闭后 15 秒仍未退出。' }
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

function Invoke-DistributionRun {
    <# 启动指定发行形态，验证既有会话，可选创建工作区，再正常退出并返回运行证据。 #>
    param(
        [string]$Label,
        [string]$Executable,
        [string]$WorkingDirectory,
        [string[]]$ExpectedWorkspaceNames,
        [string]$CreateWorkspaceName,
        [string]$CreateWorkspacePath
    )
    $PipeName = "agent-workspace-distribution-$Timestamp-$($Label -replace '[^A-Za-z0-9]', '')"
    $Stdout = Join-Path $EvidenceDirectory "$Label-标准输出.txt"
    $Stderr = Join-Path $EvidenceDirectory "$Label-错误输出.txt"
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
        $env:PANEFLOW_SOCKET_PATH = "\\.\pipe\$PipeName"
        $env:PANEFLOW_IPC_SCRIPTING = '1'
        $env:PANEFLOW_NO_TELEMETRY = '1'
        $Process = Start-Process `
            -FilePath $Executable `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Normal `
            -RedirectStandardOutput $Stdout `
            -RedirectStandardError $Stderr `
            -PassThru
        Wait-AgentWorkspaceReady -PipeName $PipeName

        $Before = @((Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'workspace.list').workspaces)
        $BeforeNames = @($Before | ForEach-Object title | Sort-Object)
        $ExpectedNames = @($ExpectedWorkspaceNames | Sort-Object)
        if (($BeforeNames -join "`0") -ne ($ExpectedNames -join "`0")) {
            throw "$Label 读取的会话不符合预期：实际 [$($BeforeNames -join ', ')]，预期 [$($ExpectedNames -join ', ')]"
        }

        $CreatedIndex = $null
        if (-not [string]::IsNullOrWhiteSpace($CreateWorkspaceName)) {
            $Created = Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'workspace.create' -Params @{
                name = $CreateWorkspaceName
                cwd = $CreateWorkspacePath
            }
            $CreatedIndex = [int]$Created.index
            $ExpectedAfter = @($ExpectedWorkspaceNames) + @($CreateWorkspaceName)
            for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
                $After = @((Invoke-AgentWorkspaceRpc -PipeName $PipeName -Method 'workspace.list').workspaces)
                $AfterNames = @($After | ForEach-Object title | Sort-Object)
                if (($AfterNames -join "`0") -eq (@($ExpectedAfter | Sort-Object) -join "`0") -and
                    (Test-Path -LiteralPath (Join-Path $CreateWorkspacePath '.git') -PathType Container)) {
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            if (($AfterNames -join "`0") -ne (@($ExpectedAfter | Sort-Object) -join "`0")) {
                throw "$Label 没有建立预期工作区集合。"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $CreateWorkspacePath '.git') -PathType Container)) {
                throw "$Label 没有为非 Git 工作区初始化本地仓库。"
            }
        }
        else {
            $AfterNames = $BeforeNames
        }

        $Tracked = @(Stop-TestAppGracefully -Process $Process)
        $Process = $null
        return [ordered]@{
            label = $Label
            executable = $Executable
            workspacesBefore = $BeforeNames
            workspacesAfter = $AfterNames
            createdIndex = $CreatedIndex
            pipe = "\\.\pipe\$PipeName"
            trackedProcesses = $Tracked
            gracefulExit = $true
            processResidueCount = 0
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
                # 仅在失败路径保护测试环境；强制终止不会生成通过结果。
                Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Assert-ElevatedAndUninstalled
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始验收前存在 AgentWorkspace 进程，无法可靠归属写入。'
}
if ((Get-MsiProperty -Path $Msi -Name 'ProductName') -ne 'AgentWorkspace') {
    throw '测试 MSI 的 ProductName 不是 AgentWorkspace。'
}
if (Test-Path -LiteralPath $EvidenceDirectory) { throw "验收证据目录必须是全新目录：$EvidenceDirectory" }
if (Test-Path -LiteralPath $FixtureRoot) { throw "验收夹具目录必须是全新目录：$FixtureRoot" }

New-Item -ItemType Directory -Force -Path @(
    $EvidenceDirectory,
    $IsolatedUser,
    $WorkspaceA,
    $WorkspaceB,
    (Join-Path $UserDataRoot 'config'),
    (Join-Path $UserDataRoot 'sessions'),
    (Join-Path $UserDataRoot 'state'),
    (Join-Path $UserDataRoot 'bin'),
    (Join-Path $UserDataRoot 'logs')
) | Out-Null

$Sentinels = @(
    New-PreservationSentinel -Category 'config' -Path (Join-Path $UserDataRoot 'config\settings.json') -Content '{"telemetry":{"enabled":false}}'
    New-PreservationSentinel -Category 'sessions' -Path (Join-Path $UserDataRoot 'sessions\durable-session-sentinel.txt') -Content 'durable-session-sentinel'
    New-PreservationSentinel -Category 'state' -Path (Join-Path $UserDataRoot 'state\durable-state-sentinel.txt') -Content 'durable-state-sentinel'
    New-PreservationSentinel -Category 'bin' -Path (Join-Path $UserDataRoot 'bin\durable-bin-sentinel.txt') -Content 'durable-bin-sentinel'
    New-PreservationSentinel -Category 'logs' -Path (Join-Path $UserDataRoot 'logs\diagnostic-log-sentinel.txt') -Content 'diagnostic-log-sentinel'
)
[IO.File]::WriteAllText((Join-Path $WorkspaceA '项目文件.txt'), 'installed-workspace', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $WorkspaceB '项目文件.txt'), 'portable-workspace', [Text.UTF8Encoding]::new($false))

$ZipHash = Expand-VerifiedPortablePackage -ArchivePath $Zip -Destination $PortableExtractRoot
$PackageRoot = Join-Path $PortableExtractRoot 'AgentWorkspace-0.7.11-windows-x64'
$PortableExecutable = Join-Path $PackageRoot 'agent-workspace.exe'
if (-not (Test-Path -LiteralPath $PortableExecutable -PathType Leaf)) {
    throw "便携包缺少主程序：$PortableExecutable"
}
$PortableManifestBefore = @(Get-DirectoryManifest -Root $PackageRoot)
$MsiHash = (Get-FileHash -LiteralPath $Msi -Algorithm SHA256).Hash.ToLowerInvariant()
$InstallLog = Join-Path $EvidenceDirectory '安装.log'
$UninstallLog = Join-Path $EvidenceDirectory '卸载.log'

$InstallExitCode = Invoke-MsiTransaction -Action Install -PackageOrProductCode $Msi -LogPath $InstallLog
$Installed = @(Get-InstalledAgentWorkspace)
if ($Installed.Count -ne 1) { throw 'MSI 安装后没有唯一 AgentWorkspace 产品。' }
if (-not (Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) {
    throw "MSI 安装后缺少主程序：$InstalledExecutable"
}

$RunInstalledCreate = Invoke-DistributionRun `
    -Label '01-installed-create-a' `
    -Executable $InstalledExecutable `
    -WorkingDirectory $WorkspaceA `
    -ExpectedWorkspaceNames @() `
    -CreateWorkspaceName '安装版工作区' `
    -CreateWorkspacePath $WorkspaceA
Assert-PreservationSentinels -Sentinels $Sentinels -Stage '安装版首次运行后'

$RunPortableCreate = Invoke-DistributionRun `
    -Label '02-portable-read-a-create-b' `
    -Executable $PortableExecutable `
    -WorkingDirectory $WorkspaceB `
    -ExpectedWorkspaceNames @('安装版工作区') `
    -CreateWorkspaceName '便携版工作区' `
    -CreateWorkspacePath $WorkspaceB
Assert-PreservationSentinels -Sentinels $Sentinels -Stage '便携版首次运行后'

# 新建 surface 首次恢复时会把隐式 cwd 规范化为显式工作区路径；先在缓存仍存在时
# 完成这一正常会话迁移，再取 durable 指纹，避免把序列化规范化误判为缓存副作用。
$RunInstalledStabilize = Invoke-DistributionRun `
    -Label '03-installed-session-stabilize' `
    -Executable $InstalledExecutable `
    -WorkingDirectory $WorkspaceA `
    -ExpectedWorkspaceNames @('安装版工作区', '便携版工作区') `
    -CreateWorkspaceName '' `
    -CreateWorkspacePath ''
Assert-PreservationSentinels -Sentinels $Sentinels -Stage '会话稳定化后'

$DurableFingerprintsBeforeCache = Get-DurableDirectoryFingerprints -DataRoot $UserDataRoot
$LogsFingerprintBeforeCache = Get-DirectoryFingerprint -Root (Join-Path $UserDataRoot 'logs')
if (Test-Path -LiteralPath $CacheRoot) { Remove-Item -LiteralPath $CacheRoot -Recurse -Force }
$RunInstalledRebuild = Invoke-DistributionRun `
    -Label '04-installed-cache-rebuild' `
    -Executable $InstalledExecutable `
    -WorkingDirectory $WorkspaceA `
    -ExpectedWorkspaceNames @('安装版工作区', '便携版工作区') `
    -CreateWorkspaceName '' `
    -CreateWorkspacePath ''
if (-not (Test-Path -LiteralPath (Join-Path $CacheRoot 'shell\pwsh\osc7.ps1') -PathType Leaf)) {
    throw '安装版没有在 cache/ 下按需重建 PowerShell shell 资产。'
}
$InstalledCacheManifest = @(Get-DirectoryManifest -Root $CacheRoot)
Assert-PreservationSentinels -Sentinels $Sentinels -Stage '安装版缓存重建后'
Assert-DurableDirectoryFingerprints `
    -DataRoot $UserDataRoot `
    -Expected $DurableFingerprintsBeforeCache `
    -Stage '安装版缓存重建后'

if (Test-Path -LiteralPath $CacheRoot) { Remove-Item -LiteralPath $CacheRoot -Recurse -Force }
$RunPortableRebuild = Invoke-DistributionRun `
    -Label '05-portable-cache-rebuild' `
    -Executable $PortableExecutable `
    -WorkingDirectory $WorkspaceB `
    -ExpectedWorkspaceNames @('安装版工作区', '便携版工作区') `
    -CreateWorkspaceName '' `
    -CreateWorkspacePath ''
if (-not (Test-Path -LiteralPath (Join-Path $CacheRoot 'shell\pwsh\osc7.ps1') -PathType Leaf)) {
    throw '便携版没有在 cache/ 下按需重建 PowerShell shell 资产。'
}
$PortableCacheManifest = @(Get-DirectoryManifest -Root $CacheRoot)
Assert-PreservationSentinels -Sentinels $Sentinels -Stage '便携版缓存重建后'
Assert-DurableDirectoryFingerprints `
    -DataRoot $UserDataRoot `
    -Expected $DurableFingerprintsBeforeCache `
    -Stage '便携版缓存重建后'
if ((Get-DirectoryFingerprint -Root (Join-Path $UserDataRoot 'logs')) -ne $LogsFingerprintBeforeCache) {
    throw '缓存重建修改了 logs/ 诊断目录。'
}
if (($InstalledCacheManifest | ConvertTo-Json -Depth 5 -Compress) -ne
    ($PortableCacheManifest | ConvertTo-Json -Depth 5 -Compress)) {
    throw '安装版与便携版重建出的缓存清单不一致。'
}

$PortableManifestAfter = @(Get-DirectoryManifest -Root $PackageRoot)
if (($PortableManifestBefore | ConvertTo-Json -Depth 5 -Compress) -ne
    ($PortableManifestAfter | ConvertTo-Json -Depth 5 -Compress)) {
    throw '便携版运行修改了便携程序目录。'
}
if (Test-Path -LiteralPath (Join-Path $PackageRoot '.agent-workspace')) {
    throw '便携版错误地在程序目录创建了隐藏用户状态。'
}
$UserFingerprintBeforePortableDelete = Get-DirectoryFingerprint -Root $UserDataRoot
Remove-Item -LiteralPath $PortableExtractRoot -Recurse -Force
if (Test-Path -LiteralPath $PortableExtractRoot) { throw '便携程序目录删除后仍然存在。' }
if ((Get-DirectoryFingerprint -Root $UserDataRoot) -ne $UserFingerprintBeforePortableDelete) {
    throw '删除便携程序目录影响了统一用户数据。'
}

$ProductCode = [string]$Installed[0].PSChildName
$UserFingerprintBeforeUninstall = Get-DirectoryFingerprint -Root $UserDataRoot
$UninstallExitCode = Invoke-MsiTransaction -Action Uninstall -PackageOrProductCode $ProductCode -LogPath $UninstallLog
if (@(Get-InstalledAgentWorkspace).Count -ne 0) { throw 'MSI 卸载后仍有 AgentWorkspace 产品注册。' }
if (Test-Path -LiteralPath $InstallDirectory) { throw 'MSI 卸载后安装目录仍然存在。' }
if ((Get-DirectoryFingerprint -Root $UserDataRoot) -ne $UserFingerprintBeforeUninstall) {
    throw 'MSI 卸载影响了统一用户数据。'
}
Assert-PreservationSentinels -Sentinels $Sentinels -Stage 'MSI 卸载后'
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '联合验收结束后仍有 AgentWorkspace 进程残留。'
}

$UserManifest = @(Get-DirectoryManifest -Root $UserDataRoot)
$ExpectedFixturePrefix = Join-Path $RepositoryVolumeRoot 'AWDistributionBoundary-Distribution-'
$ResolvedFixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
if (-not $ResolvedFixtureRoot.StartsWith($ExpectedFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝清理不符合联合验收前缀的目录：$ResolvedFixtureRoot"
}
Remove-Item -LiteralPath $ResolvedFixtureRoot -Recurse -Force
if (Test-Path -LiteralPath $ResolvedFixtureRoot) { throw '成功验收后夹具目录仍然存在。' }

$Result = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    executedAt = (Get-Date).ToString('o')
    baseCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    packages = [ordered]@{
        msi = [ordered]@{ path = $Msi; sha256 = $MsiHash; productCode = $ProductCode }
        portable = [ordered]@{ path = $Zip; sha256 = $ZipHash; packageFileCount = @($PortableManifestBefore | Where-Object type -eq 'file').Count }
    }
    dataContract = [ordered]@{
        userProfile = $IsolatedUser
        dataRoot = $UserDataRoot
        sharedByInstalledAndPortable = $true
        durableSentinels = $Sentinels
        userManifest = $UserManifest
        logsPreservedDuringCacheRebuild = $true
        durableDirectoriesPreservedDuringCacheRebuild = $true
    }
    runs = @(
        $RunInstalledCreate,
        $RunPortableCreate,
        $RunInstalledStabilize,
        $RunInstalledRebuild,
        $RunPortableRebuild
    )
    cache = [ordered]@{
        installedRebuilt = $true
        portableRebuilt = $true
        installedManifest = $InstalledCacheManifest
        portableManifest = $PortableCacheManifest
    }
    portableBoundary = [ordered]@{
        packageManifestPreserved = $true
        hiddenUserStateCreatedInPackage = $false
        directoryRemoved = $true
        userDataPreservedAfterDirectoryRemoval = $true
    }
    installerBoundary = [ordered]@{
        installExitCode = $InstallExitCode
        uninstallExitCode = $UninstallExitCode
        installDirectoryRemoved = $true
        registryRemoved = $true
        userDataPreservedAfterUninstall = $true
        installLog = $InstallLog
        uninstallLog = $UninstallLog
    }
    process = [ordered]@{ residueCount = 0 }
    cleanup = [ordered]@{ fixtureRemoved = $true }
    result = 'passed'
}
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
Write-Output 'Windows 安装版与便携版联合数据边界验收通过'
Write-Output "共享数据根：$UserDataRoot"
Write-Output "五次真实桌面运行均正常退出，进程残留：0"
Write-Output "证据：$ResultPath"
