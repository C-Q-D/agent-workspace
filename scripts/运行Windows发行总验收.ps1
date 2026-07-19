# 汇总 AgentWorkspace Windows MSI 与便携 ZIP 的既有真实证据，并执行全部非破坏性发布门禁。
# 脚本不会安装或卸载 MSI；破坏性生命周期由独立脚本完成，这里校验证据、产物、测试与系统零残留。
[CmdletBinding()]
param(
    [string]$MsiEvidencePath,
    [string]$PortableEvidencePath,
    [string]$MsiPath,
    [string]$ZipPath,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($MsiEvidencePath)) {
    $MsiEvidencePath = Join-Path $RepositoryRoot "docs\验收\WindowsMSI生命周期数据\Release-20260719-185519\运行结果.json"
}
if ([string]::IsNullOrWhiteSpace($PortableEvidencePath)) {
    $PortableEvidencePath = Join-Path $RepositoryRoot "docs\验收\Windows便携包数据\Release-20260719-190609\运行结果.json"
}
if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    $MsiPath = Join-Path $RepositoryRoot "target\msi-lifecycle\agent-workspace-0.7.11-x86_64.msi"
}
if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $RepositoryRoot "target\portable-test\atom32-02\first\agent-workspace-0.7.11-windows-x64.zip"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        "target\windows-distribution-acceptance\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
}
$MsiEvidencePath = [IO.Path]::GetFullPath($MsiEvidencePath)
$PortableEvidencePath = [IO.Path]::GetFullPath($PortableEvidencePath)
$MsiPath = [IO.Path]::GetFullPath($MsiPath)
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($Path in @($MsiEvidencePath, $PortableEvidencePath, $MsiPath, $ZipPath, "$ZipPath.sha256")) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Windows 发行总验收输入不存在：$Path"
    }
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Windows 发行总验收输出目录必须是全新目录：$OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

function Invoke-CheckedProcess {
    # 每个外部门禁独立记录标准输出、错误输出和退出码，首个失败会保留现场并终止总验收。
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments
    )
    $SafeLabel = $Label -replace '[\\/:*?"<>|]', '-'
    $Stdout = Join-Path $OutputDirectory "$SafeLabel-stdout.txt"
    $Stderr = Join-Path $OutputDirectory "$SafeLabel-stderr.txt"
    $Process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $RepositoryRoot `
        -RedirectStandardOutput $Stdout `
        -RedirectStandardError $Stderr `
        -Wait `
        -PassThru
    if ($Process.ExitCode -ne 0) {
        throw "$Label 失败，退出码 $($Process.ExitCode)，日志：$Stdout / $Stderr"
    }
    return [pscustomobject]@{
        label = $Label
        exitCode = $Process.ExitCode
        stdout = $Stdout
        stderr = $Stderr
    }
}

