# 在真实 Windows Installer 上验证 AgentWorkspace MSI 的准备、安装、升级与卸载边界。
# -PrepareOnly 检查既有安装、生成低版本/当前版本 MSI，并读取真实 MSI 数据库；
# -InstallAndUpgrade 使用准备结果执行初装和 MajorUpgrade；
# -Uninstall 消费安装升级结果，执行卸载并验证应用资源与用户数据边界。
[CmdletBinding()]
param(
    [switch]$PrepareOnly,
    [switch]$InstallAndUpgrade,
    [switch]$Uninstall,
    [string]$PreviousVersion = "0.7.10",
    [string]$CurrentVersion = "0.7.11",
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot "target\msi-lifecycle"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Assert-Elevated {
    # perMachine MSI 的安装与卸载都必须由提升权限的 Windows 进程执行。
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "MSI 生命周期验收需要管理员权限"
    }
}

function Assert-ElevatedAndUninstalled {
    # 准备和初装前除检查权限外，还要拒绝覆盖任何不属于本次验收的既有产品。
    Assert-Elevated

    $UninstallRoots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $Existing = @(
        Get-ItemProperty $UninstallRoots -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq "AgentWorkspace" }
    )
    if ($Existing.Count -gt 0) {
        $Versions = @($Existing | ForEach-Object { $_.DisplayVersion }) -join ", "
        throw "检测到既有 AgentWorkspace 安装（$Versions），为保护用户安装已停止验收"
    }

    $InstallDirectory = Join-Path $env:ProgramFiles "AgentWorkspace"
    if (Test-Path -LiteralPath $InstallDirectory) {
        throw "检测到既有安装目录，为保护用户文件已停止验收：$InstallDirectory"
    }
}

function Get-MsiProperty {
    # 通过 Windows Installer COM 读取 Property 表，不根据文件名推断产品身份。
    param([string]$Path, [string]$Name)
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Database = $null
    $View = $null
    try {
        # PowerShell 7 将 WindowsInstaller 自动化接口暴露为 IDispatch；
        # 必须显式 InvokeMember，直接调用会得到 OpenDatabase 参数绑定错误。
        $Database = $Installer.GetType().InvokeMember(
            "OpenDatabase", [Reflection.BindingFlags]::InvokeMethod, $null, $Installer, @($Path, 0)
        )
        $View = $Database.GetType().InvokeMember(
            "OpenView", [Reflection.BindingFlags]::InvokeMethod, $null, $Database,
            @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
        )
        $View.GetType().InvokeMember(
            "Execute", [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        ) | Out-Null
        $Record = $View.GetType().InvokeMember(
            "Fetch", [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        )
        if ($null -eq $Record) { throw "MSI Property 表缺少 $Name：$Path" }
        return $Record.GetType().InvokeMember(
            "StringData", [Reflection.BindingFlags]::GetProperty, $null, $Record, @(1)
        )
    }
    finally {
        if ($null -ne $View) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($View) }
        if ($null -ne $Database) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Database) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Installer)
    }
}

function Get-MsiFileNames {
    # 读取 File 表的长文件名；WiX 可能同时保存 8.3 短名，竖线后的值才是安装名。
    param([string]$Path)
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Database = $null
    $View = $null
    try {
        $Database = $Installer.GetType().InvokeMember(
            "OpenDatabase", [Reflection.BindingFlags]::InvokeMethod, $null, $Installer, @($Path, 0)
        )
        $View = $Database.GetType().InvokeMember(
            "OpenView", [Reflection.BindingFlags]::InvokeMethod, $null, $Database,
            @("SELECT ``FileName`` FROM ``File``")
        )
        $View.GetType().InvokeMember(
            "Execute", [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        ) | Out-Null
        $Names = @()
        while ($null -ne ($Record = $View.GetType().InvokeMember(
            "Fetch", [Reflection.BindingFlags]::InvokeMethod, $null, $View, $null
        ))) {
            $Value = $Record.GetType().InvokeMember(
                "StringData", [Reflection.BindingFlags]::GetProperty, $null, $Record, @(1)
            )
            $Names += ($Value -split "\|")[-1]
        }
        return @($Names | Sort-Object -Unique)
    }
    finally {
        if ($null -ne $View) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($View) }
        if ($null -ne $Database) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Database) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Installer)
    }
}

