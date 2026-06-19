function Invoke-BuildOrchestration {
    param([object]$Context)

    $SourceMode = $Context.Options.SourceMode
    $SourceMsixPath = $Context.Options.SourceMsixPath
    $OutputDir = $Context.Options.OutputDir
    $PackageIdentity = $Context.Options.PackageIdentity
    $DisplayName = $Context.Options.DisplayName
    $PackageVersionOverride = $Context.Options.PackageVersionOverride
    $PublisherSubject = $Context.Options.PublisherSubject
    $CodexReleaseTag = $Context.Options.CodexReleaseTag
    $InstallVsDependencies = $Context.Options.InstallVsDependencies
    $SkipVsDependencyCheck = $Context.Options.SkipVsDependencyCheck
    $KeepWorkDir = $Context.Options.KeepWorkDir
    $Force = $Context.Options.Force

    Write-Step "Phase: Initialize"
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = $script:Context.Paths.DefaultOutputDir
    }
    $resolvedPackageVersionOverride = Resolve-PackageVersionOverride $PackageVersionOverride

    $resolvedOutputDir = New-Item -ItemType Directory -Path $OutputDir -Force
    $resolvedOutputDir = (Resolve-Path -LiteralPath $resolvedOutputDir.FullName).Path
    $workDir = New-CleanDirectory (Join-Path $resolvedOutputDir "work")
    $cacheDir = New-Item -ItemType Directory -Path (Join-Path $resolvedOutputDir "cache") -Force
    $cacheDir = (Resolve-Path -LiteralPath $cacheDir.FullName).Path

    Write-Step "Phase: Preflight"
    $makeAppx = Find-WindowsKitTool "makeappx.exe"
    $signTool = Find-WindowsKitTool "signtool.exe"
    $mt = Find-WindowsKitTool "mt.exe"
    $script:Context.Report.tools = [ordered]@{
        makeAppx = $makeAppx
        signTool = $signTool
        mt = $mt
    }

    Ensure-VisualStudioArm64Tools

    Write-Step "Phase: Acquire"
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

    Write-Step "Phase: Transform"
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
    Patch-OwlFeatureBindingFallback $asarExtractDir

    $electronVersion = Read-ElectronVersion $appDir $asarExtractDir
    $nodeVersion = Read-NodeVersion $resourcesDir
    $script:Context.Report.versions.electron = $electronVersion
    $script:Context.Report.versions.node = $nodeVersion

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
    Install-Arm64CuaNodeSharpPackage $resourcesDir $workDir
    Install-Arm64CuaNodeCanvasPackage $resourcesDir $workDir

    Build-Arm64NativeModules $asarExtractDir $electronVersion $workDir

    Write-Step "Repacking app.asar"
    Repack-AppAsar $asarExtractDir $resourcesDir

    Write-Step "Phase: Package"
    $manifestPath = Join-Path $stageRoot "AppxManifest.xml"
    Update-AppxManifest $manifestPath $PackageIdentity $DisplayName $PublisherSubject $resolvedPackageVersionOverride
    if (-not [string]::IsNullOrWhiteSpace($resolvedPackageVersionOverride)) {
        Add-Replacement "package-version" "overridden" $resolvedPackageVersionOverride
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    $version = $manifest.Package.Identity.Version
    $script:Context.Report.versions.package = $version

    $certDir = Join-Path $resolvedOutputDir "cert"
    $certificate = Ensure-SigningCertificate $PublisherSubject $certDir

    $msixFileName = "Codex-WoA_$version`_arm64.msix"
    $msixPath = Join-Path $resolvedOutputDir $msixFileName
    if ((Test-Path -LiteralPath $msixPath) -and -not $Force) {
        throw "Output MSIX already exists: $msixPath. Use -Force to overwrite."
    }

    Pack-And-SignMsix $stageRoot $msixPath $makeAppx $signTool $certificate
    Write-Step "Phase: Validate"
    Test-MsixPackage $msixPath (Join-Path $workDir "verify") $makeAppx $signTool $mt $PackageIdentity $certificate.Thumbprint

    Write-Step "Phase: Report"
    $installScriptPath = Join-Path $resolvedOutputDir "Install.ps1"
    New-InstallScript $installScriptPath $msixFileName "cert\CodexWoA.cer"
    $installBatchPath = Join-Path $resolvedOutputDir "Install.bat"
    New-InstallBatchScript $installBatchPath

    $script:Context.Report.outputs.msix = $msixPath
    $script:Context.Report.outputs.installScript = $installScriptPath
    $script:Context.Report.outputs.installBatch = $installBatchPath
    $script:Context.Report.finishedAt = (Get-Date).ToString("o")

    $reportPath = Join-Path $resolvedOutputDir "build-report.json"
    $script:Context.Report.outputs.report = $reportPath
    $script:Context.Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

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
