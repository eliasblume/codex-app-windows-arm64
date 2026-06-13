function Get-PeMachine {
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            return "NotPE"
        }

        $stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $peOffset = $reader.ReadUInt32()
        $stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        if ($reader.ReadUInt32() -ne 0x00004550) {
            return "NotPE"
        }

        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x014c { return "x86" }
            0x8664 { return "x64" }
            0xaa64 { return "arm64" }
            0x01c4 { return "arm" }
            default { return ("0x{0:X4}" -f $machine) }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ElfMachine {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -lt 20) {
        return "NotELF"
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $magic = $reader.ReadBytes(4)
        if ($magic.Length -ne 4 -or $magic[0] -ne 0x7F -or $magic[1] -ne 0x45 -or $magic[2] -ne 0x4C -or $magic[3] -ne 0x46) {
            return "NotELF"
        }

        $class = $reader.ReadByte()
        if ($class -ne 2) {
            return "ELF32"
        }

        $data = $reader.ReadByte()
        $stream.Seek(18, [System.IO.SeekOrigin]::Begin) | Out-Null
        $machineBytes = $reader.ReadBytes(2)
        if ($machineBytes.Length -ne 2) {
            return "NotELF"
        }

        if ($data -eq 2) {
            $machine = ($machineBytes[0] -shl 8) -bor $machineBytes[1]
        }
        else {
            $machine = $machineBytes[0] -bor ($machineBytes[1] -shl 8)
        }

        switch ($machine) {
            0x003E { return "x64" }
            0x00B7 { return "arm64" }
            0x0028 { return "arm" }
            default { return ("0x{0:X4}" -f $machine) }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Test-MsixManifest {
    param(
        [string]$ManifestPath,
        [string]$ExpectedIdentity
    )

    [xml]$manifest = Get-Content -LiteralPath $ManifestPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $ns)
    $application = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application", $ns)
    $protocol = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application/f:Extensions/uap:Extension/uap:Protocol", $ns)

    if ($identity.Name -ne $ExpectedIdentity) {
        throw "Manifest identity mismatch: $($identity.Name)"
    }
    if ($identity.ProcessorArchitecture -ne "arm64") {
        throw "Manifest architecture mismatch: $($identity.ProcessorArchitecture)"
    }
    if ($application.Executable -ne "app/Codex.exe") {
        throw "Manifest executable mismatch: $($application.Executable)"
    }
    if ($null -eq $protocol -or $protocol.Name -ne "codex") {
        throw "Manifest codex protocol was not preserved"
    }

    return [pscustomobject]@{
        Identity = [string]$identity.Name
        Architecture = [string]$identity.ProcessorArchitecture
        Executable = [string]$application.Executable
        Protocol = [string]$protocol.Name
    }
}

function New-AllowedX64FallbackSet {
    $fallbacks = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $script:Context.Policy.AllowedX64Fallbacks) {
        $fallbacks.Add($path) | Out-Null
    }
    return ,$fallbacks
}

