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

function Get-SupplyChainPolicy {
    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $contextVariable -and $null -ne $contextVariable.Value) {
        $policyProperty = $contextVariable.Value.PSObject.Properties["SupplyChainPolicy"]
        if ($null -ne $policyProperty -and $null -ne $policyProperty.Value) {
            return $policyProperty.Value
        }
    }

    return Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot "Data\SupplyChainPolicy.psd1")
}

function Assert-SafeScalarValue {
    param(
        [string]$Name,
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -match "[\x00-\x1F\x7F]") {
        throw "$Name contains a control character and cannot cross a trust boundary."
    }
}

function Assert-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Label = $Path
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash) -or $ExpectedHash -notmatch "^[a-fA-F0-9]{64}$") {
        throw "Missing SHA-256 policy for $Label."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "$Label SHA-256 mismatch. Expected $($ExpectedHash.ToUpperInvariant()) but got $actualHash."
    }
}

function Add-SupplyChainEvidence {
    param([hashtable]$Evidence)

    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $contextVariable -or $null -eq $contextVariable.Value) {
        return
    }

    $reportProperty = $contextVariable.Value.PSObject.Properties["Report"]
    if ($null -eq $reportProperty -or $null -eq $reportProperty.Value) {
        return
    }

    $report = $reportProperty.Value
    if ($report -is [System.Collections.IDictionary]) {
        $supplyChain = $report["supplyChain"]
    }
    else {
        $supplyChainProperty = $report.PSObject.Properties["supplyChain"]
        $supplyChain = if ($null -ne $supplyChainProperty) { $supplyChainProperty.Value } else { $null }
    }

    if ($null -eq $supplyChain) {
        return
    }

    $supplyChain.Add($Evidence) | Out-Null
}

function Download-VerifiedGitHubReleaseAsset {
    param(
        [object]$Release,
        [string]$Owner,
        [string]$Repo,
        [string]$AssetName,
        [string]$Destination,
        [string]$AssetNamePattern,
        [string]$Label
    )

    if ($AssetName -notmatch $AssetNamePattern) {
        throw "$Label asset name is not allowed by policy: $AssetName"
    }

    $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if ($null -eq $asset) {
        throw "Release asset not found: $AssetName"
    }

    $digest = [string]$asset.digest
    if ($digest -notmatch "^sha256:[a-fA-F0-9]{64}$") {
        throw "$Label asset $AssetName does not expose a SHA-256 digest."
    }

    $expectedHash = $digest.Substring("sha256:".Length).ToUpperInvariant()
    if (Test-Path -LiteralPath $Destination) {
        try {
            Assert-FileSha256 $Destination $expectedHash $AssetName
        }
        catch {
            Write-Warn "Cached $Label asset $AssetName did not match release digest; refreshing cached download."
            Remove-IfExists $Destination
            Download-File $asset.browser_download_url $Destination
        }
    }
    else {
        Download-File $asset.browser_download_url $Destination
    }

    Assert-FileSha256 $Destination $expectedHash $AssetName
    Add-SupplyChainEvidence @{
        kind = "GitHubReleaseAsset"
        label = $Label
        owner = $Owner
        repo = $Repo
        tag = $Release.tag_name
        assetName = $AssetName
        assetId = $asset.id
        digest = $digest
        url = $asset.browser_download_url
    }

    return $Destination
}

function Get-GitHubRelease {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Tag
    )

    $headers = @{ Accept = "application/vnd.github+json" }
    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -eq "latest") {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $headers
    }

    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" -Headers $headers
}

function Get-GitHubReleaseFromPolicy {
    param(
        [string]$PolicyName,
        [string]$RequestedTag,
        [string]$Label
    )

    $releasePolicy = (Get-SupplyChainPolicy).GitHubReleases[$PolicyName]
    if ($null -eq $releasePolicy) {
        throw "No GitHub release policy exists for $PolicyName."
    }

    $release = Get-GitHubRelease $releasePolicy.Owner $releasePolicy.Repo $RequestedTag
    if ($release.draft) {
        throw "$Label release $($release.tag_name) is a draft release."
    }
    if ($release.prerelease -and -not [bool]$releasePolicy.AllowPrerelease) {
        throw "$Label release $($release.tag_name) is a prerelease and prereleases are not allowed."
    }

    return [pscustomobject][ordered]@{
        Release = $release
        Owner = $releasePolicy.Owner
        Repo = $releasePolicy.Repo
        AssetNamePattern = $releasePolicy.AssetNamePattern
    }
}

