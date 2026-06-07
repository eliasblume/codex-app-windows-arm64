function Read-PngUInt32BigEndian {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    return (($Bytes[$Offset] -shl 24) -bor ($Bytes[$Offset + 1] -shl 16) -bor ($Bytes[$Offset + 2] -shl 8) -bor $Bytes[$Offset + 3])
}

function New-IcoFromPng {
    param(
        [string]$PngPath,
        [string]$IcoPath
    )

    $png = [System.IO.File]::ReadAllBytes($PngPath)
    if ($png.Length -lt 24 -or $png[0] -ne 0x89 -or $png[1] -ne 0x50 -or $png[2] -ne 0x4E -or $png[3] -ne 0x47) {
        throw "Icon source is not a PNG file: $PngPath"
    }

    $width = Read-PngUInt32BigEndian $png 16
    $height = Read-PngUInt32BigEndian $png 20
    $iconWidth = if ($width -ge 256) { 0 } else { [byte]$width }
    $iconHeight = if ($height -ge 256) { 0 } else { [byte]$height }

    New-Item -ItemType Directory -Path (Split-Path -Parent $IcoPath) -Force | Out-Null
    $stream = [System.IO.File]::Create($IcoPath)
    try {
        $writer = New-Object System.IO.BinaryWriter($stream)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]$iconWidth)
        $writer.Write([byte]$iconHeight)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$png.Length)
        $writer.Write([uint32]22)
        $writer.Write($png)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RceditPath {
    param([string]$CacheDir)

    $rceditPolicy = (Get-SupplyChainPolicy).DirectDownloads.Rcedit
    $rceditName = [string]$rceditPolicy.AssetName
    $rceditPath = Join-Path $CacheDir $rceditName
    Download-VerifiedDirectDownload "Rcedit" $rceditPath "rcedit" | Out-Null

    return $rceditPath
}

function Set-CodexExecutableIcon {
    param(
        [string]$PackageRoot,
        [string]$CodexExe,
        [string]$CacheDir
    )

    $iconPng = Join-Path $PackageRoot "assets\icon.png"
    if (-not (Test-Path -LiteralPath $iconPng)) {
        Write-Warn "Could not patch Codex.exe icon because assets\icon.png was not found."
        return
    }

    $iconIco = Join-Path $CacheDir "CodexWoA.ico"
    New-IcoFromPng $iconPng $iconIco
    $rcedit = Get-RceditPath $CacheDir
    Invoke-Checked $rcedit @($CodexExe, "--set-icon", $iconIco)
    Add-Replacement "Codex.exe-icon" "patched" "assets\icon.png"
}

