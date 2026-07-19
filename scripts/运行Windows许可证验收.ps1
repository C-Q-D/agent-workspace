# 对真实 AgentWorkspace Release、About 界面和 MSI 法律材料执行 Windows 总验收。
# 脚本不安装 MSI，也不修改用户现有数据；应用使用临时 USERPROFILE 启动，
# MSI 通过 WiX dark 解包后核对文件表与真实字节，最终只保存截图和 JSON 证据。
[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [string]$MsiPath,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $RepositoryRoot "target\x86_64-pc-windows-msvc\release\agent-workspace.exe"
}
if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    $MsiPath = Join-Path $RepositoryRoot "target\wix\agent-workspace-0.7.11-x86_64.msi"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        "docs\验收\Windows许可证数据\Release-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
}

$ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
$MsiPath = [System.IO.Path]::GetFullPath($MsiPath)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
foreach ($Path in @($ExecutablePath, $MsiPath)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "验收输入不存在：$Path"
    }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

# 调用现有确定性门禁；任何锁定依赖或 Windows 发布材料漂移都先于 UI/MSI 验收失败。
$PreviousBytecode = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONDONTWRITEBYTECODE = "1"
    & python (Join-Path $RepositoryRoot "scripts\生成第三方许可证清单.py") --check
    if ($LASTEXITCODE -ne 0) { throw "第三方许可证门禁失败" }
    & python (Join-Path $RepositoryRoot "scripts\生成Windows法律材料.py") --check
    if ($LASTEXITCODE -ne 0) { throw "Windows 法律材料门禁失败" }
    & python (Join-Path $RepositoryRoot "scripts\测试Windows法律材料.py")
    if ($LASTEXITCODE -ne 0) { throw "Windows 法律材料测试失败" }
}
finally {
    $env:PYTHONDONTWRITEBYTECODE = $PreviousBytecode
}

# WiX 3 dark 按 File Id 提取柜体内容，最终安装名保存在反编译 WXS 中；两者必须同时核对。
$WixRoots = @(
    "C:\Program Files (x86)\WiX Toolset v3.14\bin",
    "C:\Program Files (x86)\WiX Toolset v3.11\bin"
)
$WixBin = $WixRoots | Where-Object { Test-Path (Join-Path $_ "dark.exe") } | Select-Object -First 1
if ($null -eq $WixBin) {
    throw "未找到 WiX 3 dark.exe，无法读取真实 MSI 文件表"
}
$ExtractRoot = Join-Path $RepositoryRoot (
    "target\windows-license-acceptance\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
)
$ExtractContent = Join-Path $ExtractRoot "内容"
$DecompiledWxs = Join-Path $ExtractRoot "反编译结果.wxs"
New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
& (Join-Path $WixBin "dark.exe") -x $ExtractContent -o $DecompiledWxs $MsiPath
if ($LASTEXITCODE -ne 0) { throw "WiX dark 反编译 MSI 失败" }

