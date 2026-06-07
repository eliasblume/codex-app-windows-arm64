function Resolve-CodexStorePackage {
    [CmdletBinding()]
    param(
        [string]$ProductId = "9PLM9XGG6VKS",
        [string]$Repo = "",
        [string]$Ring = "Retail",
        [string]$Lang = "en-US",
        [string]$VersionOverride = "",
        [string]$Html = ""
    )

    $storePackage = if ([string]::IsNullOrWhiteSpace($Html)) {
        Resolve-LatestStoreMsix -ProductId $ProductId -Ring $Ring -Lang $Lang
    }
    else {
        ConvertFrom-CodexStoreHtml $Html
    }

    $latestTag = "0.0.0"
    $latestReleaseWarning = ""
    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $gh = Get-Command "gh" -ErrorAction SilentlyContinue
        if ($null -eq $gh) {
            $latestReleaseWarning = "GitHub CLI 'gh' was not found; latest release comparison fell back to 0.0.0."
            Write-Warning $latestReleaseWarning
        }
        else {
            try {
                $resolvedLatestTag = & $gh.Source release view --repo $Repo --json tagName --jq ".tagName" 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedLatestTag)) {
                    $latestTag = $resolvedLatestTag
                }
                else {
                    $latestReleaseWarning = "GitHub CLI 'gh' could not resolve the latest release for $Repo; latest release comparison fell back to 0.0.0."
                    Write-Warning $latestReleaseWarning
                }
            }
            catch {
                $latestReleaseWarning = "GitHub CLI 'gh' failed while resolving $Repo; latest release comparison fell back to 0.0.0. $($_.Exception.Message)"
                Write-Warning $latestReleaseWarning
            }
        }
    }

    $latestReleaseVersion = ConvertTo-FourPartVersion $latestTag
    $resolvedOverride = Resolve-PackageVersionOverride $VersionOverride
    $effectivePackageVersion = $storePackage.Version
    $releaseTag = $storePackage.Version.ToString(3)
    $shouldBuild = $storePackage.Version -gt $latestReleaseVersion
    if (-not [string]::IsNullOrWhiteSpace($resolvedOverride)) {
        $effectivePackageVersion = [version]$resolvedOverride
        $releaseTag = $resolvedOverride
        $shouldBuild = $true
    }

    return [pscustomobject][ordered]@{
        shouldBuild = $shouldBuild
        storeVersion = $storePackage.Version.ToString()
        packageVersion = $effectivePackageVersion.ToString()
        releaseTag = $releaseTag
        msixUrl = $storePackage.Url
        msixFile = $storePackage.File
        msixSha1 = $storePackage.Sha1
        msixExpire = $storePackage.Expire
        latestReleaseTag = $latestTag
        latestReleaseWarning = $latestReleaseWarning
    }
}