function Install-Arm64ElectronRuntime {
    param(
        [string]$AppDir,
        [string]$ElectronVersion,
        [string]$CacheDir
    )

    Write-Step "Replacing Electron runtime with win32-arm64 v$ElectronVersion"
    $zipName = "electron-v$ElectronVersion-win32-arm64.zip"
    $zipPath = Join-Path $CacheDir $zipName
    $releaseInfo = Get-GitHubReleaseFromPolicy "Electron" "v$ElectronVersion" "Electron runtime"
    Download-VerifiedGitHubReleaseAsset `
        -Release $releaseInfo.Release `
        -Owner $releaseInfo.Owner `
        -Repo $releaseInfo.Repo `
        -AssetName $zipName `
        -Destination $zipPath `
        -AssetNamePattern $releaseInfo.AssetNamePattern `
        -Label "electron-runtime" | Out-Null

    $runtimeDir = Join-Path $CacheDir "electron-win32-arm64-$ElectronVersion"
    Expand-ZipClean $zipPath $runtimeDir

    $resourcesDir = Join-Path $AppDir "resources"
    $savedResources = Join-Path (Split-Path -Parent $AppDir) "resources.saved"
    Remove-IfExists $savedResources
    Move-Item -LiteralPath $resourcesDir -Destination $savedResources

    Get-ChildItem -LiteralPath $AppDir -Force | Remove-Item -Recurse -Force
    Copy-DirectoryRobust $runtimeDir $AppDir
    Remove-IfExists (Join-Path $AppDir "resources")
    Move-Item -LiteralPath $savedResources -Destination $resourcesDir

    $electronExe = Join-Path $AppDir "electron.exe"
    $codexExe = Join-Path $AppDir "Codex.exe"
    if (-not (Test-Path -LiteralPath $electronExe)) {
        throw "Electron runtime did not contain electron.exe"
    }
    Move-Item -LiteralPath $electronExe -Destination $codexExe -Force
    Set-CodexExecutableIcon (Split-Path -Parent $AppDir) $codexExe $CacheDir

    Add-Replacement "electron-runtime" "arm64" $zipName
}

function Install-Arm64Node {
    param(
        [string]$ResourcesDir,
        [string]$NodeVersion,
        [string]$CacheDir
    )

    Write-Step "Replacing Node.js with win-arm64 v$NodeVersion"
    $zipName = "node-v$NodeVersion-win-arm64.zip"
    $zipPath = Join-Path $CacheDir $zipName
    Download-VerifiedNodeReleaseFile $NodeVersion $zipName $zipPath $CacheDir | Out-Null

    $nodeDir = Join-Path $CacheDir "node-win-arm64-$NodeVersion"
    Expand-ZipClean $zipPath $nodeDir
    $nodeExe = Get-ChildItem -LiteralPath $nodeDir -Recurse -File -Filter "node.exe" | Select-Object -First 1
    if ($null -eq $nodeExe) {
        throw "Node archive did not contain node.exe"
    }

    Copy-Item -LiteralPath $nodeExe.FullName -Destination (Join-Path $ResourcesDir "node.exe") -Force
    Add-Replacement "node.exe" "arm64" $zipName
}

function Install-Arm64CodexHelpers {
    param(
        [string]$ResourcesDir,
        [string]$CacheDir,
        [string]$ReleaseTag
    )

    Write-Step "Replacing Codex helper executables from openai/codex"
    $releaseInfo = Get-GitHubReleaseFromPolicy "Codex" $ReleaseTag "Codex helper"
    $release = $releaseInfo.Release
    $script:Context.Report.versions.codexRelease = $release.tag_name

    $mapping = @(
        @{ asset = "codex-aarch64-pc-windows-msvc.exe"; target = "codex.exe"; required = $false },
        @{ asset = "codex-command-runner-aarch64-pc-windows-msvc.exe"; target = "codex-command-runner.exe"; required = $false },
        @{ asset = "codex-windows-sandbox-setup-aarch64-pc-windows-msvc.exe"; target = "codex-windows-sandbox-setup.exe"; required = $false },
        @{ asset = "codex-app-server-aarch64-pc-windows-msvc.exe"; target = "codex-app-server.exe"; required = $false },
        @{ asset = "codex-responses-api-proxy-aarch64-pc-windows-msvc.exe"; target = "codex-responses-api-proxy.exe"; required = $false }
    )

    foreach ($item in $mapping) {
        $targetPath = Join-Path $ResourcesDir $item.target
        if (-not (Test-Path -LiteralPath $targetPath) -and -not $item.required) {
            continue
        }

        try {
            $downloadPath = Join-Path $CacheDir $item.asset
            Download-VerifiedGitHubReleaseAsset `
                -Release $release `
                -Owner $releaseInfo.Owner `
                -Repo $releaseInfo.Repo `
                -AssetName $item.asset `
                -Destination $downloadPath `
                -AssetNamePattern $releaseInfo.AssetNamePattern `
                -Label $item.target | Out-Null
            Copy-Item -LiteralPath $downloadPath -Destination $targetPath -Force
            Add-Replacement $item.target "arm64" $item.asset
        }
        catch {
            if ($item.required) {
                throw
            }
            Write-Warn "Could not verify and replace optional helper $($item.target); keeping original fallback. $($_.Exception.Message)"
            Add-Replacement $item.target "fallback" $_.Exception.Message
        }
    }
}

function Install-Arm64Ripgrep {
    param(
        [string]$ResourcesDir,
        [string]$CacheDir
    )

    Write-Step "Replacing rg.exe with ripgrep arm64"
    $releaseInfo = Get-GitHubReleaseFromPolicy "Ripgrep" "latest" "ripgrep"
    $release = $releaseInfo.Release
    $tag = $release.tag_name.TrimStart("v")
    $assetName = "ripgrep-$tag-aarch64-pc-windows-msvc.zip"
    $zipPath = Join-Path $CacheDir $assetName
    Download-VerifiedGitHubReleaseAsset `
        -Release $release `
        -Owner $releaseInfo.Owner `
        -Repo $releaseInfo.Repo `
        -AssetName $assetName `
        -Destination $zipPath `
        -AssetNamePattern $releaseInfo.AssetNamePattern `
        -Label "rg.exe" | Out-Null

    $ripgrepDir = Join-Path $CacheDir "ripgrep-arm64-$tag"
    Expand-ZipClean $zipPath $ripgrepDir
    $rgExe = Get-ChildItem -LiteralPath $ripgrepDir -Recurse -File -Filter "rg.exe" | Select-Object -First 1
    if ($null -eq $rgExe) {
        throw "ripgrep archive did not contain rg.exe"
    }

    Copy-Item -LiteralPath $rgExe.FullName -Destination (Join-Path $ResourcesDir "rg.exe") -Force
    Add-Replacement "rg.exe" "arm64" $assetName
}

function Remove-WindowsUpdaterNative {
    param([string]$ResourcesDir)

    $updaterPath = Join-Path $ResourcesDir "native\windows-updater.node"
    if (Test-Path -LiteralPath $updaterPath) {
        Remove-Item -LiteralPath $updaterPath -Force
        Add-Replacement "windows-updater.node" "removed" "self-signed WoA package disables native updater"
    }
}
