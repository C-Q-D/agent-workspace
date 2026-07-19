<#
.SYNOPSIS
使用真实 Release 程序验收 AgentWorkspace 的 Windows 图标链路。

.DESCRIPTION
脚本隔离构建 agent-workspace.exe，通过 Windows Shell API 提取 PE 关联图标，
真实启动应用并读取主窗口图标句柄，同时保存窗口截图、像素对比和机器可读结果。
脚本不使用替身程序或模拟图标。
#>
[CmdletBinding()]
param(
    # 验收证据根目录；默认保存在仓库内，便于随提交复核。
    [string]$OutputRoot = "",

    # 已存在最新隔离 Release 产物时，仅重复图标与窗口检查。
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 所有仓库路径从脚本位置解析，避免调用目录改变验收对象。
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot "docs\验收\Windows图标数据"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ResultDirectory = Join-Path $OutputRoot "Release-$Timestamp"
$TargetDirectory = Join-Path $RepositoryRoot "target\icon-atom"
$ExecutablePath = Join-Path $TargetDirectory "release\agent-workspace.exe"
$MasterIconPath = Join-Path $RepositoryRoot "assets\AgentWorkspace.ico"
$WixIconPath = Join-Path $RepositoryRoot "packaging\wix\agent-workspace.ico"
$ExpectedPePngPath = Join-Path $RepositoryRoot "assets\icons\agent-workspace-32.png"
$FixtureRoot = Join-Path $TargetDirectory "验收工作区"
$UserRoot = Join-Path $TargetDirectory "验收用户"
New-Item -ItemType Directory -Force -Path $ResultDirectory, $FixtureRoot, $UserRoot | Out-Null

function Write-Utf8Text {
    <# 以无 BOM UTF-8 和统一换行保存可复核文本。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Text
    )

    $Normalized = $Text.TrimEnd("`r", "`n") + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $Normalized,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Wait-MainWindow {
    <# 等待真实主窗口出现，并拒绝把启动器或无界面进程误当成产品窗口。 #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "AgentWorkspace 在主窗口出现前退出，退出码：$($Process.ExitCode)"
        }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $Deadline)

    throw "等待 AgentWorkspace 主窗口超时：$TimeoutSeconds 秒"
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

// Windows 图标验收所需的最小窗口 API 集合。
public static class AgentWorkspaceIconAcceptance
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW", SetLastError = true)]
    public static extern IntPtr GetClassLongPtr(IntPtr hWnd, int index);
}
"@

function Save-WindowScreenshot {
    <# 保存真实应用窗口截图，并校验捕获区域不是零尺寸或辅助窗口。 #>
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Rect = [AgentWorkspaceIconAcceptance+RECT]::new()
    if (-not [AgentWorkspaceIconAcceptance]::GetWindowRect($Handle, [ref]$Rect)) {
        throw "无法读取 AgentWorkspace 主窗口边界"
    }
    $Width = $Rect.Right - $Rect.Left
    $Height = $Rect.Bottom - $Rect.Top
    if ($Width -lt 800 -or $Height -lt 500) {
        throw "拒绝保存非主窗口截图：${Width}×${Height}"
    }

    $Bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    try {
        $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
        try {
            $Graphics.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Bitmap.Size)
        }
        finally {
            $Graphics.Dispose()
        }
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Bitmap.Dispose()
    }
}

function Save-IconBitmap {
    <# 把图标对象保存为 PNG，便于像素比较和人工复核。 #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Icon]$Icon,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Bitmap = $Icon.ToBitmap()
    try {
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return [ordered]@{ width = $Bitmap.Width; height = $Bitmap.Height }
    }
    finally {
        $Bitmap.Dispose()
    }
}

function Get-BitmapDifference {
    <# 计算两个同尺寸图像的平均 RGBA 通道差，用于验证图标来源一致。 #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActualPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath
    )

    $Actual = [System.Drawing.Bitmap]::new($ActualPath)
    $ExpectedOriginal = [System.Drawing.Bitmap]::new($ExpectedPath)
    $Expected = [System.Drawing.Bitmap]::new($ExpectedOriginal, $Actual.Width, $Actual.Height)
    try {
        [long]$TotalDifference = 0
        [long]$ChangedPixels = 0
        for ($Y = 0; $Y -lt $Actual.Height; $Y++) {
            for ($X = 0; $X -lt $Actual.Width; $X++) {
                $A = $Actual.GetPixel($X, $Y)
                $E = $Expected.GetPixel($X, $Y)
                $Difference = [math]::Abs($A.A - $E.A) +
                    [math]::Abs($A.R - $E.R) +
                    [math]::Abs($A.G - $E.G) +
                    [math]::Abs($A.B - $E.B)
                $TotalDifference += $Difference
                if ($Difference -ne 0) {
                    $ChangedPixels++
                }
            }
        }
        $ChannelCount = [double]($Actual.Width * $Actual.Height * 4)
        return [ordered]@{
            width = $Actual.Width
            height = $Actual.Height
            changedPixels = $ChangedPixels
            meanChannelDifference = [math]::Round($TotalDifference / $ChannelCount, 4)
        }
    }
    finally {
        $Expected.Dispose()
        $ExpectedOriginal.Dispose()
        $Actual.Dispose()
    }
}