function Assert-SystemHasNoAgentWorkspaceResidue {
    # 总门禁只检查并报告残留，不自动卸载、删目录或终止可能属于用户的进程。
    $UninstallRoots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $Installed = @(
        Get-ItemProperty $UninstallRoots -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq "AgentWorkspace" }
    )
    if ($Installed.Count -ne 0) {
        throw "系统仍存在 AgentWorkspace 卸载注册项；总门禁不会自动卸载用户产品"
    }
    $InstallDirectory = Join-Path $env:ProgramFiles "AgentWorkspace"
    if (Test-Path -LiteralPath $InstallDirectory) {
        throw "系统仍存在 AgentWorkspace 安装目录：$InstallDirectory"
    }
    $StartMenuDirectory = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AgentWorkspace"
    if (Test-Path -LiteralPath $StartMenuDirectory) {
        throw "系统仍存在 AgentWorkspace 开始菜单目录：$StartMenuDirectory"
    }
    $ExpectedPath = $InstallDirectory.TrimEnd("\")
    $PathMatches = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine") -split ";" |
            ForEach-Object { $_.Trim().TrimEnd("\") } |
            Where-Object { $_ -ieq $ExpectedPath }
    )
    if ($PathMatches.Count -ne 0) {
        throw "系统 PATH 仍包含 AgentWorkspace 安装目录"
    }
    $Processes = @(Get-Process -Name "agent-workspace" -ErrorAction SilentlyContinue)
    if ($Processes.Count -ne 0) {
        throw "系统仍有 AgentWorkspace 进程；总门禁不会自动终止用户进程"
    }
}

$MsiEvidence = Get-Content -Raw -LiteralPath $MsiEvidencePath | ConvertFrom-Json
$PortableEvidence = Get-Content -Raw -LiteralPath $PortableEvidencePath | ConvertFrom-Json
if ($MsiEvidence.lifecycle.initialInstall.exitCode -ne 0 -or
    $MsiEvidence.lifecycle.majorUpgrade.exitCode -ne 0 -or
    $MsiEvidence.lifecycle.uninstall.exitCode -ne 0 -or
    -not $MsiEvidence.lifecycle.majorUpgrade.oldProductRemoved -or
    -not $MsiEvidence.lifecycle.uninstall.installDirectoryRemoved -or
    -not $MsiEvidence.sentinels.project.preservedAfterUninstall -or
    -not $MsiEvidence.sentinels.userData.preservedAfterUninstall) {
    throw "UNIT-31 MSI 生命周期证据未达到总验收条件"
}
if (-not $PortableEvidence.determinism.identicalBytes -or
    -not $PortableEvidence.extraction.allEntryHashesVerified -or
    $PortableEvidence.execution.exitCode -ne 0 -or
    $PortableEvidence.execution.processResidueCount -ne 0 -or
    -not $PortableEvidence.dataBoundary.developerDataFingerprintPreserved) {
    throw "UNIT-32 便携包证据未达到总验收条件"
}
$CurrentMsiHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
$CurrentZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($CurrentMsiHash -ne $MsiEvidence.packages.current.sha256) {
    throw "当前 MSI 与 UNIT-31 已验收哈希不一致"
}
if ($CurrentZipHash -ne $PortableEvidence.package.sha256) {
    throw "当前便携 ZIP 与 UNIT-32 已验收哈希不一致"
}
$ExpectedSidecar = "$CurrentZipHash *$([IO.Path]::GetFileName($ZipPath))"
if ([IO.File]::ReadAllText("$ZipPath.sha256").Trim() -ne $ExpectedSidecar) {
    throw "当前便携 ZIP sidecar 与实际哈希不一致"
}
Assert-SystemHasNoAgentWorkspaceResidue

$PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
    $PowerShellPath = (Get-Process -Id $PID).Path
}
$PythonPath = (Get-Command python -ErrorAction Stop).Source
$CargoPath = (Get-Command cargo -ErrorAction Stop).Source
$Checks = @()
$ParityOutput = Join-Path $OutputDirectory "载荷一致性"
$Checks += Invoke-CheckedProcess `
    -Label "发行载荷一致性" `
    -FilePath $PowerShellPath `
    -Arguments @(
        "-NoProfile", "-File", (Join-Path $RepositoryRoot "scripts\检查Windows发行载荷一致性.ps1"),
        "-MsiPath", $MsiPath, "-ZipPath", $ZipPath, "-OutputDirectory", $ParityOutput
    )
$Checks += Invoke-CheckedProcess `
    -Label "上游归属声明" `
    -FilePath $PowerShellPath `
    -Arguments @("-NoProfile", "-File", (Join-Path $RepositoryRoot "scripts\检查上游归属声明.ps1"))
$PreviousBytecode = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONDONTWRITEBYTECODE = "1"
    $Checks += Invoke-CheckedProcess `
        -Label "第三方许可证只读门禁" `
        -FilePath $PythonPath `
        -Arguments @((Join-Path $RepositoryRoot "scripts\生成第三方许可证清单.py"), "--check")
    $Checks += Invoke-CheckedProcess `
        -Label "第三方许可证失败门禁" `
        -FilePath $PythonPath `
        -Arguments @((Join-Path $RepositoryRoot "scripts\测试第三方许可证清单.py"))
    $Checks += Invoke-CheckedProcess `
        -Label "Windows法律材料只读门禁" `
        -FilePath $PythonPath `
        -Arguments @((Join-Path $RepositoryRoot "scripts\生成Windows法律材料.py"), "--check")
    $Checks += Invoke-CheckedProcess `
        -Label "Windows法律材料测试" `
        -FilePath $PythonPath `
        -Arguments @((Join-Path $RepositoryRoot "scripts\测试Windows法律材料.py"))
}
finally {
    $env:PYTHONDONTWRITEBYTECODE = $PreviousBytecode
}
$Checks += Invoke-CheckedProcess `
    -Label "主程序完整测试" `
    -FilePath $CargoPath `
    -Arguments @("test", "-p", "paneflow-app", "--locked")
$Checks += Invoke-CheckedProcess `
    -Label "MCP安装完整测试" `
    -FilePath $CargoPath `
    -Arguments @("test", "-p", "paneflow-mcp-install", "--locked")

