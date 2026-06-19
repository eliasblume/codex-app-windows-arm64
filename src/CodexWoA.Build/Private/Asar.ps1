function Read-ElectronVersion {
    param(
        [string]$AppDir,
        [string]$AsarExtractDir
    )

    $versionFile = Join-Path $AppDir "version"
    if (Test-Path -LiteralPath $versionFile) {
        $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        if ($version -match "^\d+\.\d+\.\d+") {
            return $version
        }
    }

    $packageJson = Join-Path $AsarExtractDir "package.json"
    if (Test-Path -LiteralPath $packageJson) {
        $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
        if ($package.devDependencies.electron) {
            return [string]$package.devDependencies.electron
        }
        if ($package.dependencies.electron) {
            return [string]$package.dependencies.electron
        }
    }

    throw "Could not determine Electron version"
}

function Read-NodeVersion {
    param([string]$ResourcesDir)

    $candidates = @(Get-ChildItem -LiteralPath $ResourcesDir -Recurse -File -Filter "node.exe" -Depth 3 -ErrorAction Stop)
    if ($candidates.Count -eq 0) {
        throw "Could not find bundled node.exe under $($ResourcesDir)"
    }
    if ($candidates.Count -gt 1) {
        $paths = ($candidates.FullName -join "`n")
        throw "Found multiple node.exe candidates under $($ResourcesDir):`n$paths"
    }

    $version = $candidates[0].VersionInfo.ProductVersion
    if ($version -match "^\d+\.\d+\.\d+") {
        return $Matches[0]
    }

    throw "Could not determine bundled Node.js version from $($candidates[0].FullName)"
}

function Use-Asar {
    param(
        [string[]]$Arguments
    )

    Require-CommandPath "pnpm" | Out-Null
    Invoke-Checked "pnpm" (@("dlx", "@electron/asar") + $Arguments)
}

function Extract-AsarTolerant {
    param(
        [string]$AsarPath,
        [string]$Destination
    )

    $node = Require-CommandPath "node"
    $extractScript = Get-Content -LiteralPath (Join-Path $script:Context.Paths.RepoRoot "src\CodexWoA.Build\Tools\extract-asar-tolerant.js") -Raw

    Invoke-Checked $node @("-e", $extractScript, $AsarPath, $Destination)
}

function Extract-AppAsar {
    param(
        [string]$ResourcesDir,
        [string]$Destination
    )

    $asarPath = Join-Path $ResourcesDir "app.asar"
    New-CleanDirectory $Destination | Out-Null
    Extract-AsarTolerant $asarPath $Destination

    $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"
    if (Test-Path -LiteralPath $unpacked) {
        Copy-DirectoryRobust $unpacked $Destination -Mode Merge
    }
}

function Repack-AppAsar {
    param(
        [string]$ExtractedDir,
        [string]$ResourcesDir
    )

    $asarPath = Join-Path $ResourcesDir "app.asar"
    $unpackedPath = Join-Path $ResourcesDir "app.asar.unpacked"
    Remove-IfExists $asarPath
    Remove-IfExists $unpackedPath
    Use-Asar @("pack", $ExtractedDir, $asarPath, "--unpack", "{*.node,*.dll,*.exe,codex,bwrap}")
}

function Patch-OwlFeatureBindingFallback {
    param([string]$AsarExtractDir)

    $bindingName = "electron_common_owl_features"
    $fallbackMarker = "isOwlFeatureEnabled:()=>!1"
    $pattern = 'function\s+(?<fn>[A-Za-z_$][A-Za-z0-9_$]*)\(\)\{let\s+(?<binding>[A-Za-z_$][A-Za-z0-9_$]*)=process\._linkedBinding;if\(typeof\s+\k<binding>!=`function`\)throw Error\(`Owl feature binding is unavailable`\);return\s+(?<schema>[A-Za-z_$][A-Za-z0-9_$]*)\.parse\(\k<binding>\.call\(process,`electron_common_owl_features`\)\)\}'
    $changed = New-Object "System.Collections.Generic.List[string]"

    $javascriptFiles = @(Get-ChildItem -LiteralPath $AsarExtractDir -Recurse -File -Filter "*.js" -ErrorAction Stop)
    foreach ($file in $javascriptFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        if (-not $content.Contains($bindingName)) {
            continue
        }
        if ($content.Contains($fallbackMarker)) {
            continue
        }

        $matches = [regex]::Matches($content, $pattern)
        if ($matches.Count -eq 0) {
            throw "Found $bindingName in $($file.FullName), but the Owl feature binding bootstrap shape was not recognized."
        }

        $patched = [regex]::Replace($content, $pattern, {
            param($match)

            $fn = $match.Groups["fn"].Value
            $binding = $match.Groups["binding"].Value
            $schema = $match.Groups["schema"].Value
            return "function $fn(){let $binding=process._linkedBinding;if(typeof $binding!=``function``)return{isOwlFeatureEnabled:()=>!1};try{return $schema.parse($binding.call(process,``electron_common_owl_features``))}catch{return{isOwlFeatureEnabled:()=>!1}}}"
        })

        Set-TextUtf8NoBom $file.FullName $patched
        $changed.Add((Get-RelativePath $AsarExtractDir $file.FullName)) | Out-Null
    }

    if ($changed.Count -gt 0) {
        Add-Replacement "owl-feature-binding-fallback" "patched" ($changed -join ", ")
    }
}