function Build-VersionedMsi {
    # cargo-wix 的输出文件名来自 Cargo 包版本，因此每次构建后立即复制为明确的测试版本名。
    param([string]$Version)
    $WixBin = "C:\Program Files (x86)\WiX Toolset v3.14\bin"
    if (-not (Test-Path (Join-Path $WixBin "candle.exe"))) {
        throw "缺少 WiX 3.14：$WixBin"
    }
    $PreviousPath = $env:PATH
    try {
        $env:PATH = "$WixBin;$PreviousPath"
        Push-Location $RepositoryRoot
        try {
            & cargo wix `
                --nocapture `
                --no-build `
                --package paneflow-app `
                --target x86_64-pc-windows-msvc `
                --install-version $Version `
                --include packaging/wix/main.wxs | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "cargo-wix 生成 $Version MSI 失败" }
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $env:PATH = $PreviousPath
    }

    $Generated = Join-Path $RepositoryRoot "target\wix\agent-workspace-$Version-x86_64.msi"
    if (-not (Test-Path -LiteralPath $Generated -PathType Leaf)) {
        throw "cargo-wix 没有生成预期 MSI：$Generated"
    }
    $Destination = Join-Path $OutputDirectory "agent-workspace-$Version-x86_64.msi"
    Copy-Item -LiteralPath $Generated -Destination $Destination -Force
    return $Destination
}

function Get-InstalledAgentWorkspace {
    # 同时检查 64/32 位卸载视图，要求系统中最多只有一个 AgentWorkspace 产品。
    $Roots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    return @(
        Get-ItemProperty $Roots -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq "AgentWorkspace" }
    )
}

function Invoke-MsiTransaction {
    # 使用独立完整日志执行单次 Windows Installer 事务；非零退出码保留现场后失败。
    param(
        [ValidateSet("Install", "Uninstall")][string]$Action,
        [string]$PackageOrProductCode,
        [string]$LogPath
    )
    $Mode = if ($Action -eq "Install") { "/i" } else { "/x" }
    $Arguments = @(
        $Mode,
        ('"{0}"' -f $PackageOrProductCode),
        "/qn",
        "/norestart",
        "/l*v",
        ('"{0}"' -f $LogPath)
    )
    $Process = Start-Process `
        -FilePath (Join-Path $env:WINDIR "System32\msiexec.exe") `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru
    if ($Process.ExitCode -ne 0) {
        throw "msiexec $Action 失败，退出码 $($Process.ExitCode)，日志：$LogPath"
    }
    return $Process.ExitCode
}

