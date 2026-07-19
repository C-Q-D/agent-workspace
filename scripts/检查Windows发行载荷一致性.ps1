# 只读比较 AgentWorkspace Windows MSI 与便携 ZIP 的共享载荷，阻止两个发行形态字节漂移。
# 脚本使用 WiX dark 解包 MSI，但不会安装、升级、卸载或执行任一应用文件。
[CmdletBinding()]
param(
    [string]$Version = "0.7.11",
    [string]$MsiPath,
    [string]$ZipPath,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    $MsiPath = Join-Path $RepositoryRoot "target\msi-lifecycle\agent-workspace-$Version-x86_64.msi"
}
if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $RepositoryRoot "target\portable\agent-workspace-$Version-windows-x64.zip"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        "target\windows-distribution-parity\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
}
$MsiPath = [IO.Path]::GetFullPath($MsiPath)
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($Path in @($MsiPath, $ZipPath)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "发行载荷输入不存在：$Path"
    }
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "发行载荷比对输出目录必须是全新目录：$OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

function Get-MsiProperty {
    # PowerShell 7 通过 IDispatch 显式读取 Windows Installer Property 表。
    param([string]$Path, [string]$Name)
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Database = $null
    $View = $null
    try {
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
        if ($null -eq $Record) { throw "MSI 缺少 Property：$Name" }
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

function Get-ZipEntryHash {
    # 直接从 ZIP 流计算哈希，不依赖解压目录或文件系统时间戳。
    param([IO.Compression.ZipArchiveEntry]$Entry)
    $Stream = $Entry.Open()
    try {
        $Sha = [Security.Cryptography.SHA256]::Create()
        try {
            return [Convert]::ToHexString($Sha.ComputeHash($Stream)).ToLowerInvariant()
        }
        finally {
            $Sha.Dispose()
        }
    }
    finally {
        $Stream.Dispose()
    }
}

$WixRoots = @(
    "C:\Program Files (x86)\WiX Toolset v3.14\bin",
    "C:\Program Files (x86)\WiX Toolset v3.11\bin"
)
$WixBin = $WixRoots | Where-Object { Test-Path (Join-Path $_ "dark.exe") } | Select-Object -First 1
if ($null -eq $WixBin) {
    throw "未找到 WiX dark.exe，无法只读解包 MSI"
}
$ExtractDirectory = Join-Path $OutputDirectory "msi-content"
$DecompiledWxs = Join-Path $OutputDirectory "反编译结果.wxs"
& (Join-Path $WixBin "dark.exe") -x $ExtractDirectory -o $DecompiledWxs $MsiPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "WiX dark 反编译 MSI 失败"
}

$MsiVersion = Get-MsiProperty -Path $MsiPath -Name "ProductVersion"
if ($MsiVersion -ne $Version) {
    throw "MSI ProductVersion 不是 $Version：$MsiVersion"
}
$MsiFileDirectory = Join-Path $ExtractDirectory "File"
$MsiFiles = @(Get-ChildItem -LiteralPath $MsiFileDirectory -File)
if ($MsiFiles.Count -ne 24) {
    throw "MSI File 表载荷数量不是 24：$($MsiFiles.Count)"
}

# 显式映射 WiX File Id 与便携包路径；新增、删除或重命名载荷都必须更新并审查这里。
$Mappings = @(
    @{ Id = "exe0"; Zip = "agent-workspace.exe" },
    @{ Id = "HelperAgy"; Zip = "bin/agy.exe" },
    @{ Id = "HelperAiHook"; Zip = "bin/paneflow-ai-hook.exe" },
    @{ Id = "HelperAmp"; Zip = "bin/amp.exe" },
    @{ Id = "HelperClaude"; Zip = "bin/claude.exe" },
    @{ Id = "HelperCodebuddy"; Zip = "bin/codebuddy.exe" },
    @{ Id = "HelperCodex"; Zip = "bin/codex.exe" },
    @{ Id = "HelperCopilot"; Zip = "bin/copilot.exe" },
    @{ Id = "HelperCursorAgent"; Zip = "bin/cursor-agent.exe" },
    @{ Id = "HelperDroid"; Zip = "bin/droid.exe" },
    @{ Id = "HelperGemini"; Zip = "bin/gemini.exe" },
    @{ Id = "HelperGrok"; Zip = "bin/grok.exe" },
    @{ Id = "HelperHermes"; Zip = "bin/hermes.exe" },
    @{ Id = "HelperKiroCli"; Zip = "bin/kiro-cli.exe" },
    @{ Id = "HelperOpenclaw"; Zip = "bin/openclaw.exe" },
    @{ Id = "HelperOpencode"; Zip = "bin/opencode.exe" },
    @{ Id = "HelperPi"; Zip = "bin/pi.exe" },
    @{ Id = "HelperQodercli"; Zip = "bin/qodercli.exe" },
    @{ Id = "LicenseFile"; Zip = "License.rtf" },
    @{ Id = "RootLicenseText"; Zip = "licenses/LICENSE.txt" },
    @{ Id = "ThirdPartyAssets"; Zip = "licenses/THIRD-PARTY-ASSETS.md" },
    @{ Id = "ThirdPartyRustJson"; Zip = "licenses/THIRD-PARTY-RUST.json" },
    @{ Id = "ThirdPartyRustMarkdown"; Zip = "licenses/THIRD-PARTY-RUST.md" },
    @{ Id = "UpstreamNotice"; Zip = "licenses/UPSTREAM-NOTICE.md" }
)
if ($Mappings.Count -ne $MsiFiles.Count) {
    throw "共享载荷映射数量与 MSI File 表不一致"
}

$Archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $ZipEntries = @($Archive.Entries)
    if ($ZipEntries.Count -ne 25) {
        throw "便携 ZIP 条目数量不是 25：$($ZipEntries.Count)"
    }
    $ExpectedRoot = "AgentWorkspace-$Version-windows-x64/"
    $RelativeZipEntries = @(
        $ZipEntries | ForEach-Object {
            if (-not $_.FullName.StartsWith($ExpectedRoot, [StringComparison]::Ordinal)) {
                throw "ZIP 条目不在预期版本根目录：$($_.FullName)"
            }
            $_.FullName.Substring($ExpectedRoot.Length)
        }
    )
    $ExpectedRelativeEntries = @($Mappings | ForEach-Object Zip) + @("便携版说明.txt")
    if ((Compare-Object -ReferenceObject $ExpectedRelativeEntries -DifferenceObject $RelativeZipEntries).Count -ne 0) {
        throw "ZIP 共享载荷或唯一便携说明发生漂移"
    }

    $Comparisons = @()
    foreach ($Mapping in $Mappings) {
        $MsiFile = Join-Path $MsiFileDirectory $Mapping.Id
        if (-not (Test-Path -LiteralPath $MsiFile -PathType Leaf)) {
            throw "MSI 解包后缺少 File Id：$($Mapping.Id)"
        }
        $ZipFullName = "$ExpectedRoot$($Mapping.Zip)"
        $ZipEntry = $Archive.GetEntry($ZipFullName)
        if ($null -eq $ZipEntry) {
            throw "ZIP 缺少共享载荷：$ZipFullName"
        }
        $MsiHash = (Get-FileHash -LiteralPath $MsiFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $ZipHash = Get-ZipEntryHash -Entry $ZipEntry
        $MsiLength = (Get-Item -LiteralPath $MsiFile).Length
        if ($MsiLength -ne $ZipEntry.Length -or $MsiHash -ne $ZipHash) {
            throw "MSI 与 ZIP 共享载荷不一致：$($Mapping.Zip)"
        }
        $Comparisons += [ordered]@{
            fileId = $Mapping.Id
            path = $Mapping.Zip
            length = $MsiLength
            sha256 = $MsiHash
            identical = $true
        }
    }
}
finally {
    $Archive.Dispose()
}

$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    version = $Version
    msi = [ordered]@{
        path = $MsiPath
        length = (Get-Item -LiteralPath $MsiPath).Length
        sha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        fileCount = $MsiFiles.Count
    }
    zip = [ordered]@{
        path = $ZipPath
        length = (Get-Item -LiteralPath $ZipPath).Length
        sha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        entryCount = $ZipEntries.Count
        onlyPortableEntry = "便携版说明.txt"
    }
    sharedPayloadCount = $Comparisons.Count
    allSharedPayloadsIdentical = $true
    comparisons = $Comparisons
}
$ResultPath = Join-Path $OutputDirectory "载荷一致性结果.json"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 7) + "`n", $Utf8NoBom)
Write-Output "Windows MSI 与便携 ZIP 共享载荷一致性通过"
Write-Output "版本：$Version"
Write-Output "共享文件：$($Comparisons.Count)"
Write-Output "证据：$ResultPath"