function Download-VerifiedDirectDownload {
    param(
        [string]$PolicyName,
        [string]$Destination,
        [string]$Label
    )

    $downloadPolicy = (Get-SupplyChainPolicy).DirectDownloads[$PolicyName]
    if ($null -eq $downloadPolicy) {
        throw "No direct download policy exists for $PolicyName."
    }

    $assetName = [string]$downloadPolicy.AssetName
    if ([string]::IsNullOrWhiteSpace($assetName)) {
        throw "Direct download policy for $PolicyName is missing AssetName."
    }
    if ([string]::IsNullOrWhiteSpace([string]$downloadPolicy.Url)) {
        throw "Direct download policy for $PolicyName is missing Url."
    }

    if (Test-Path -LiteralPath $Destination) {
        try {
            Assert-FileSha256 $Destination ([string]$downloadPolicy.Sha256) $assetName
        }
        catch {
            Write-Warn "Cached $Label asset $assetName did not match policy hash; refreshing cached download."
            Remove-IfExists $Destination
            Download-File ([string]$downloadPolicy.Url) $Destination
        }
    }
    else {
        Download-File ([string]$downloadPolicy.Url) $Destination
    }

    Assert-FileSha256 $Destination ([string]$downloadPolicy.Sha256) $assetName
    Add-SupplyChainEvidence @{
        kind = "DirectDownload"
        label = $Label
        version = [string]$downloadPolicy.Version
        assetName = $assetName
        digest = "sha256:$([string]$downloadPolicy.Sha256)"
        url = [string]$downloadPolicy.Url
    }

    return $Destination
}

