# 在真实 Windows Installer 上验证 AgentWorkspace MSI 的准备、安装、升级与卸载边界。
# 当前原子先实现 -PrepareOnly：检查既有安装，生成低版本/当前版本 MSI，并读取真实 MSI 数据库。
# 后续原子会在同一脚本中接入初装、MajorUpgrade 和卸载，不另建并行生命周期实现。
[CmdletBinding()]
param(
    [switch]$PrepareOnly,
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

if (-not $PrepareOnly) {
    throw "当前原子只开放 -PrepareOnly；安装、升级和卸载将在后续原子接入"
}

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