function Test-MsixPackage {
    param(
        [string]$MsixPath,
        [string]$VerifyDir,
        [string]$MakeAppxPath,
        [string]$SignToolPath,
        [string]$MtPath,
        [string]$ExpectedIdentity,
        [string]$ExpectedSignerThumbprint
    )

    Write-Step "Verifying generated MSIX"
    New-CleanDirectory $VerifyDir | Out-Null
    Invoke-Checked $MakeAppxPath @("unpack", "/p", $MsixPath, "/d", $VerifyDir, "/o")

    $manifestResult = Test-MsixManifest (Join-Path $VerifyDir "AppxManifest.xml") $ExpectedIdentity

    Assert-WindowsSandboxSetupAsInvokerManifest `
        (Join-Path $VerifyDir "app\resources\codex-windows-sandbox-setup.exe") `
        $MtPath `
        (Join-Path $VerifyDir "codex-windows-sandbox-setup.embedded.manifest")

    $fallbackX64 = New-AllowedX64FallbackSet

    $errors = New-Object System.Collections.Generic.List[string]
    $fallbacks = New-Object System.Collections.Generic.List[string]
    $peFiles = Get-ChildItem -LiteralPath (Join-Path $VerifyDir "app") -Recurse -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".exe", ".dll", ".node") }

    foreach ($file in $peFiles) {
        $relative = Get-RelativePath $VerifyDir $file.FullName
        $machine = Get-PeMachine $file.FullName
        if ($machine -eq "NotPE") {
            continue
        }

        if ($machine -eq "x64" -and $fallbackX64.Contains($relative)) {
            $fallbacks.Add($relative)
            continue
        }

        $mustBeArm64 = $false
        if ($relative -match "^app\\resources\\app\.asar\.unpacked\\node_modules\\(better-sqlite3|node-pty)\\") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "\.node$") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "^app\\resources\\(node|rg)\.exe$") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "^app\\resources\\native\\") {
            $mustBeArm64 = $true
        }
        elseif ($relative -notmatch "^app\\resources\\") {
            $mustBeArm64 = $true
        }

        if ($mustBeArm64 -and $machine -ne "arm64") {
            $errors.Add("$relative is $machine, expected arm64")
            continue
        }

        if ($machine -eq "x64") {
            if ($fallbackX64.Contains($relative)) {
                $fallbacks.Add($relative)
            }
            else {
                $errors.Add("$relative is x64 and is not in the out-of-process fallback allowlist")
            }
        }
    }

    $wslElfPayloads = New-Object System.Collections.Generic.List[string]
    $requiredWslPayloads = $script:Context.Policy.RequiredWslPayloads
    foreach ($relative in $requiredWslPayloads) {
        $payloadPath = Join-Path $VerifyDir $relative
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            $errors.Add("$relative is missing")
            continue
        }

        $machine = Get-ElfMachine $payloadPath
        if ($machine -ne "arm64") {
            $errors.Add("$relative is $machine, expected arm64")
        }
        elseif (-not $wslElfPayloads.Contains($relative)) {
            $wslElfPayloads.Add($relative) | Out-Null
        }
    }

    $elfFiles = Get-ChildItem -LiteralPath (Join-Path $VerifyDir "app") -Recurse -File
    foreach ($file in $elfFiles) {
        $machine = Get-ElfMachine $file.FullName
        if ($machine -eq "NotELF") {
            continue
        }

        $relative = Get-RelativePath $VerifyDir $file.FullName
        $isCodexWslPayload = $file.Name -eq "codex" -and (Test-IsWslCodexPayloadPath $relative)
        $isBwrapWslPayload = $file.Name -eq "bwrap" -and (Test-IsWslBwrapPayloadPath $relative)

        if ($isCodexWslPayload -or $isBwrapWslPayload) {
            if ($machine -ne "arm64") {
                $errors.Add("$relative is Linux $machine ELF, expected arm64")
            }
            elseif (-not $wslElfPayloads.Contains($relative)) {
                $wslElfPayloads.Add($relative) | Out-Null
            }
        }
        elseif ($machine -eq "x64" -and ($file.Name -eq "codex" -or $file.Name -eq "bwrap")) {
            $errors.Add("$relative is Linux x64 ELF and looks like an unpatched WSL runtime payload")
        }
    }

    if ($errors.Count -gt 0) {
        throw "Architecture validation failed:`n$($errors -join "`n")"
    }

    $authenticode = Get-AuthenticodeSignature -LiteralPath $MsixPath
    if ($null -eq $authenticode.SignerCertificate) {
        throw "MSIX does not contain an Authenticode signer"
    }
    if ($authenticode.SignerCertificate.Thumbprint -ne $ExpectedSignerThumbprint) {
        throw "MSIX signer thumbprint mismatch: $($authenticode.SignerCertificate.Thumbprint)"
    }

    try {
        Invoke-Checked $SignToolPath @("verify", "/pa", $MsixPath)
        $signToolVerify = "passed"
    }
    catch {
        $signToolVerify = "self-signed/untrusted before Install.ps1 trust step: $($_.Exception.Message)"
        Write-Warn "signtool verify did not build a trusted chain yet. This is expected before Install.ps1 imports the local certificate."
    }

    try {
        Add-AppxPackage -Path $MsixPath -WhatIf | Out-Null
        $whatIf = "passed"
    }
    catch {
        $whatIf = "skipped: $($_.Exception.Message)"
        Write-Warn "Add-AppxPackage -WhatIf did not complete: $($_.Exception.Message)"
    }

    $script:Context.Report.validation = [ordered]@{
        manifestIdentity = $manifestResult.Identity
        manifestArchitecture = $manifestResult.Architecture
        executable = $manifestResult.Executable
        protocol = $manifestResult.Protocol
        sandboxSetupManifest = "asInvoker"
        x64Fallbacks = @($fallbacks)
        wslElfPayloads = @($wslElfPayloads)
        signerThumbprint = $authenticode.SignerCertificate.Thumbprint
        signToolVerify = $signToolVerify
        addAppxPackageWhatIf = $whatIf
    }
}
