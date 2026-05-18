#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProductId = "9PLM9XGG6VKS",
    [string]$Repo = $env:GITHUB_REPOSITORY,
    [string]$Ring = "Retail",
    [string]$Lang = "en-US"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-TagToVersion {
    param([string]$Tag)

    $match = [regex]::Match($Tag, "\d+\.\d+\.\d+(?:\.\d+)?")
    if (-not $match.Success) {
        return [version]"0.0.0.0"
    }

    $value = $match.Value
    if (($value.Split(".")).Count -eq 3) {
        $value = "$value.0"
    }

    return [version]$value
}

function Add-GitHubOutput {
    param(
        [string]$Name,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        "$Name=$Value" >> $env:GITHUB_OUTPUT
    }
}

$response = Invoke-WebRequest -UseBasicParsing `
    -Uri "https://store.rg-adguard.net/api/GetFiles" `
    -Method POST `
    -Headers @{
        Accept = "*/*"
        Origin = "https://store.rg-adguard.net"
        Referer = "https://store.rg-adguard.net/"
    } `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "type=ProductId&url=$ProductId&ring=$Ring&lang=$Lang"

$html = [string]$response.Content
$rowPattern = '<tr[^>]*>.*?<a\s+[^>]*href="(?<href>[^"]+)"[^>]*>(?<file>OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_x64__[^<]+\.msix)</a>.*?<td[^>]*>(?<expire>[^<]*)</td>.*?<td[^>]*>(?<sha1>[a-fA-F0-9]{40})</td>.*?<td[^>]*>(?<size>[^<]*)</td>.*?</tr>'
$matches = [regex]::Matches($html, $rowPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)

if ($matches.Count -eq 0) {
    throw "Could not find OpenAI.Codex x64 MSIX in rg-adguard response."
}

$storePackage = $matches |
    ForEach-Object {
        [pscustomobject]@{
            Version = [version]$_.Groups["version"].Value
            File = [System.Net.WebUtility]::HtmlDecode($_.Groups["file"].Value)
            Url = [System.Net.WebUtility]::HtmlDecode($_.Groups["href"].Value)
            Sha1 = $_.Groups["sha1"].Value.ToUpperInvariant()
            Expire = [System.Net.WebUtility]::HtmlDecode($_.Groups["expire"].Value)
            Size = [System.Net.WebUtility]::HtmlDecode($_.Groups["size"].Value)
        }
    } |
    Sort-Object Version -Descending |
    Select-Object -First 1

$latestTag = "0.0.0"
if (-not [string]::IsNullOrWhiteSpace($Repo)) {
    try {
        $resolvedLatestTag = gh release view --repo $Repo --json tagName --jq ".tagName" 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedLatestTag)) {
            $latestTag = $resolvedLatestTag
        }
    }
    catch {
        $latestTag = "0.0.0"
    }
}

$latestReleaseVersion = Convert-TagToVersion $latestTag
$shouldBuild = $storePackage.Version -gt $latestReleaseVersion
$releaseTag = $storePackage.Version.ToString(3)

Write-Host "Store version:  $($storePackage.Version)"
Write-Host "Release tag:    $releaseTag"
Write-Host "Latest release: $latestTag ($latestReleaseVersion)"
Write-Host "MSIX file:      $($storePackage.File)"
Write-Host "MSIX SHA-1:     $($storePackage.Sha1)"
Write-Host "MSIX expires:   $($storePackage.Expire)"
Write-Host "Should build:   $shouldBuild"

Add-GitHubOutput "should_build" $shouldBuild.ToString().ToLowerInvariant()
Add-GitHubOutput "store_version" $storePackage.Version.ToString()
Add-GitHubOutput "release_tag" $releaseTag
Add-GitHubOutput "msix_url" $storePackage.Url
Add-GitHubOutput "msix_file" $storePackage.File
Add-GitHubOutput "msix_sha1" $storePackage.Sha1

[pscustomobject]@{
    shouldBuild = $shouldBuild
    storeVersion = $storePackage.Version.ToString()
    releaseTag = $releaseTag
    msixUrl = $storePackage.Url
    msixFile = $storePackage.File
    msixSha1 = $storePackage.Sha1
    latestReleaseTag = $latestTag
} | ConvertTo-Json -Depth 4

exit 0