function Get-GpgCommandPath {
    $command = Get-Command "gpg" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    foreach ($gitRoot in Get-GitRootCandidates) {
        foreach ($relativePath in @("usr\bin\gpg.exe", "bin\gpg.exe")) {
            $candidate = Join-Path $gitRoot $relativePath
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    throw "Required command not found: gpg. Install GnuPG or Git for Windows with gpg.exe to verify Node release checksums."
}

function Get-GitRootCandidates {
    $roots = New-Object "System.Collections.Generic.List[string]"
    $seen = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)

    function Add-GitRootCandidate {
        param([AllowNull()][string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        try {
            $fullPath = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return
        }

        if ($seen.Add($fullPath)) {
            $roots.Add($fullPath) | Out-Null
        }
    }

    function Add-GitAncestorCandidates {
        param([AllowNull()][string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        try {
            $directory = if ([System.IO.Directory]::Exists($Path)) {
                [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path))
            }
            else {
                [System.IO.FileInfo]::new([System.IO.Path]::GetFullPath($Path)).Directory
            }
        }
        catch {
            return
        }

        for ($i = 0; $null -ne $directory -and $i -lt 8; $i++) {
            Add-GitRootCandidate $directory.FullName
            $directory = $directory.Parent
        }
    }

    $gitCommand = Get-Command "git" -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand -and -not [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
        Add-GitAncestorCandidates $gitCommand.Source

        try {
            $execPath = (& $gitCommand.Source --exec-path 2>$null | Select-Object -First 1)
            Add-GitAncestorCandidates ([string]$execPath)
        }
        catch {
            # Best effort only; git's executable path already provides candidates.
        }
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            Add-GitRootCandidate (Join-Path $base "Git")
        }
    }

    return $roots.ToArray()
}

function Assert-SupplyChainBuildPrerequisites {
    $nodePolicy = (Get-SupplyChainPolicy).Node
    if (-not [bool]$nodePolicy.RequireSignedChecksums) {
        return
    }

    Write-Step "Checking supply-chain signature verification tools"
    $gpg = Get-GpgCommandPath
    $script:Context.Report.tools.gpg = $gpg
}

function ConvertTo-GpgPath {
    param(
        [string]$Path,
        [string]$GpgPath
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($GpgPath -match "\\Git\\usr\\bin\\gpg\.exe$" -and $fullPath -match "^(?<drive>[A-Za-z]):\\(?<rest>.*)$") {
        return "/$($matches.drive.ToLowerInvariant())/" + ($matches.rest -replace "\\", "/")
    }

    return $fullPath
}

function Get-NodeReleaseKeysDirectory {
    param(
        [object]$NodePolicy
    )

    if ([string]::IsNullOrWhiteSpace([string]$NodePolicy.ReleaseKeysDirectory)) {
        throw "Node release keyring policy is missing ReleaseKeysDirectory."
    }

    $keysDirectory = [string]$NodePolicy.ReleaseKeysDirectory
    if (-not [System.IO.Path]::IsPathRooted($keysDirectory)) {
        $keysDirectory = Join-Path $script:ModuleRoot $keysDirectory
    }

    if (-not (Test-Path -LiteralPath $keysDirectory)) {
        throw "Node release keyring directory was not found: $keysDirectory"
    }

    $keyFiles = @(Get-ChildItem -LiteralPath $keysDirectory -File -Filter "*.asc" -ErrorAction SilentlyContinue)
    if ($keyFiles.Count -eq 0) {
        throw "Node release keyring directory does not contain public keys: $keysDirectory"
    }

    return (Resolve-Path -LiteralPath $keysDirectory).Path
}

function New-NodeReleaseGpgHome {
    param(
        [object]$NodePolicy,
        [string]$CacheDir,
        [string]$GpgPath
    )

    $keysDirectory = Get-NodeReleaseKeysDirectory $NodePolicy
    $keyFiles = @(Get-ChildItem -LiteralPath $keysDirectory -File -Filter "*.asc" | Sort-Object Name)
    $gpgHome = Join-Path $CacheDir "node-release-keyring"
    New-CleanDirectoryUnderRoot $gpgHome $CacheDir | Out-Null

    $importPaths = @($keyFiles | ForEach-Object { ConvertTo-GpgPath $_.FullName $GpgPath })
    Invoke-Checked $GpgPath (@(
        "--homedir", (ConvertTo-GpgPath $gpgHome $GpgPath),
        "--import"
    ) + $importPaths) | Out-Null

    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $contextVariable -and $null -ne $contextVariable.Value) {
        $reportProperty = $contextVariable.Value.PSObject.Properties["Report"]
        if ($null -ne $reportProperty -and $null -ne $reportProperty.Value) {
            $report = $reportProperty.Value
            $tools = if ($report -is [System.Collections.IDictionary]) {
                $report["tools"]
            }
            else {
                $report.tools
            }
            if ($tools -is [System.Collections.IDictionary]) {
                $tools["nodeReleaseKeys"] = $keysDirectory
            }
            else {
                $tools.nodeReleaseKeys = $keysDirectory
            }
        }
    }

    return $gpgHome
}

function Assert-NodeChecksumsSignature {
    param(
        [string]$ChecksumsPath,
        [object]$NodePolicy,
        [string]$CacheDir
    )

    if (-not [bool]$NodePolicy.RequireSignedChecksums) {
        return @(Get-Content -LiteralPath $ChecksumsPath)
    }

    $gpg = Get-GpgCommandPath
    $keyringDir = New-NodeReleaseGpgHome $NodePolicy $CacheDir $gpg
    $verifiedPath = Join-Path $CacheDir ("node-checksums-verified-" + [guid]::NewGuid().ToString("N") + ".txt")
    try {
        Invoke-Checked $gpg @(
            "--batch",
            "--yes",
            "--homedir", (ConvertTo-GpgPath $keyringDir $gpg),
            "--output", (ConvertTo-GpgPath $verifiedPath $gpg),
            "--decrypt", (ConvertTo-GpgPath $ChecksumsPath $gpg)
        ) | Out-Null

        if (-not (Test-Path -LiteralPath $verifiedPath)) {
            throw "GPG did not emit verified Node checksum cleartext: $ChecksumsPath"
        }

        return @(Get-Content -LiteralPath $verifiedPath)
    }
    finally {
        Remove-IfExists $verifiedPath
    }
}

function Get-NodeReleaseChecksum {
    param(
        [string]$NodeVersion,
        [string]$AssetName,
        [string]$CacheDir
    )

    $nodePolicy = (Get-SupplyChainPolicy).Node
    $checksumsName = $nodePolicy.ChecksumsFile
    if ([string]::IsNullOrWhiteSpace($checksumsName)) {
        throw "Node checksum policy is missing a checksums file name."
    }

    $checksumsPath = Join-Path $CacheDir "node-v$NodeVersion-$checksumsName"
    $url = "https://nodejs.org/dist/v$NodeVersion/$checksumsName"
    if (-not (Test-Path -LiteralPath $checksumsPath)) {
        Download-File $url $checksumsPath
    }
    $verifiedChecksums = Assert-NodeChecksumsSignature $checksumsPath $nodePolicy $CacheDir

    $match = $verifiedChecksums |
        Where-Object { $_ -match "^\s*(?<hash>[a-fA-F0-9]{64})\s+$([regex]::Escape($AssetName))\s*$" } |
        Select-Object -First 1
    if ($null -eq $match) {
        throw "Node checksum file did not contain $AssetName."
    }

    $expectedHash = [regex]::Match($match, "^\s*(?<hash>[a-fA-F0-9]{64})").Groups["hash"].Value.ToUpperInvariant()
    return [pscustomobject][ordered]@{
        Hash = $expectedHash
        Url = $url
        Path = $checksumsPath
        Signature = "verified"
    }
}

function Download-VerifiedNodeReleaseFile {
    param(
        [string]$NodeVersion,
        [string]$AssetName,
        [string]$Destination,
        [string]$CacheDir
    )

    $url = "https://nodejs.org/dist/v$NodeVersion/$AssetName"
    if (-not (Test-Path -LiteralPath $Destination)) {
        Download-File $url $Destination
    }

    $checksum = Get-NodeReleaseChecksum $NodeVersion $AssetName $CacheDir
    Assert-FileSha256 $Destination $checksum.Hash $AssetName
    Add-SupplyChainEvidence @{
        kind = "NodeReleaseAsset"
        label = "node"
        version = $NodeVersion
        assetName = $AssetName
        digest = "sha256:$($checksum.Hash)"
        url = $url
        checksumUrl = $checksum.Url
        checksumSignature = $checksum.Signature
    }

    return $Destination
}