function Assert-MachinePathContainsInstallDirectory {
    # MSI 写入系统 PATH 后以环境注册表的真实值验证，不依赖当前进程的旧环境快照。
    param([string]$InstallDirectory)
    $Expected = $InstallDirectory.TrimEnd("\")
    $Entries = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine") -split ";" |
            ForEach-Object { $_.Trim().TrimEnd("\") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if (-not ($Entries | Where-Object { $_ -ieq $Expected })) {
        throw "系统 PATH 没有 AgentWorkspace 安装目录：$InstallDirectory"
    }
}

function Assert-MachinePathDoesNotContainInstallDirectory {
    # 卸载后读取注册表中的系统 PATH，避免当前进程仍持有安装前环境而产生误判。
    param([string]$InstallDirectory)
    $Expected = $InstallDirectory.TrimEnd("\")
    $Entries = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine") -split ";" |
            ForEach-Object { $_.Trim().TrimEnd("\") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($Entries | Where-Object { $_ -ieq $Expected }) {
        throw "卸载后系统 PATH 仍包含 AgentWorkspace 安装目录：$InstallDirectory"
    }
}

function Invoke-InstalledVersionProbe {
    # 在隔离 USERPROFILE 下执行已安装 EXE 的真实 CLI 版本探针，避免读写开发者现有会话。
    param([string]$Executable, [string]$UserRoot, [string]$ResultRoot, [string]$Label)
    $Stdout = Join-Path $ResultRoot "$Label-stdout.txt"
    $Stderr = Join-Path $ResultRoot "$Label-stderr.txt"
    $PreviousUserProfile = $env:USERPROFILE
    $PreviousHome = $env:HOME
    try {
        $env:USERPROFILE = $UserRoot
        $env:HOME = $UserRoot
        $Process = Start-Process `
            -FilePath $Executable `
            -ArgumentList "--version" `
            -RedirectStandardOutput $Stdout `
            -RedirectStandardError $Stderr `
            -Wait `
            -PassThru
    }
    finally {
        $env:USERPROFILE = $PreviousUserProfile
        $env:HOME = $PreviousHome
    }
    if ($Process.ExitCode -ne 0) {
        throw "已安装 EXE 版本探针失败：$Label，退出码 $($Process.ExitCode)"
    }
    $Output = (Get-Content -Raw -LiteralPath $Stdout).Trim()
    if ($Output -ne "agent-workspace 0.7.11") {
        throw "已安装 EXE 版本输出异常：$Output"
    }
    return $Output
}

function New-PreservationSentinel {
    # 创建具有稳定 UTF-8 字节内容的边界哨兵，并返回后续阶段可复核的分类与摘要。
    param(
        [string]$Category,
        [string]$Lifecycle,
        [string]$Path,
        [string]$Content
    )
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    return [ordered]@{
        category = $Category
        lifecycle = $Lifecycle
        path = $Path
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        preserved = $true
    }
}

function Assert-PreservationSentinels {
    # 每个生命周期阶段都逐项验证存在性和摘要，避免聚合判断掩盖具体受损的数据类别。
    param(
        [object[]]$Sentinels,
        [string]$Stage
    )
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

$SelectedModeCount = [int][bool]$PrepareOnly + [int][bool]$InstallAndUpgrade + [int][bool]$Uninstall
if ($SelectedModeCount -ne 1) {
    throw "必须且只能选择 -PrepareOnly、-InstallAndUpgrade 或 -Uninstall 之一"
}

if ($PrepareOnly) {
    Assert-ElevatedAndUninstalled
    & python (Join-Path $RepositoryRoot "scripts\生成Windows法律材料.py") --check
    if ($LASTEXITCODE -ne 0) { throw "Windows 法律材料门禁失败" }

    $PreviousMsi = Build-VersionedMsi -Version $PreviousVersion
    # 最后生成当前版本，确保 target/wix 留下的是后续安装验收使用的最新版。
    $CurrentMsi = Build-VersionedMsi -Version $CurrentVersion
    $PreviousProperties = [ordered]@{
        productName = Get-MsiProperty -Path $PreviousMsi -Name "ProductName"
        productVersion = Get-MsiProperty -Path $PreviousMsi -Name "ProductVersion"
        productCode = Get-MsiProperty -Path $PreviousMsi -Name "ProductCode"
        upgradeCode = Get-MsiProperty -Path $PreviousMsi -Name "UpgradeCode"
    }
    $CurrentProperties = [ordered]@{
        productName = Get-MsiProperty -Path $CurrentMsi -Name "ProductName"
        productVersion = Get-MsiProperty -Path $CurrentMsi -Name "ProductVersion"
        productCode = Get-MsiProperty -Path $CurrentMsi -Name "ProductCode"
        upgradeCode = Get-MsiProperty -Path $CurrentMsi -Name "UpgradeCode"
    }

    if ($PreviousProperties.productName -ne "AgentWorkspace" -or $CurrentProperties.productName -ne "AgentWorkspace") {
        throw "测试 MSI ProductName 不是 AgentWorkspace"
    }
    if ($PreviousProperties.productVersion -ne $PreviousVersion -or $CurrentProperties.productVersion -ne $CurrentVersion) {
        throw "测试 MSI ProductVersion 不符合预期"
    }
    if ($PreviousProperties.upgradeCode -ne $CurrentProperties.upgradeCode) {
        throw "低版本与当前版本 UpgradeCode 不一致，无法执行 MajorUpgrade"
    }
    if ($PreviousProperties.productCode -eq $CurrentProperties.productCode) {
        throw "低版本与当前版本 ProductCode 相同，无法证明覆盖升级产品替换"
    }

    $ExpectedLegalFiles = @(
        "LICENSE.txt",
        "UPSTREAM-NOTICE.md",
        "THIRD-PARTY-RUST.md",
        "THIRD-PARTY-RUST.json",
        "THIRD-PARTY-ASSETS.md"
    )
    foreach ($Msi in @($PreviousMsi, $CurrentMsi)) {
        $FileNames = Get-MsiFileNames -Path $Msi
        foreach ($Name in $ExpectedLegalFiles) {
            if ($FileNames -notcontains $Name) { throw "$Msi 缺少法律材料：$Name" }
        }
        if ($FileNames -notcontains "agent-workspace.exe") { throw "$Msi 缺少真实主程序" }
    }

    $Result = [ordered]@{
        schemaVersion = 1
        preparedAt = (Get-Date).ToString("o")
        previous = [ordered]@{
            path = $PreviousMsi
            length = (Get-Item $PreviousMsi).Length
            sha256 = (Get-FileHash $PreviousMsi -Algorithm SHA256).Hash.ToLowerInvariant()
            properties = $PreviousProperties
        }
        current = [ordered]@{
            path = $CurrentMsi
            length = (Get-Item $CurrentMsi).Length
            sha256 = (Get-FileHash $CurrentMsi -Algorithm SHA256).Hash.ToLowerInvariant()
            properties = $CurrentProperties
        }
        expectedLegalFiles = $ExpectedLegalFiles
    }
    $ResultPath = Join-Path $OutputDirectory "准备结果.json"
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
    Write-Output "MSI 生命周期准备验收通过"
    Write-Output "低版本：$PreviousMsi"
    Write-Output "当前版本：$CurrentMsi"
    Write-Output "UpgradeCode：$($CurrentProperties.upgradeCode)"
    exit 0
}

if ($Uninstall) {
    # 卸载只接受上一阶段留下的受控产品和证据，避免误删用户自行安装的同名应用。
    Assert-Elevated
    $InstallResultPath = Join-Path $OutputDirectory "安装升级结果.json"
    if (-not (Test-Path -LiteralPath $InstallResultPath -PathType Leaf)) {
        throw "缺少安装升级结果，拒绝卸载未知产品：$InstallResultPath"
    }
    $InstallResult = Get-Content -Raw -LiteralPath $InstallResultPath | ConvertFrom-Json
    $Installed = Get-InstalledAgentWorkspace
    if ($Installed.Count -ne 1 -or $Installed[0].DisplayVersion -ne $CurrentVersion) {
        throw "当前系统不是本次验收预期的单一 $CurrentVersion 产品，拒绝卸载"
    }
    $ExpectedProductCode = ([string]$InstallResult.current.productCode).Trim("{}").ToUpperInvariant()
    $ActualProductCode = ([string]$Installed[0].PSChildName).Trim("{}").ToUpperInvariant()
    if ($ActualProductCode -ne $ExpectedProductCode) {
        throw "当前 ProductCode 与安装升级结果不一致，拒绝卸载：$($Installed[0].PSChildName)"
    }

    $InstallDirectory = [string]$InstallResult.installDirectory
    $StartMenuDirectory = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AgentWorkspace"
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory "agent-workspace.exe") -PathType Leaf)) {
        throw "卸载前缺少受控主程序，拒绝在不完整现场继续"
    }
    if (-not (Test-Path -LiteralPath $StartMenuDirectory -PathType Container)) {
        throw "卸载前缺少受控开始菜单目录，拒绝在不完整现场继续"
    }
    Assert-MachinePathContainsInstallDirectory -InstallDirectory $InstallDirectory
    if (@(Get-Process -Name "agent-workspace" -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "卸载前仍有 AgentWorkspace 进程，拒绝强行终止用户进程"
    }

    $InstallSentinels = @($InstallResult.sentinels)
    Assert-PreservationSentinels -Sentinels $InstallSentinels -Stage "卸载前"

    $RunRoot = [string]$InstallResult.runRoot
    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
        throw "安装升级运行目录不存在：$RunRoot"
    }
    $UninstallLog = Join-Path $RunRoot "卸载-0.7.11.log"
    $UninstallExitCode = Invoke-MsiTransaction `
        -Action Uninstall `
        -PackageOrProductCode $Installed[0].PSChildName `
        -LogPath $UninstallLog

    if ((Get-InstalledAgentWorkspace).Count -ne 0) {
        throw "卸载后注册表仍存在 AgentWorkspace 产品"
    }
    if (Test-Path -LiteralPath $InstallDirectory) {
        throw "卸载后安装目录仍存在：$InstallDirectory"
    }
    if (Test-Path -LiteralPath $StartMenuDirectory) {
        throw "卸载后开始菜单目录仍存在：$StartMenuDirectory"
    }
    Assert-MachinePathDoesNotContainInstallDirectory -InstallDirectory $InstallDirectory
    if (@(Get-Process -Name "agent-workspace" -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "卸载后出现 AgentWorkspace 进程残留"
    }

    $PreservedSentinels = @()
    foreach ($Sentinel in $InstallSentinels) {
        if (-not (Test-Path -LiteralPath $Sentinel.path -PathType Leaf)) {
            throw "卸载误删哨兵 [$($Sentinel.category)]：$($Sentinel.path)"
        }
        $ActualHash = (Get-FileHash -LiteralPath $Sentinel.path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualHash -ne $Sentinel.sha256) {
            throw "卸载修改了哨兵 [$($Sentinel.category)]：$($Sentinel.path)"
        }
        $PreservedSentinels += [ordered]@{
            category = [string]$Sentinel.category
            lifecycle = [string]$Sentinel.lifecycle
            path = [string]$Sentinel.path
            sha256 = $ActualHash
            preserved = $true
        }
    }

    $UninstallResult = [ordered]@{
        schemaVersion = 2
        executedAt = (Get-Date).ToString("o")
        productCode = [string]$Installed[0].PSChildName
        productVersion = [string]$Installed[0].DisplayVersion
        exitCode = $UninstallExitCode
        log = $UninstallLog
        installDirectoryRemoved = $true
        startMenuRemoved = $true
        machinePathRemoved = $true
        uninstallRegistryRemoved = $true
        processResidueCount = 0
        sentinels = $PreservedSentinels
    }
    $UninstallResultPath = Join-Path $OutputDirectory "卸载结果.json"
    $UninstallResult | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $UninstallResultPath -Encoding utf8
    Write-Output "MSI 卸载边界验收通过"
    Write-Output "已卸载 ProductCode：$($Installed[0].PSChildName)"
    Write-Output "$($PreservedSentinels.Count) 个分类数据哨兵均保留"
    exit 0
}

# 真实初装与覆盖升级阶段只消费已通过准备门禁的两个 MSI；发现既有产品仍会在写入前停止。
Assert-ElevatedAndUninstalled
$PreparationPath = Join-Path $OutputDirectory "准备结果.json"
if (-not (Test-Path -LiteralPath $PreparationPath -PathType Leaf)) {
    throw "缺少准备结果，请先执行 -PrepareOnly：$PreparationPath"
}
$Preparation = Get-Content -Raw -LiteralPath $PreparationPath | ConvertFrom-Json
$PreviousMsi = [string]$Preparation.previous.path
$CurrentMsi = [string]$Preparation.current.path
foreach ($Msi in @($PreviousMsi, $CurrentMsi)) {
    if (-not (Test-Path -LiteralPath $Msi -PathType Leaf)) { throw "准备的 MSI 不存在：$Msi" }
}
if ((Get-FileHash $PreviousMsi -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Preparation.previous.sha256) {
    throw "低版本 MSI 在准备后发生变化"
}
if ((Get-FileHash $CurrentMsi -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Preparation.current.sha256) {
    throw "当前版本 MSI 在准备后发生变化"
}

$RunRoot = Join-Path $OutputDirectory ("run-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$ProjectRoot = Join-Path $RunRoot "project-sentinel"
$UserRoot = Join-Path $RunRoot "user"
$UserDataRoot = Join-Path $UserRoot ".agent-workspace"
$LegacyDataRoot = Join-Path $UserRoot "AppData\Local\paneflow"
$UnrelatedUserRoot = Join-Path $UserRoot "Documents"
# durable 是卸载后必须保留的不可重建数据；其余类别虽可重建或属于外部，但安装器同样无权修改。
$SentinelSpecs = @(
    [ordered]@{ category = "external-project"; lifecycle = "external"; path = (Join-Path $ProjectRoot "用户项目不得删除.txt"); content = "agent-workspace-project-sentinel" },
    [ordered]@{ category = "data-root"; lifecycle = "durable"; path = (Join-Path $UserDataRoot "用户数据不得删除.txt"); content = "agent-workspace-user-data-sentinel" },
    [ordered]@{ category = "config"; lifecycle = "durable"; path = (Join-Path $UserDataRoot "config\settings.json"); content = '{"telemetry":{"enabled":false},"sentinel":"msi-config"}' },
    [ordered]@{ category = "sessions"; lifecycle = "durable"; path = (Join-Path $UserDataRoot "sessions\workspaces.json"); content = '{"schemaVersion":1,"workspaces":[],"sentinel":"msi-sessions"}' },
    [ordered]@{ category = "state"; lifecycle = "durable"; path = (Join-Path $UserDataRoot "state\window-layout.json"); content = '{"schemaVersion":1,"sentinel":"msi-state"}' },
    [ordered]@{ category = "bin"; lifecycle = "durable"; path = (Join-Path $UserDataRoot "bin\stable-helper.txt"); content = "agent-workspace-stable-bin-sentinel" },
    [ordered]@{ category = "cache"; lifecycle = "rebuildable"; path = (Join-Path $UserDataRoot "cache\cache-sentinel.txt"); content = "agent-workspace-cache-sentinel" },
    [ordered]@{ category = "logs"; lifecycle = "diagnostic"; path = (Join-Path $UserDataRoot "logs\diagnostic-sentinel.txt"); content = "agent-workspace-log-sentinel" },
    [ordered]@{ category = "legacy-paneflow"; lifecycle = "legacy"; path = (Join-Path $LegacyDataRoot "legacy-sentinel.txt"); content = "legacy-paneflow-data-sentinel" },
    [ordered]@{ category = "unrelated-user-file"; lifecycle = "external"; path = (Join-Path $UnrelatedUserRoot "unrelated-sentinel.txt"); content = "unrelated-user-file-sentinel" }
)
$Sentinels = @(
    foreach ($Spec in $SentinelSpecs) {
        New-PreservationSentinel `
            -Category $Spec.category `
            -Lifecycle $Spec.lifecycle `
            -Path $Spec.path `
            -Content $Spec.content
    }
)
$InstallDirectory = Join-Path $env:ProgramFiles "AgentWorkspace"
$InstalledExecutable = Join-Path $InstallDirectory "agent-workspace.exe"

$PreviousLog = Join-Path $RunRoot "安装-0.7.10.log"
$PreviousExitCode = Invoke-MsiTransaction -Action Install -PackageOrProductCode $PreviousMsi -LogPath $PreviousLog
$InstalledAfterPrevious = Get-InstalledAgentWorkspace
if ($InstalledAfterPrevious.Count -ne 1 -or $InstalledAfterPrevious[0].DisplayVersion -ne $PreviousVersion) {
    throw "0.7.10 初装后卸载注册项不符合预期"
}
if (-not (Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) {
    throw "0.7.10 初装后缺少主程序：$InstalledExecutable"
}
foreach ($Name in $Preparation.expectedLegalFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory "licenses\$Name") -PathType Leaf)) {
        throw "0.7.10 初装后缺少法律材料：$Name"
    }
}
Assert-MachinePathContainsInstallDirectory -InstallDirectory $InstallDirectory
$PreviousProbe = Invoke-InstalledVersionProbe `
    -Executable $InstalledExecutable `
    -UserRoot $UserRoot `
    -ResultRoot $RunRoot `
    -Label "初装"

$UpgradeLog = Join-Path $RunRoot "升级-0.7.11.log"
$UpgradeExitCode = Invoke-MsiTransaction -Action Install -PackageOrProductCode $CurrentMsi -LogPath $UpgradeLog
$InstalledAfterUpgrade = Get-InstalledAgentWorkspace
if ($InstalledAfterUpgrade.Count -ne 1 -or $InstalledAfterUpgrade[0].DisplayVersion -ne $CurrentVersion) {
    throw "0.7.11 覆盖升级后卸载注册项不符合预期"
}
$ExpectedCurrentCode = ([string]$Preparation.current.properties.productCode).Trim("{}").ToUpperInvariant()
$ActualCurrentCode = ([string]$InstalledAfterUpgrade[0].PSChildName).Trim("{}").ToUpperInvariant()
if ($ActualCurrentCode -ne $ExpectedCurrentCode) {
    throw "覆盖升级后 ProductCode 不是当前版本：$($InstalledAfterUpgrade[0].PSChildName)"
}
Assert-PreservationSentinels -Sentinels $Sentinels -Stage "覆盖升级后"
$UpgradeProbe = Invoke-InstalledVersionProbe `
    -Executable $InstalledExecutable `
    -UserRoot $UserRoot `
    -ResultRoot $RunRoot `
    -Label "升级"

$Result = [ordered]@{
    schemaVersion = 2
    executedAt = (Get-Date).ToString("o")
    runRoot = $RunRoot
    installDirectory = $InstallDirectory
    previous = [ordered]@{
        msi = $PreviousMsi
        exitCode = $PreviousExitCode
        displayVersion = $InstalledAfterPrevious[0].DisplayVersion
        productCode = $InstalledAfterPrevious[0].PSChildName
        versionProbe = $PreviousProbe
        log = $PreviousLog
    }
    current = [ordered]@{
        msi = $CurrentMsi
        exitCode = $UpgradeExitCode
        displayVersion = $InstalledAfterUpgrade[0].DisplayVersion
        productCode = $InstalledAfterUpgrade[0].PSChildName
        versionProbe = $UpgradeProbe
        log = $UpgradeLog
    }
    sentinels = $Sentinels
}
$ResultPath = Join-Path $OutputDirectory "安装升级结果.json"
$Result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $ResultPath -Encoding utf8
Write-Output "MSI 初装与覆盖升级验收通过"
Write-Output "0.7.10 ProductCode：$($InstalledAfterPrevious[0].PSChildName)"
Write-Output "0.7.11 ProductCode：$($InstalledAfterUpgrade[0].PSChildName)"
Write-Output "安装目录：$InstallDirectory"
Write-Output "升级后保留数据分类：$($Sentinels.Count)"
