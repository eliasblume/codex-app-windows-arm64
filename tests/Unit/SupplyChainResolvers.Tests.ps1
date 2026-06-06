$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "Supply-chain resolvers" {
    BeforeEach {
        $script:testRoot = Join-Path $TestDrive "supply-chain"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    It "verifies a GitHub release asset against its API digest" {
        $assetPath = Join-Path $script:testRoot "tool.zip"
        Set-Content -LiteralPath $assetPath -Value "trusted bytes" -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
        $release = [pscustomobject]@{
            tag_name = "v1.2.3"
            assets = @([pscustomobject]@{
                    name = "tool.zip"
                    id = 123
                    digest = "sha256:$hash"
                    browser_download_url = "https://example.test/tool.zip"
                })
        }

        $result = & (Get-Module CodexWoA.Build) {
            param($Release, $Path)
            Download-VerifiedGitHubReleaseAsset `
                -Release $Release `
                -Owner "owner" `
                -Repo "repo" `
                -AssetName "tool.zip" `
                -Destination $Path `
                -AssetNamePattern "^tool\.zip$" `
                -Label "tool"
        } $release $assetPath

        $result | Should -Be $assetPath
    }

    It "rejects a GitHub release asset without a SHA-256 digest" {
        $assetPath = Join-Path $script:testRoot "tool.zip"
        Set-Content -LiteralPath $assetPath -Value "trusted bytes" -NoNewline
        $release = [pscustomobject]@{
            tag_name = "v1.2.3"
            assets = @([pscustomobject]@{
                    name = "tool.zip"
                    id = 123
                    digest = ""
                    browser_download_url = "https://example.test/tool.zip"
                })
        }

        {
            & (Get-Module CodexWoA.Build) {
                param($Release, $Path)
                Download-VerifiedGitHubReleaseAsset `
                    -Release $Release `
                    -Owner "owner" `
                    -Repo "repo" `
                    -AssetName "tool.zip" `
                    -Destination $Path `
                    -AssetNamePattern "^tool\.zip$" `
                    -Label "tool"
            } $release $assetPath
        } | Should -Throw "*does not expose a SHA-256 digest*"
    }

    It "rejects a GitHub release asset with a digest mismatch" {
        $assetPath = Join-Path $script:testRoot "tool.zip"
        Set-Content -LiteralPath $assetPath -Value "tampered bytes" -NoNewline
        $release = [pscustomobject]@{
            tag_name = "v1.2.3"
            assets = @([pscustomobject]@{
                    name = "tool.zip"
                    id = 123
                    digest = "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                    browser_download_url = "https://example.test/tool.zip"
                })
        }

        {
            & (Get-Module CodexWoA.Build) {
                param($Release, $Path)
                Download-VerifiedGitHubReleaseAsset `
                    -Release $Release `
                    -Owner "owner" `
                    -Repo "repo" `
                    -AssetName "tool.zip" `
                    -Destination $Path `
                    -AssetNamePattern "^tool\.zip$" `
                    -Label "tool"
            } $release $assetPath
        } | Should -Throw "*SHA-256 mismatch*"
    }

    It "rejects prerelease GitHub releases when policy does not allow them" {
        {
            & (Get-Module CodexWoA.Build) {
                function Get-GitHubRelease {
                    [pscustomobject]@{
                        tag_name = "v999.0.0-beta"
                        draft = $false
                        prerelease = $true
                        assets = @()
                    }
                }

                Get-GitHubReleaseFromPolicy "Electron" "latest" "Electron runtime"
            }
        } | Should -Throw "*prerelease*"
    }

    It "rejects a GitHub release asset outside the allowed name pattern" {
        $assetPath = Join-Path $script:testRoot "tool.zip"
        Set-Content -LiteralPath $assetPath -Value "trusted bytes" -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
        $release = [pscustomobject]@{
            tag_name = "v1.2.3"
            assets = @([pscustomobject]@{
                    name = "tool.zip"
                    id = 123
                    digest = "sha256:$hash"
                    browser_download_url = "https://example.test/tool.zip"
                })
        }

        {
            & (Get-Module CodexWoA.Build) {
                param($Release, $Path)
                Download-VerifiedGitHubReleaseAsset `
                    -Release $Release `
                    -Owner "owner" `
                    -Repo "repo" `
                    -AssetName "tool.zip" `
                    -Destination $Path `
                    -AssetNamePattern "^other\.zip$" `
                    -Label "tool"
            } $release $assetPath
        } | Should -Throw "*not allowed by policy*"
    }

    It "extracts and verifies a Node release checksum" {
        $cacheDir = Join-Path $script:testRoot "cache"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $assetName = "node-v1.2.3-win-arm64.zip"
        $assetPath = Join-Path $cacheDir $assetName
        Set-Content -LiteralPath $assetPath -Value "node bytes" -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $cacheDir "node-v1.2.3-SHASUMS256.txt.asc") -Value "$hash  $assetName"

        $result = & (Get-Module CodexWoA.Build) {
            param($AssetName, $Path, $CacheDir)
            Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
        } $assetName $assetPath $cacheDir

        $result | Should -Be $assetPath
    }

    It "fails closed when Node checksums do not mention the asset" {
        $cacheDir = Join-Path $script:testRoot "cache"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $assetName = "node-v1.2.3-win-arm64.zip"
        $assetPath = Join-Path $cacheDir $assetName
        Set-Content -LiteralPath $assetPath -Value "node bytes" -NoNewline
        Set-Content -LiteralPath (Join-Path $cacheDir "node-v1.2.3-SHASUMS256.txt.asc") -Value "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  other.zip"

        {
            & (Get-Module CodexWoA.Build) {
                param($AssetName, $Path, $CacheDir)
                Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
            } $assetName $assetPath $cacheDir
        } | Should -Throw "*did not contain*"
    }
}
