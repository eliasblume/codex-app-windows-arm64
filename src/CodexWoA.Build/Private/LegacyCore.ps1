function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    $script:Report.warnings.Add($Message)
    Write-Warning $Message
}

function Add-Replacement {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    $script:Report.replacements.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
    })
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function New-CleanDirectory {
    param([string]$Path)
    Remove-IfExists $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Set-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Require-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found: $Name"
    }
    return $command.Source
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0)
    )

    Write-Verbose ("Running: {0} {1}" -f $FilePath, ($Arguments -join " "))
    & $FilePath @Arguments | Out-Host
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($SuccessExitCodes -notcontains $exitCode) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
    return $exitCode
}

function Copy-DirectoryRobust {
    param(
        [string]$Source,
        [string]$Destination,
        [ValidateSet("Mirror", "Merge")]
        [string]$Mode = "Mirror"
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $copyMode = if ($Mode -eq "Mirror") { "/MIR" } else { "/E" }
    & robocopy $Source $Destination $copyMode /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "robocopy failed with exit code $exitCode"
    }
}

function Normalize-PercentEncodedScopedPackageDirs {
    param(
        [string]$Root,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $normalized = New-Object "System.Collections.Generic.List[string]"
    $encodedDirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)%40" } |
        Sort-Object { $_.FullName.Length } -Descending)

    foreach ($dir in $encodedDirs) {
        if (-not (Test-Path -LiteralPath $dir.FullName)) {
            continue
        }

        $decodedName = $dir.Name -replace "(?i)%40", "@"
        if ($decodedName -eq $dir.Name) {
            continue
        }

        $target = Join-Path $dir.Parent.FullName $decodedName
        if (Test-Path -LiteralPath $target) {
            Copy-DirectoryRobust $dir.FullName $target -Mode Merge
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        }
        else {
            Rename-Item -LiteralPath $dir.FullName -NewName $decodedName
        }

        $normalized.Add((Get-RelativePath $Root $target)) | Out-Null
    }

    if ($normalized.Count -gt 0) {
        Add-Replacement $Label "normalized" ($normalized -join ", ")
    }
}



