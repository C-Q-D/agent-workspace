# 在真实 Windows Installer 上验证 AgentWorkspace MSI 的准备、安装、升级与卸载边界。
# -PrepareOnly 检查既有安装、生成低版本/当前版本 MSI，并读取真实 MSI 数据库；
# -InstallAndUpgrade 使用准备结果执行初装和 MajorUpgrade。卸载在下一原子接入。
[CmdletBinding()]
param(
    [switch]$PrepareOnly,
    [switch]$InstallAndUpgrade,
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

function Assert-ElevatedAndUninstalled {
    # perMachine MSI 需要提升权限；发现既有用户安装时必须在任何写操作前停止。
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "MSI 生命周期验收需要管理员权限"
    }

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

if ($PrepareOnly -and $InstallAndUpgrade) {
    throw "-PrepareOnly 与 -InstallAndUpgrade 不能同时使用"
}
if (-not $PrepareOnly -and -not $InstallAndUpgrade) {
    throw "必须选择 -PrepareOnly 或 -InstallAndUpgrade"
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
New-Item -ItemType Directory -Force -Path $ProjectRoot, $UserDataRoot | Out-Null
$ProjectSentinel = Join-Path $ProjectRoot "用户项目不得删除.txt"
$UserSentinel = Join-Path $UserDataRoot "用户数据不得删除.txt"
Set-Content -LiteralPath $ProjectSentinel -Encoding utf8 -Value "agent-workspace-project-sentinel"
Set-Content -LiteralPath $UserSentinel -Encoding utf8 -Value "agent-workspace-user-data-sentinel"
$ProjectHash = (Get-FileHash $ProjectSentinel -Algorithm SHA256).Hash
$UserHash = (Get-FileHash $UserSentinel -Algorithm SHA256).Hash
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
if ((Get-FileHash $ProjectSentinel -Algorithm SHA256).Hash -ne $ProjectHash) {
    throw "覆盖升级修改了用户项目哨兵"
}
if ((Get-FileHash $UserSentinel -Algorithm SHA256).Hash -ne $UserHash) {
    throw "覆盖升级修改了用户数据哨兵"
}
$UpgradeProbe = Invoke-InstalledVersionProbe `
    -Executable $InstalledExecutable `
    -UserRoot $UserRoot `
    -ResultRoot $RunRoot `
    -Label "升级"

$Result = [ordered]@{
    schemaVersion = 1
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
    sentinels = [ordered]@{
        project = [ordered]@{ path = $ProjectSentinel; sha256 = $ProjectHash.ToLowerInvariant(); preserved = $true }
        userData = [ordered]@{ path = $UserSentinel; sha256 = $UserHash.ToLowerInvariant(); preserved = $true }
    }
}
$ResultPath = Join-Path $OutputDirectory "安装升级结果.json"
$Result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $ResultPath -Encoding utf8
Write-Output "MSI 初装与覆盖升级验收通过"
Write-Output "0.7.10 ProductCode：$($InstalledAfterPrevious[0].PSChildName)"
Write-Output "0.7.11 ProductCode：$($InstalledAfterUpgrade[0].PSChildName)"
Write-Output "安装目录：$InstallDirectory"
