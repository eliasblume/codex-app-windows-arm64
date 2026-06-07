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

    It "verifies a direct-download policy asset against its pinned hash" {
        $assetPath = Join-Path $script:testRoot "tool.exe"
        Set-Content -LiteralPath $assetPath -Value "trusted bytes" -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToUpperInvariant()

        $result = & (Get-Module CodexWoA.Build) {
            param($Path, $Hash)
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    DirectDownloads = @{
                        Tool = @{
                            Version = "v1.0.0"
                            AssetName = "tool.exe"
                            Url = "https://example.test/tool.exe"
                            Sha256 = $Hash
                        }
                    }
                }
            }

            Download-VerifiedDirectDownload "Tool" $Path "tool"
        } $assetPath $hash

        $result | Should -Be $assetPath
    }

    It "lets optional Codex helper replacement fall back when an asset is missing" {
        $resourcesDir = Join-Path $script:testRoot "resources"
        New-Item -ItemType Directory -Path $resourcesDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $resourcesDir "codex-app-server.exe") -Value "original" -NoNewline

        $result = & (Get-Module CodexWoA.Build) {
            param($ResourcesDir, $CacheDir)
            $script:Context = [pscustomobject]@{
                Report = [ordered]@{
                    versions = [ordered]@{}
                    replacements = New-Object System.Collections.Generic.List[object]
                    warnings = New-Object System.Collections.Generic.List[string]
                    supplyChain = New-Object System.Collections.Generic.List[object]
                }
            }

            function Get-GitHubReleaseFromPolicy {
                [pscustomobject][ordered]@{
                    Release = [pscustomobject]@{
                        tag_name = "rust-v0.test"
                        assets = @()
                    }
                    Owner = "openai"
                    Repo = "codex"
                    AssetNamePattern = ".*"
                }
            }

            Install-Arm64CodexHelpers $ResourcesDir $CacheDir "latest"
            [pscustomobject]@{
                WarningCount = $script:Context.Report.warnings.Count
                Fallbacks = @($script:Context.Report.replacements | Where-Object { $_.status -eq "fallback" }).Count
                Original = Get-Content -LiteralPath (Join-Path $ResourcesDir "codex-app-server.exe") -Raw
            }
        } $resourcesDir $script:testRoot

        $result.WarningCount | Should -Be 1
        $result.Fallbacks | Should -Be 1
        $result.Original | Should -Be "original"
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
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    Node = @{
                        ChecksumsFile = "SHASUMS256.txt.asc"
                        RequireSignedChecksums = $true
                        ReleaseKeysRepo = "https://example.test/nodejs/release-keys.git"
                        ReleaseKeysRef = "main"
                        ReleaseKeysGpgDirectory = "gpg"
                    }
                }
            }
            function Assert-NodeChecksumsSignature {
                param($ChecksumsPath, $NodePolicy, $CacheDir)
                $script:signatureInput = $ChecksumsPath
            }
            Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
        } $assetName $assetPath $cacheDir

        $result | Should -Be $assetPath
    }

    It "fails closed when a signed Node checksum mismatches" {
        $cacheDir = Join-Path $script:testRoot "cache"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $assetName = "node-v1.2.3-win-arm64.zip"
        $assetPath = Join-Path $cacheDir $assetName
        Set-Content -LiteralPath $assetPath -Value "node bytes" -NoNewline
        Set-Content -LiteralPath (Join-Path $cacheDir "node-v1.2.3-SHASUMS256.txt.asc") -Value "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  $assetName"

        {
            & (Get-Module CodexWoA.Build) {
                param($AssetName, $Path, $CacheDir)
                $script:Context = [pscustomobject]@{
                    SupplyChainPolicy = @{
                        Node = @{
                            ChecksumsFile = "SHASUMS256.txt.asc"
                            RequireSignedChecksums = $true
                            ReleaseKeysRepo = "https://example.test/nodejs/release-keys.git"
                            ReleaseKeysRef = "main"
                            ReleaseKeysGpgDirectory = "gpg"
                        }
                    }
                }
                function Assert-NodeChecksumsSignature {
                    param($ChecksumsPath, $NodePolicy, $CacheDir)
                }
                Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
            } $assetName $assetPath $cacheDir
        } | Should -Throw "*SHA-256 mismatch*"
    }

    It "requires signed Node checksums when policy opts into strict mode" {
        $cacheDir = Join-Path $script:testRoot "cache"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $assetName = "node-v1.2.3-win-arm64.zip"
        $assetPath = Join-Path $cacheDir $assetName
        Set-Content -LiteralPath $assetPath -Value "node bytes" -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $cacheDir "node-v1.2.3-SHASUMS256.txt.asc") -Value "$hash  $assetName"

        {
            & (Get-Module CodexWoA.Build) {
                param($AssetName, $Path, $CacheDir)
                $script:Context = [pscustomobject]@{
                    SupplyChainPolicy = @{
                        Node = @{
                            ChecksumsFile = "SHASUMS256.txt.asc"
                            RequireSignedChecksums = $true
                            ReleaseKeysRepo = "https://example.test/nodejs/release-keys.git"
                            ReleaseKeysRef = "main"
                            ReleaseKeysGpgDirectory = "gpg"
                        }
                    }
                }
                function Assert-NodeChecksumsSignature {
                    throw "signature verification failed"
                }
                Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
            } $assetName $assetPath $cacheDir
        } | Should -Throw "*signature verification failed*"
    }

    It "converts paths for Git for Windows gpg" {
        $result = & (Get-Module CodexWoA.Build) {
            ConvertTo-GpgPath "C:\repo\dist\cache\node-release-keys\gpg" "C:\Program Files\Git\usr\bin\gpg.exe"
        }

        $result | Should -Be "/c/repo/dist/cache/node-release-keys/gpg"
    }

    It "checks Node signature verification tools during preflight" {
        $result = & (Get-Module CodexWoA.Build) {
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    Node = @{
                        RequireSignedChecksums = $true
                    }
                }
                Report = [ordered]@{
                    tools = [ordered]@{}
                }
            }
            function Require-CommandPath {
                param($Name)
                "C:\tools\$Name.exe"
            }
            function Get-GpgCommandPath {
                "C:\Program Files\Git\usr\bin\gpg.exe"
            }

            Assert-SupplyChainBuildPrerequisites
            $script:Context.Report.tools
        }

        $result.git | Should -Be "C:\tools\git.exe"
        $result.gpg | Should -Be "C:\Program Files\Git\usr\bin\gpg.exe"
    }

    It "fails preflight when Node signatures are required but gpg is unavailable" {
        {
            & (Get-Module CodexWoA.Build) {
                $script:Context = [pscustomobject]@{
                    SupplyChainPolicy = @{
                        Node = @{
                            RequireSignedChecksums = $true
                        }
                    }
                    Report = [ordered]@{
                        tools = [ordered]@{}
                    }
                }
                function Require-CommandPath {
                    param($Name)
                    "C:\tools\$Name.exe"
                }
                function Get-GpgCommandPath {
                    throw "Required command not found: gpg"
                }

                Assert-SupplyChainBuildPrerequisites
            }
        } | Should -Throw "*gpg*"
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
                $script:Context = [pscustomobject]@{
                    SupplyChainPolicy = @{
                        Node = @{
                            ChecksumsFile = "SHASUMS256.txt.asc"
                            RequireSignedChecksums = $false
                        }
                    }
                }
                Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
            } $assetName $assetPath $cacheDir
        } | Should -Throw "*did not contain*"
    }
}
