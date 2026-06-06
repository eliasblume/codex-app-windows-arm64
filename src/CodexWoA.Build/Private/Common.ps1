function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    $script:Context.Report.warnings.Add($Message)
    Write-Warning $Message
}

function Add-Replacement {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    $script:Context.Report.replacements.Add([ordered]@{
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

function Get-SupplyChainPolicy {
    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $contextVariable -and
        $null -ne $contextVariable.Value -and
        $null -ne $contextVariable.Value.SupplyChainPolicy) {
        return $contextVariable.Value.SupplyChainPolicy
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
    if ($null -eq $contextVariable -or
        $null -eq $contextVariable.Value -or
        $null -eq $contextVariable.Value.Report -or
        $null -eq $contextVariable.Value.Report.supplyChain) {
        return
    }

    $contextVariable.Value.Report.supplyChain.Add($Evidence) | Out-Null
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

function Get-NodeReleaseChecksum {
    param(
        [string]$NodeVersion,
        [string]$AssetName,
        [string]$CacheDir
    )

    $checksumsName = (Get-SupplyChainPolicy).Node.ChecksumsFile
    if ([string]::IsNullOrWhiteSpace($checksumsName)) {
        throw "Node checksum policy is missing a checksums file name."
    }

    $checksumsPath = Join-Path $CacheDir "node-v$NodeVersion-$checksumsName"
    $url = "https://nodejs.org/dist/v$NodeVersion/$checksumsName"
    if (-not (Test-Path -LiteralPath $checksumsPath)) {
        Download-File $url $checksumsPath
    }

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
    }

    return $Destination
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












































































































