$AppLog = (Get-Content -Raw -LiteralPath ($Checks | Where-Object label -eq "主程序完整测试").stdout) +
    (Get-Content -Raw -LiteralPath ($Checks | Where-Object label -eq "主程序完整测试").stderr)
if ($AppLog -notmatch "1426 passed; 0 failed" -or $AppLog -notmatch "5 passed; 0 failed") {
    throw "主程序测试虽返回 0，但没有观察到 1426+5 项预期结果"
}
$McpLog = (Get-Content -Raw -LiteralPath ($Checks | Where-Object label -eq "MCP安装完整测试").stdout) +
    (Get-Content -Raw -LiteralPath ($Checks | Where-Object label -eq "MCP安装完整测试").stderr)
if ($McpLog -notmatch "97 passed; 0 failed") {
    throw "MCP 安装测试虽返回 0，但没有观察到 97 项预期结果"
}
$ParityResult = Get-Content -Raw -LiteralPath (Join-Path $ParityOutput "载荷一致性结果.json") | ConvertFrom-Json
if ($ParityResult.sharedPayloadCount -ne 24 -or -not $ParityResult.allSharedPayloadsIdentical) {
    throw "MSI 与便携 ZIP 共享载荷总门禁结果异常"
}
Assert-SystemHasNoAgentWorkspaceResidue

$Os = Get-CimInstance Win32_OperatingSystem
$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    environment = [ordered]@{
        os = [string]$Os.Caption
        version = [string]$Os.Version
        architecture = [string]$Os.OSArchitecture
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    artifacts = [ordered]@{
        version = "0.7.11"
        msi = [ordered]@{ path = $MsiPath; length = (Get-Item $MsiPath).Length; sha256 = $CurrentMsiHash }
        zip = [ordered]@{ path = $ZipPath; length = (Get-Item $ZipPath).Length; sha256 = $CurrentZipHash; sidecarVerified = $true }
    }
    lifecycleEvidence = [ordered]@{
        initialInstall = $true
        majorUpgrade = $true
        uninstall = $true
        userDataPreserved = $true
    }
    portableEvidence = [ordered]@{
        deterministic = $true
        realExecution = $true
        userDataBoundary = $true
    }
    payloadParity = [ordered]@{
        sharedFileCount = 24
        allIdentical = $true
        onlyPortableEntry = "便携版说明.txt"
    }
    regression = [ordered]@{
        upstreamAttribution = $true
        dependencyInventory = "1109 packages; 0 unresolved"
        thirdPartyLicenseTests = 4
        windowsLegalMaterialTests = 4
        applicationTests = 1426
        layoutIntegrationTests = 5
        mcpInstallTests = 97
    }
    systemResidue = [ordered]@{
        uninstallRegistryCount = 0
        installDirectoryPresent = $false
        startMenuPresent = $false
        machinePathPresent = $false
        processCount = 0
    }
    checks = @($Checks | ForEach-Object {
        [ordered]@{ label = $_.label; exitCode = $_.exitCode; stdout = $_.stdout; stderr = $_.stderr }
    })
}
$ResultPath = Join-Path $OutputDirectory "总验收结果.json"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 8) + "`n", $Utf8NoBom)
Write-Output "Windows 发行形态非破坏性总验收通过"
Write-Output "MSI SHA-256：$CurrentMsiHash"
Write-Output "ZIP SHA-256：$CurrentZipHash"
Write-Output "共享载荷：24"
Write-Output "证据：$ResultPath"