[xml]$MsiXml = Get-Content -Raw -LiteralPath $DecompiledWxs
$Namespace = New-Object System.Xml.XmlNamespaceManager($MsiXml.NameTable)
$Namespace.AddNamespace("w", "http://schemas.microsoft.com/wix/2006/wi")
$ExpectedMsiFiles = [ordered]@{
    RootLicenseText = "LICENSE.txt"
    UpstreamNotice = "UPSTREAM-NOTICE.md"
    ThirdPartyRustMarkdown = "THIRD-PARTY-RUST.md"
    ThirdPartyRustJson = "THIRD-PARTY-RUST.json"
    ThirdPartyAssets = "THIRD-PARTY-ASSETS.md"
}
$MsiFileResults = @()
foreach ($FileId in $ExpectedMsiFiles.Keys) {
    $ExtractedPath = Join-Path (Join-Path $ExtractContent "File") $FileId
    if (-not (Test-Path -LiteralPath $ExtractedPath -PathType Leaf)) {
        throw "MSI 解包缺少法律材料 File Id：$FileId"
    }
    $Node = $MsiXml.SelectSingleNode("//w:File[@Id='$FileId']", $Namespace)
    if ($null -eq $Node -or $Node.Name -ne $ExpectedMsiFiles[$FileId]) {
        throw "MSI 安装名映射错误：$FileId"
    }
    $Info = Get-Item -LiteralPath $ExtractedPath
    $MsiFileResults += [ordered]@{
        fileId = $FileId
        installedName = $Node.Name
        length = $Info.Length
        sha256 = (Get-FileHash -LiteralPath $ExtractedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
if (-not (Select-String -Quiet -SimpleMatch "GNU GENERAL PUBLIC LICENSE" (Join-Path $ExtractContent "File\RootLicenseText"))) {
    throw "MSI 内 LICENSE.txt 不是 GPL"
}
if (-not (Select-String -Quiet -SimpleMatch "Paneflow" (Join-Path $ExtractContent "File\UpstreamNotice"))) {
    throw "MSI 内上游归属没有记录 Paneflow"
}
if (-not (Select-String -Quiet -SimpleMatch "第三方包数量：1109" (Join-Path $ExtractContent "File\ThirdPartyRustMarkdown"))) {
    throw "MSI 内 Rust 依赖数量不是 1109"
}
if (-not (Select-String -Quiet -SimpleMatch "已登记字体文件：36" (Join-Path $ExtractContent "File\ThirdPartyAssets"))) {
    throw "MSI 内字体登记数量不是 36"
}

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceLicenseAcceptance {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@

function Save-ScreenRegion {
    # 保存固定窗口区域；窗口已被放置到 (20,20)，避免被不同桌面尺寸影响证据。
    param([string]$Path)
    $Bitmap = New-Object System.Drawing.Bitmap 1200, 800
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Graphics.CopyFromScreen(20, 20, 0, 0, $Bitmap.Size)
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Graphics.Dispose()
        $Bitmap.Dispose()
    }
}

function Get-SampledPixelChanges {
    # 以固定网格比较打开 About 前后画面，证明真实点击确实改变了渲染状态。
    param([string]$BeforePath, [string]$AfterPath)
    $Before = [System.Drawing.Bitmap]::FromFile($BeforePath)
    $After = [System.Drawing.Bitmap]::FromFile($AfterPath)
    $Changed = 0
    $Samples = 0
    try {
        for ($Y = 20; $Y -lt 780; $Y += 20) {
            for ($X = 20; $X -lt 1180; $X += 20) {
                $Samples++
                if ($Before.GetPixel($X, $Y).ToArgb() -ne $After.GetPixel($X, $Y).ToArgb()) {
                    $Changed++
                }
            }
        }
    }
    finally {
        $Before.Dispose()
        $After.Dispose()
    }
    return [ordered]@{ samples = $Samples; changed = $Changed }
}

$UserRoot = Join-Path $ExtractRoot "user"
New-Item -ItemType Directory -Force -Path $UserRoot | Out-Null
$BeforeScreenshot = Join-Path $OutputDirectory "真实Release主界面.png"
$AboutScreenshot = Join-Path $OutputDirectory "真实Release-About法律入口.png"
$PreviousUserProfile = $env:USERPROFILE
$PreviousHome = $env:HOME
$Process = $null
try {
    # 隔离用户目录，确保验收不读取或覆盖开发者现有 AgentWorkspace 会话。
    $env:USERPROFILE = (Resolve-Path $UserRoot).Path
    $env:HOME = $env:USERPROFILE
    $Process = Start-Process -FilePath $ExecutablePath -WorkingDirectory $RepositoryRoot -WindowStyle Normal -PassThru
    $Deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 200
        $Process.Refresh()
    } while ($Process.MainWindowHandle -eq 0 -and (Get-Date) -lt $Deadline)
    if ($Process.MainWindowHandle -eq 0) { throw "真实 Release 未创建主窗口" }

    [AgentWorkspaceLicenseAcceptance]::SetWindowPos(
        $Process.MainWindowHandle, [IntPtr](-1), 20, 20, 1200, 800, 0x0040
    ) | Out-Null
    [AgentWorkspaceLicenseAcceptance]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
    Start-Sleep -Seconds 5
    Save-ScreenRegion -Path $BeforeScreenshot

    # 真实点击 Help，再点击固定菜单中的 About AgentWorkspace。
    foreach ($Point in @(@(151, 37), @(200, 232))) {
        [AgentWorkspaceLicenseAcceptance]::SetCursorPos($Point[0], $Point[1]) | Out-Null
        [AgentWorkspaceLicenseAcceptance]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [AgentWorkspaceLicenseAcceptance]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 700
    }
    Save-ScreenRegion -Path $AboutScreenshot
}
finally {
    if ($null -ne $Process -and -not $Process.HasExited) {
        $null = $Process.CloseMainWindow()
        if (-not $Process.WaitForExit(5000)) {
            Stop-Process -Id $Process.Id -Force
            $Process.WaitForExit()
        }
    }
    $env:USERPROFILE = $PreviousUserProfile
    $env:HOME = $PreviousHome
}

$PixelChanges = Get-SampledPixelChanges -BeforePath $BeforeScreenshot -AfterPath $AboutScreenshot
if ($PixelChanges.changed -lt 100) {
    throw "真实点击后画面变化不足，About 可能没有打开：$($PixelChanges.changed) 个采样点"
}

$ExecutableInfo = Get-Item -LiteralPath $ExecutablePath
$MsiInfo = Get-Item -LiteralPath $MsiPath
$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    executable = [ordered]@{
        path = $ExecutableInfo.FullName
        length = $ExecutableInfo.Length
        sha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    msi = [ordered]@{
        path = $MsiInfo.FullName
        length = $MsiInfo.Length
        sha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        legalFiles = $MsiFileResults
    }
    about = [ordered]@{
        beforeScreenshot = $BeforeScreenshot
        screenshot = $AboutScreenshot
        sampledPixelChanges = $PixelChanges
        processExited = ($null -eq $Process -or $Process.HasExited)
    }
    gates = [ordered]@{
        rustPackages = 1109
        fontFiles = 36
        unresolvedLicenses = 0
        windowsLegalTests = 4
    }
}
$ResultPath = Join-Path $OutputDirectory "运行结果.json"
$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding utf8
Write-Output "Windows 许可证总验收通过"
Write-Output "证据目录：$OutputDirectory"
Write-Output "MSI SHA-256：$($Result.msi.sha256)"
Write-Output "About 变化采样点：$($PixelChanges.changed)/$($PixelChanges.samples)"