function Find-WindowsKitTool {
    param([string]$ToolName)

    $preferredArches = @("arm64", "x64", "x86")
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne "Arm64") {
        $preferredArches = @("x64", "arm64", "x86")
    }

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitRoot) {
        $versions = Get-ChildItem -LiteralPath $kitRoot -Directory |
            Where-Object { $_.Name -match "^\d+\.\d+\.\d+\.\d+$" } |
            Sort-Object { [version]$_.Name } -Descending

        foreach ($version in $versions) {
            foreach ($arch in $preferredArches) {
                $candidate = Join-Path $version.FullName (Join-Path $arch $ToolName)
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "Could not find Windows SDK tool: $ToolName"
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Write-Host "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Downloaded file is empty: $Destination"
    }
}

function Expand-ZipClean {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Expand-MsixClean {
    param(
        [string]$MsixPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($MsixPath, $Destination)
}

function Get-TarCommandPath {
    $command = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    $command = Get-Command "tar" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    throw "Required command not found: tar.exe"
}

function Expand-TarGzClean {
    param(
        [string]$TarGzPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    $tar = Get-TarCommandPath
    Invoke-Checked $tar @("-xzf", $TarGzPath, "-C", $Destination)
}





function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return $pathFull.Substring($rootFull.Length + 1).Replace("/", "\")
}

















































































































































function Main {
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = $script:DefaultOutputDir
    }
    $resolvedPackageVersionOverride = Resolve-PackageVersionOverride $PackageVersionOverride

    $resolvedOutputDir = New-Item -ItemType Directory -Path $OutputDir -Force
    $resolvedOutputDir = (Resolve-Path -LiteralPath $resolvedOutputDir.FullName).Path
    $workDir = New-CleanDirectory (Join-Path $resolvedOutputDir "work")
    $cacheDir = New-Item -ItemType Directory -Path (Join-Path $resolvedOutputDir "cache") -Force
    $cacheDir = (Resolve-Path -LiteralPath $cacheDir.FullName).Path

    $makeAppx = Find-WindowsKitTool "makeappx.exe"
    $signTool = Find-WindowsKitTool "signtool.exe"
    $mt = Find-WindowsKitTool "mt.exe"
    $script:Report.tools = [ordered]@{
        makeAppx = $makeAppx
        signTool = $signTool
        mt = $mt
    }

    Ensure-VisualStudioArm64Tools

    $effectiveSourceMode = Resolve-SourceMode $SourceMode
    $sourceRoot = Join-Path $workDir "source"
    switch ($effectiveSourceMode) {
        "StoreMsix" { Copy-StoreMsixSource $sourceRoot $cacheDir | Out-Null }
        "Installed" { Copy-InstalledSource $sourceRoot | Out-Null }
        "StoreLatest" { Copy-StoreInstalledSource $sourceRoot | Out-Null }
        "Msix" { Copy-MsixSource $SourceMsixPath $sourceRoot | Out-Null }
        default { throw "Unsupported source mode: $effectiveSourceMode" }
    }

    Assert-SourceShape $sourceRoot

    $stageRoot = Join-Path $workDir "stage"
    Write-Step "Preparing staging package"
    New-CleanDirectory $stageRoot | Out-Null
    Copy-DirectoryRobust $sourceRoot $stageRoot
    Remove-SourcePackageMetadata $stageRoot

    $appDir = Join-Path $stageRoot "app"
    $resourcesDir = Join-Path $appDir "resources"
    $asarExtractDir = Join-Path $workDir "app-asar"
    Normalize-PercentEncodedScopedPackageDirs $resourcesDir "resource-scoped-package-dirs"

    Write-Step "Extracting app.asar"
    Extract-AppAsar $resourcesDir $asarExtractDir
    Normalize-PercentEncodedScopedPackageDirs $asarExtractDir "asar-scoped-package-dirs"

    $electronVersion = Read-ElectronVersion $appDir $asarExtractDir
    $nodeVersion = Read-NodeVersion (Join-Path $resourcesDir "node.exe")
    $script:Report.versions.electron = $electronVersion
    $script:Report.versions.node = $nodeVersion

    Install-Arm64ElectronRuntime $appDir $electronVersion $cacheDir
    Install-Arm64Node $resourcesDir $nodeVersion $cacheDir
    Install-Arm64CodexHelpers $resourcesDir $cacheDir $CodexReleaseTag
    Patch-WindowsSandboxSetupAsInvokerManifest $resourcesDir $signTool $mt $workDir
    Install-Arm64WslCodexRuntime $stageRoot $resourcesDir $asarExtractDir $cacheDir $CodexReleaseTag
    Install-Arm64Ripgrep $resourcesDir $cacheDir
    Remove-WindowsUpdaterNative $resourcesDir
    Enable-ChromeExtensionHostX64Fallback $resourcesDir
    Prune-PluginClassicLevelNonArm64WindowsPrebuilds $resourcesDir
    Rebuild-PluginClassicLevelArm64NativeModules $resourcesDir
    Enable-ComputerUseX64Fallback $resourcesDir

    Build-Arm64NativeModules $asarExtractDir $electronVersion $workDir

    Write-Step "Repacking app.asar"
    Repack-AppAsar $asarExtractDir $resourcesDir

    $manifestPath = Join-Path $stageRoot "AppxManifest.xml"
    Update-AppxManifest $manifestPath $PackageIdentity $DisplayName $PublisherSubject $resolvedPackageVersionOverride
    if (-not [string]::IsNullOrWhiteSpace($resolvedPackageVersionOverride)) {
        Add-Replacement "package-version" "overridden" $resolvedPackageVersionOverride
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    $version = $manifest.Package.Identity.Version
    $script:Report.versions.package = $version

    $certDir = Join-Path $resolvedOutputDir "cert"
    $certificate = Ensure-SigningCertificate $PublisherSubject $certDir

    $msixFileName = "Codex-WoA_$version`_arm64.msix"
    $msixPath = Join-Path $resolvedOutputDir $msixFileName
    if ((Test-Path -LiteralPath $msixPath) -and -not $Force) {
        throw "Output MSIX already exists: $msixPath. Use -Force to overwrite."
    }

    Pack-And-SignMsix $stageRoot $msixPath $makeAppx $signTool $certificate
    Test-MsixPackage $msixPath (Join-Path $workDir "verify") $makeAppx $signTool $mt $PackageIdentity $certificate.Thumbprint

    $installScriptPath = Join-Path $resolvedOutputDir "Install.ps1"
    New-InstallScript $installScriptPath $msixFileName "cert\CodexWoA.cer"
    $installBatchPath = Join-Path $resolvedOutputDir "Install.bat"
    New-InstallBatchScript $installBatchPath

    $script:Report.outputs.msix = $msixPath
    $script:Report.outputs.installScript = $installScriptPath
    $script:Report.outputs.installBatch = $installBatchPath
    $script:Report.finishedAt = (Get-Date).ToString("o")

    $reportPath = Join-Path $resolvedOutputDir "build-report.json"
    $script:Report.outputs.report = $reportPath
    $script:Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if (-not $KeepWorkDir) {
        Remove-IfExists $workDir
    }

    Write-Host ""
    Write-Host "Codex WoA package created:" -ForegroundColor Green
    Write-Host "  MSIX: $msixPath"
    Write-Host "  Certificate: $(Join-Path $certDir 'CodexWoA.cer')"
    Write-Host "  Installer: $installScriptPath"
    Write-Host "  Installer batch: $installBatchPath"
    Write-Host "  Report: $reportPath"
}