# 先运行确定性资产校验；脚本会拒绝缺帧、错误透明通道和不同步的 WiX ICO。
$PreviousBytecodeSetting = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONDONTWRITEBYTECODE = "1"
    $AssetLines = & python (Join-Path $RepositoryRoot "scripts\生成Windows图标资产.py") 2>&1
    $AssetExitCode = $LASTEXITCODE
}
finally {
    if ($null -eq $PreviousBytecodeSetting) {
        Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONDONTWRITEBYTECODE = $PreviousBytecodeSetting
    }
}
$AssetLogPath = Join-Path $ResultDirectory "图标资产校验.txt"
Write-Utf8Text -Path $AssetLogPath -Text (($AssetLines | Out-String).TrimEnd("`r", "`n"))
if ($AssetExitCode -ne 0) {
    throw "图标资产校验失败：$AssetLogPath"
}

if (-not $SkipBuild) {
    $BuildLogPath = Join-Path $ResultDirectory "Release构建.txt"
    $PreviousTargetDirectory = $env:CARGO_TARGET_DIR
    try {
        $env:CARGO_TARGET_DIR = $TargetDirectory
        Push-Location $RepositoryRoot
        try {
            $BuildLines = & cargo build -p paneflow-app --release 2>&1
            $BuildExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if ($null -eq $PreviousTargetDirectory) {
            Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:CARGO_TARGET_DIR = $PreviousTargetDirectory
        }
    }
    Write-Utf8Text -Path $BuildLogPath -Text (($BuildLines | Out-String).TrimEnd("`r", "`n"))
    if ($BuildExitCode -ne 0) {
        throw "Release 构建失败，退出码：$BuildExitCode。请先分析：$BuildLogPath"
    }
}

foreach ($RequiredPath in @($ExecutablePath, $MasterIconPath, $WixIconPath, $ExpectedPePngPath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "缺少图标验收对象：$RequiredPath"
    }
}

$MasterHash = (Get-FileHash -LiteralPath $MasterIconPath -Algorithm SHA256).Hash.ToLowerInvariant()
$WixHash = (Get-FileHash -LiteralPath $WixIconPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($MasterHash -ne $WixHash) {
    throw "主 ICO 与 WiX ICO 不一致"
}

# Explorer 和任务栏读取 PE 关联图标；提取失败意味着 EXE 未正确嵌入资源。
$PeIconPath = Join-Path $ResultDirectory "PE关联图标.png"
$PeIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExecutablePath)
if ($null -eq $PeIcon) {
    throw "Windows Shell 无法从 agent-workspace.exe 提取关联图标"
}
try {
    $PeIconSize = Save-IconBitmap -Icon $PeIcon -Path $PeIconPath
}
finally {
    $PeIcon.Dispose()
}
$PeDifference = Get-BitmapDifference -ActualPath $PeIconPath -ExpectedPath $ExpectedPePngPath
if ($PeDifference.meanChannelDifference -gt 2.0) {
    throw "PE 关联图标与 AgentWorkspace 源图差异过大：$($PeDifference.meanChannelDifference)"
}

# 与系统普通控制台程序比较，防止把 Windows 通用图标误判为产品图标。
$GenericExecutable = Join-Path $env:WINDIR "System32\where.exe"
$GenericIconPath = Join-Path $ResultDirectory "系统通用程序图标.png"
$GenericIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($GenericExecutable)
if ($null -eq $GenericIcon) {
    throw "无法提取系统对照图标：$GenericExecutable"
}
try {
    $null = Save-IconBitmap -Icon $GenericIcon -Path $GenericIconPath
}
finally {
    $GenericIcon.Dispose()
}
$GenericDifference = Get-BitmapDifference -ActualPath $GenericIconPath -ExpectedPath $ExpectedPePngPath
if ($GenericDifference.meanChannelDifference -lt 5.0) {
    throw "系统对照图标与 AgentWorkspace 图标过于接近，无法证明 PE 使用独立资源"
}

$ScreenshotPath = Join-Path $ResultDirectory "真实AgentWorkspace窗口.png"
$WindowIconPath = Join-Path $ResultDirectory "真实窗口图标.png"
$PreviousUserProfile = $env:USERPROFILE
$PreviousHome = $env:HOME
$Process = $null
try {
    # 临时用户目录隔离真实启动数据，不读取开发者现有会话。
    $env:USERPROFILE = $UserRoot
    $env:HOME = $UserRoot
    $Process = Start-Process -FilePath $ExecutablePath -WorkingDirectory $FixtureRoot -WindowStyle Normal -PassThru
    $WindowHandle = Wait-MainWindow -Process $Process
    [AgentWorkspaceIconAcceptance]::ShowWindow($WindowHandle, 9) | Out-Null
    # 截图前把真实目标 HWND 临时置顶并切到前台，防止其他应用覆盖后被误存为
    # AgentWorkspace 证据；固定到可见区域也排除上次会话的离屏窗口位置。
    [AgentWorkspaceIconAcceptance]::SetWindowPos(
        $WindowHandle,
        [IntPtr](-1),
        20,
        20,
        1200,
        800,
        0x0040
    ) | Out-Null
    [AgentWorkspaceIconAcceptance]::SetForegroundWindow($WindowHandle) | Out-Null
    Start-Sleep -Milliseconds 800
    $Process.Refresh()
    $WindowTitle = $Process.MainWindowTitle
    Save-WindowScreenshot -Handle $WindowHandle -Path $ScreenshotPath

    # 优先读取窗口显式小图标，若框架未设置则读取窗口类图标；两者都来自真实 HWND。
    $WindowIconHandle = [AgentWorkspaceIconAcceptance]::SendMessage(
        $WindowHandle,
        0x007F,
        [IntPtr]2,
        [IntPtr]::Zero
    )
    if ($WindowIconHandle -eq [IntPtr]::Zero) {
        $WindowIconHandle = [AgentWorkspaceIconAcceptance]::GetClassLongPtr($WindowHandle, -34)
    }
    if ($WindowIconHandle -eq [IntPtr]::Zero) {
        $WindowIconHandle = [AgentWorkspaceIconAcceptance]::GetClassLongPtr($WindowHandle, -14)
    }
    if ($WindowIconHandle -eq [IntPtr]::Zero) {
        throw "真实 AgentWorkspace 主窗口没有可读取的 Windows 图标句柄"
    }

    $BorrowedIcon = [System.Drawing.Icon]::FromHandle($WindowIconHandle)
    $WindowIcon = $BorrowedIcon.Clone()
    try {
        $WindowIconSize = Save-IconBitmap -Icon $WindowIcon -Path $WindowIconPath
    }
    finally {
        $WindowIcon.Dispose()
    }
    # HWND 可能按当前 DPI 返回 16px 或 32px 帧，必须与同尺寸源帧比较；
    # 先缩放 32px 基准会引入不同插值核，造成图标正确但验收误报。
    $ExpectedWindowPngPath = Join-Path $RepositoryRoot (
        "assets\icons\agent-workspace-{0}.png" -f $WindowIconSize.width
    )
    if (-not (Test-Path -LiteralPath $ExpectedWindowPngPath -PathType Leaf)) {
        throw "缺少真实窗口尺寸对应的 AgentWorkspace PNG：$ExpectedWindowPngPath"
    }
    $WindowDifference = Get-BitmapDifference -ActualPath $WindowIconPath -ExpectedPath $ExpectedWindowPngPath
    if ($WindowDifference.meanChannelDifference -gt 2.0) {
        throw "真实窗口图标与 AgentWorkspace 源图差异过大：$($WindowDifference.meanChannelDifference)"
    }
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

$ExecutableInfo = Get-Item -LiteralPath $ExecutablePath
$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    repository = $RepositoryRoot
    executable = [ordered]@{
        path = $ExecutableInfo.FullName
        length = $ExecutableInfo.Length
        sha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    iconAssets = [ordered]@{
        masterIcoSha256 = $MasterHash
        wixIcoSha256 = $WixHash
        sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    }
    peAssociatedIcon = [ordered]@{
        path = $PeIconPath
        expected = $ExpectedPePngPath
        size = $PeIconSize
        comparison = $PeDifference
    }
    genericControl = [ordered]@{
        executable = $GenericExecutable
        path = $GenericIconPath
        comparison = $GenericDifference
    }
    realWindow = [ordered]@{
        title = $WindowTitle
        screenshot = $ScreenshotPath
        icon = $WindowIconPath
        expected = $ExpectedWindowPngPath
        iconSize = $WindowIconSize
        comparison = $WindowDifference
    }
    result = "passed"
}
$ResultPath = Join-Path $ResultDirectory "运行结果.json"
Write-Utf8Text -Path $ResultPath -Text ($Result | ConvertTo-Json -Depth 8)

Write-Host "Windows 图标验收通过。结果：$ResultPath"
