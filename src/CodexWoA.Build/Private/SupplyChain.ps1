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
    if (-not (Test-Path -LiteralPath $Destination)) {
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

    if (-not (Test-Path -LiteralPath $Destination)) {
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

    $gitGpg = "C:\Program Files\Git\usr\bin\gpg.exe"
    if (Test-Path -LiteralPath $gitGpg) {
        return $gitGpg
    }

    throw "Required command not found: gpg. Install GnuPG or Git for Windows with gpg.exe to verify Node release checksums."
}

function Assert-SupplyChainBuildPrerequisites {
    $nodePolicy = (Get-SupplyChainPolicy).Node
    if (-not [bool]$nodePolicy.RequireSignedChecksums) {
        return
    }

    Write-Step "Checking supply-chain signature verification tools"
    $git = Require-CommandPath "git"
    $gpg = Get-GpgCommandPath
    $script:Context.Report.tools.git = $git
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

function Get-NodeReleaseKeyringDirectory {
    param(
        [object]$NodePolicy,
        [string]$CacheDir
    )

    if ([string]::IsNullOrWhiteSpace([string]$NodePolicy.ReleaseKeysRepo)) {
        throw "Node release keyring policy is missing ReleaseKeysRepo."
    }
    if ([string]::IsNullOrWhiteSpace([string]$NodePolicy.ReleaseKeysRef)) {
        throw "Node release keyring policy is missing ReleaseKeysRef."
    }
    if ([string]::IsNullOrWhiteSpace([string]$NodePolicy.ReleaseKeysGpgDirectory)) {
        throw "Node release keyring policy is missing ReleaseKeysGpgDirectory."
    }

    $git = Require-CommandPath "git"
    $keysRoot = Join-Path $CacheDir "node-release-keys"
    if (-not (Test-Path -LiteralPath (Join-Path $keysRoot ".git"))) {
        Remove-IfExists $keysRoot
        Invoke-Checked $git @(
            "clone",
            "--depth", "1",
            "--branch", [string]$NodePolicy.ReleaseKeysRef,
            [string]$NodePolicy.ReleaseKeysRepo,
            $keysRoot
        ) | Out-Null
    }
    else {
        Push-Location $keysRoot
        try {
            Invoke-Checked $git @("fetch", "--depth", "1", "origin", [string]$NodePolicy.ReleaseKeysRef) | Out-Null
            Invoke-Checked $git @("checkout", "--detach", "FETCH_HEAD") | Out-Null
        }
        finally {
            Pop-Location
        }
    }

    $gpgDir = Join-Path $keysRoot ([string]$NodePolicy.ReleaseKeysGpgDirectory)
    if (-not (Test-Path -LiteralPath $gpgDir)) {
        throw "Node release keyring directory was not found: $gpgDir"
    }

    return $gpgDir
}

function Assert-NodeChecksumsSignature {
    param(
        [string]$ChecksumsPath,
        [object]$NodePolicy,
        [string]$CacheDir
    )

    if (-not [bool]$NodePolicy.RequireSignedChecksums) {
        return
    }

    $gpg = Get-GpgCommandPath
    $keyringDir = Get-NodeReleaseKeyringDirectory $NodePolicy $CacheDir
    Invoke-Checked $gpg @(
        "--homedir", (ConvertTo-GpgPath $keyringDir $gpg),
        "--verify", (ConvertTo-GpgPath $ChecksumsPath $gpg)
    ) | Out-Null
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
    Assert-NodeChecksumsSignature $checksumsPath $nodePolicy $CacheDir

    $match = Get-Content -LiteralPath $checksumsPath |
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
