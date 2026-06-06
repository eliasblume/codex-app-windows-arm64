function Get-ExtractedSingleFile {
    param(
        [string]$Root,
        [string]$ExpectedName
    )

    $exact = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.Name -eq $ExpectedName } |
        Select-Object -First 1
    if ($null -ne $exact) {
        return $exact.FullName
    }

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File)
    if ($files.Count -eq 1) {
        return $files[0].FullName
    }

    throw "Could not find extracted file $ExpectedName in $Root"
}

function Get-Arm64WslCodexPayload {
    param(
        [object]$Release,
        [string]$Owner,
        [string]$Repo,
        [string]$AssetNamePattern,
        [string]$CacheDir
    )

    $safeTag = $Release.tag_name -replace "[^A-Za-z0-9_.-]", "_"
    $payloadCacheDir = Join-Path $CacheDir "codex-wsl-aarch64-$safeTag"
    $codexPath = Join-Path $payloadCacheDir "codex"
    $bwrapPath = Join-Path $payloadCacheDir "bwrap"

    if (-not (Test-Path -LiteralPath $codexPath) -or -not (Test-Path -LiteralPath $bwrapPath)) {
        New-CleanDirectory $payloadCacheDir | Out-Null

        $assets = @(
            @{ asset = "codex-aarch64-unknown-linux-musl.tar.gz"; expected = "codex-aarch64-unknown-linux-musl"; target = $codexPath },
            @{ asset = "bwrap-aarch64-unknown-linux-musl.tar.gz"; expected = "bwrap-aarch64-unknown-linux-musl"; target = $bwrapPath }
        )

        foreach ($item in $assets) {
            $archivePath = Join-Path $payloadCacheDir $item.asset
            Download-VerifiedGitHubReleaseAsset `
                -Release $Release `
                -Owner $Owner `
                -Repo $Repo `
                -AssetName $item.asset `
                -Destination $archivePath `
                -AssetNamePattern $AssetNamePattern `
                -Label $item.expected | Out-Null

            $extractDirName = ($item.asset -replace "[^A-Za-z0-9_.-]", "_") -replace "\.tar\.gz$", ""
            $extractDir = Join-Path $payloadCacheDir $extractDirName
            Expand-TarGzClean $archivePath $extractDir | Out-Null

            $sourcePath = Get-ExtractedSingleFile $extractDir $item.expected
            Copy-Item -LiteralPath $sourcePath -Destination $item.target -Force
        }
    }

    foreach ($path in @($codexPath, $bwrapPath)) {
        $machine = Get-ElfMachine $path
        if ($machine -ne "arm64") {
            throw "Downloaded WSL runtime payload is $machine, expected arm64: $path"
        }
    }

    return [pscustomobject][ordered]@{
        CodexPath = $codexPath
        BwrapPath = $bwrapPath
    }
}

function Copy-Arm64WslCodexPayload {
    param(
        [object]$Payload,
        [string]$DestinationDir
    )

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    Copy-Item -LiteralPath $Payload.CodexPath -Destination (Join-Path $DestinationDir "codex") -Force

    $resourcesDir = Join-Path $DestinationDir "codex-resources"
    New-Item -ItemType Directory -Path $resourcesDir -Force | Out-Null
    Copy-Item -LiteralPath $Payload.BwrapPath -Destination (Join-Path $resourcesDir "bwrap") -Force
}

function Test-IsUnderDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $directoryFull = [System.IO.Path]::GetFullPath($Directory).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($directoryFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsWslCodexPayloadPath {
    param([string]$RelativePath)

    return (
        $RelativePath -match "\\bin\\wsl\\codex$" -or
        $RelativePath -match "\\wsl\\" -or
        $RelativePath -match "\\codex-wsl"
    )
}

function Test-IsWslBwrapPayloadPath {
    param([string]$RelativePath)

    return (
        $RelativePath -match "\\codex-resources\\bwrap$" -or
        $RelativePath -match "\\bin\\wsl\\" -or
        $RelativePath -match "\\wsl\\"
    )
}

function Install-Arm64WslCodexRuntime {
    param(
        [string]$PackageRoot,
        [string]$ResourcesDir,
        [string]$AsarExtractDir,
        [string]$CacheDir,
        [string]$ReleaseTag
    )

    Write-Step "Replacing WSL Codex runtime with linux-aarch64 from openai/codex"
    $releaseInfo = Get-GitHubReleaseFromPolicy "Codex" $ReleaseTag "WSL Codex"
    $release = $releaseInfo.Release
    $script:Context.Report.versions.codexRelease = $release.tag_name
    $payload = Get-Arm64WslCodexPayload `
        -Release $release `
        -Owner $releaseInfo.Owner `
        -Repo $releaseInfo.Repo `
        -AssetNamePattern $releaseInfo.AssetNamePattern `
        -CacheDir $CacheDir

    $packagedSeedDir = Join-Path $PackageRoot $script:Context.Paths.WslPayloadRelativeDir
    Copy-Arm64WslCodexPayload $payload $packagedSeedDir
    Add-Replacement "wsl-codex-packaged-source" "arm64" (Get-RelativePath $PackageRoot (Join-Path $packagedSeedDir "codex"))
    Add-Replacement "wsl-bwrap-packaged-source" "arm64" (Get-RelativePath $PackageRoot (Join-Path $packagedSeedDir "codex-resources\bwrap"))

    $candidateRoots = @($ResourcesDir, $AsarExtractDir) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_)
    }

    $patchedCodexSeeds = New-Object System.Collections.Generic.List[string]
    $patchedBwrapSeeds = New-Object System.Collections.Generic.List[string]
    foreach ($root in $candidateRoots) {
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "codex" -or $_.Name -eq "bwrap" }

        foreach ($file in $files) {
            if (Test-IsUnderDirectory $file.FullName $packagedSeedDir) {
                continue
            }

            $machine = Get-ElfMachine $file.FullName
            if ($machine -eq "NotELF") {
                continue
            }

            $relative = if (Test-IsUnderDirectory $file.FullName $PackageRoot) {
                Get-RelativePath $PackageRoot $file.FullName
            }
            else {
                "app.asar\" + (Get-RelativePath $AsarExtractDir $file.FullName)
            }

            if ($file.Name -eq "codex") {
                if (-not (Test-IsWslCodexPayloadPath $relative)) {
                    continue
                }

                Copy-Item -LiteralPath $payload.CodexPath -Destination $file.FullName -Force
                $seedDir = Split-Path -Parent $file.FullName
                $seedResourcesDir = Join-Path $seedDir "codex-resources"
                New-Item -ItemType Directory -Path $seedResourcesDir -Force | Out-Null
                $bwrapTarget = Join-Path $seedResourcesDir "bwrap"
                Copy-Item -LiteralPath $payload.BwrapPath -Destination $bwrapTarget -Force
                $bwrapRelative = if (Test-IsUnderDirectory $bwrapTarget $PackageRoot) {
                    Get-RelativePath $PackageRoot $bwrapTarget
                }
                else {
                    "app.asar\" + (Get-RelativePath $AsarExtractDir $bwrapTarget)
                }
                $patchedCodexSeeds.Add($relative) | Out-Null
                $patchedBwrapSeeds.Add($bwrapRelative) | Out-Null
            }
            elseif ($file.Name -eq "bwrap") {
                if (-not (Test-IsWslBwrapPayloadPath $relative)) {
                    continue
                }

                Copy-Item -LiteralPath $payload.BwrapPath -Destination $file.FullName -Force
                $patchedBwrapSeeds.Add($relative) | Out-Null
            }
        }
    }

    if ($patchedCodexSeeds.Count -gt 0) {
        Add-Replacement "wsl-codex-existing-seeds" "arm64" ($patchedCodexSeeds -join ", ")
    }
    else {
        Write-Warn "No extra packaged WSL codex seed was found. The ARM64 source was added at app\resources\codex."
        Add-Replacement "wsl-codex-existing-seeds" "not-found" "packaged source added at app\resources\codex"
    }

    if ($patchedBwrapSeeds.Count -gt 0) {
        Add-Replacement "wsl-bwrap-existing-seeds" "arm64" ($patchedBwrapSeeds -join ", ")
    }
}
