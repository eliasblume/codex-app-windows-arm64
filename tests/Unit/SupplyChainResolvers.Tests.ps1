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
                function Download-File {
                    param($Url, $Destination)
                    Set-Content -LiteralPath $Destination -Value "still tampered bytes" -NoNewline
                }

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

    It "refreshes a stale cached GitHub release asset before verifying the digest" {
        $assetPath = Join-Path $script:testRoot "tool.zip"
        Set-Content -LiteralPath $assetPath -Value "old release bytes" -NoNewline
        $freshBytes = "new release bytes"
        $hashPath = Join-Path $script:testRoot "fresh.zip"
        Set-Content -LiteralPath $hashPath -Value $freshBytes -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hashPath).Hash.ToLowerInvariant()
        $release = [pscustomobject]@{
            tag_name = "v2.0.0"
            assets = @([pscustomobject]@{
                    name = "tool.zip"
                    id = 456
                    digest = "sha256:$hash"
                    browser_download_url = "https://example.test/tool.zip"
                })
        }

        $result = & (Get-Module CodexWoA.Build) {
            param($Release, $Path, $FreshBytes)
            $script:downloadCount = 0
            function Download-File {
                param($Url, $Destination)
                $script:downloadCount++
                Set-Content -LiteralPath $Destination -Value $FreshBytes -NoNewline
            }

            $resolved = Download-VerifiedGitHubReleaseAsset `
                -Release $Release `
                -Owner "owner" `
                -Repo "repo" `
                -AssetName "tool.zip" `
                -Destination $Path `
                -AssetNamePattern "^tool\.zip$" `
                -Label "tool"

            [pscustomobject]@{
                Path = $resolved
                DownloadCount = $script:downloadCount
                Content = Get-Content -LiteralPath $Path -Raw
            }
        } $release $assetPath $freshBytes

        $result.Path | Should -Be $assetPath
        $result.DownloadCount | Should -Be 1
        $result.Content | Should -Be $freshBytes
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

    It "refreshes a stale cached direct-download asset before verifying the policy hash" {
        $assetPath = Join-Path $script:testRoot "tool.exe"
        Set-Content -LiteralPath $assetPath -Value "old direct-download bytes" -NoNewline
        $freshBytes = "new direct-download bytes"
        $hashPath = Join-Path $script:testRoot "fresh-tool.exe"
        Set-Content -LiteralPath $hashPath -Value $freshBytes -NoNewline
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hashPath).Hash.ToUpperInvariant()

        $result = & (Get-Module CodexWoA.Build) {
            param($Path, $Hash, $FreshBytes)
            $script:downloadCount = 0
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    DirectDownloads = @{
                        Tool = @{
                            Version = "v2.0.0"
                            AssetName = "tool.exe"
                            Url = "https://example.test/tool.exe"
                            Sha256 = $Hash
                        }
                    }
                }
            }

            function Download-File {
                param($Url, $Destination)
                $script:downloadCount++
                Set-Content -LiteralPath $Destination -Value $FreshBytes -NoNewline
            }

            $resolved = Download-VerifiedDirectDownload "Tool" $Path "tool"

            [pscustomobject]@{
                Path = $resolved
                DownloadCount = $script:downloadCount
                Content = Get-Content -LiteralPath $Path -Raw
            }
        } $assetPath $hash $freshBytes

        $result.Path | Should -Be $assetPath
        $result.DownloadCount | Should -Be 1
        $result.Content | Should -Be $freshBytes
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

    It "refreshes cached WSL payload files from verified release assets" {
        $cacheDir = Join-Path $script:testRoot "cache"
        $payloadDir = Join-Path $cacheDir "codex-wsl-aarch64-v1.2.3"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $payloadDir "codex") -Value "poisoned codex" -NoNewline
        Set-Content -LiteralPath (Join-Path $payloadDir "bwrap") -Value "poisoned bwrap" -NoNewline
        $release = [pscustomobject]@{
            tag_name = "v1.2.3"
            assets = @()
        }

        $result = & (Get-Module CodexWoA.Build) {
            param($Release, $CacheDir)
            $script:verifiedAssets = New-Object System.Collections.Generic.List[string]
            $script:expandedArchives = New-Object System.Collections.Generic.List[string]

            function Download-VerifiedGitHubReleaseAsset {
                param(
                    $Release,
                    $Owner,
                    $Repo,
                    $AssetName,
                    $Destination,
                    $AssetNamePattern,
                    $Label
                )

                $script:verifiedAssets.Add($AssetName) | Out-Null
                Set-Content -LiteralPath $Destination -Value "verified $AssetName" -NoNewline
                return $Destination
            }

            function Expand-TarGzClean {
                param($ArchivePath, $Destination)
                $script:expandedArchives.Add((Split-Path -Leaf $ArchivePath)) | Out-Null
                New-CleanDirectory $Destination | Out-Null
                $archiveName = Split-Path -Leaf $ArchivePath
                $expectedName = if ($archiveName -like "codex-*") {
                    "codex-aarch64-unknown-linux-musl"
                }
                else {
                    "bwrap-aarch64-unknown-linux-musl"
                }
                Set-Content -LiteralPath (Join-Path $Destination $expectedName) -Value "trusted $expectedName" -NoNewline
            }

            function Get-ElfMachine {
                param($Path)
                "arm64"
            }

            $payload = Get-Arm64WslCodexPayload `
                -Release $Release `
                -Owner "openai" `
                -Repo "codex" `
                -AssetNamePattern ".*" `
                -CacheDir $CacheDir

            [pscustomobject]@{
                Codex = Get-Content -LiteralPath $payload.CodexPath -Raw
                Bwrap = Get-Content -LiteralPath $payload.BwrapPath -Raw
                VerifiedAssets = $script:verifiedAssets.ToArray()
                ExpandedArchives = $script:expandedArchives.ToArray()
            }
        } $release $cacheDir

        $result.Codex | Should -Be "trusted codex-aarch64-unknown-linux-musl"
        $result.Bwrap | Should -Be "trusted bwrap-aarch64-unknown-linux-musl"
        $result.VerifiedAssets | Should -Contain "codex-aarch64-unknown-linux-musl.tar.gz"
        $result.VerifiedAssets | Should -Contain "bwrap-aarch64-unknown-linux-musl.tar.gz"
        $result.ExpandedArchives | Should -Contain "codex-aarch64-unknown-linux-musl.tar.gz"
        $result.ExpandedArchives | Should -Contain "bwrap-aarch64-unknown-linux-musl.tar.gz"
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
            param($AssetName, $Path, $CacheDir, $Hash)
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    Node = @{
                        ChecksumsFile = "SHASUMS256.txt.asc"
                        RequireSignedChecksums = $true
                        ReleaseKeysDirectory = "C:\fake\node-release-keys"
                    }
                }
            }
            function Assert-NodeChecksumsSignature {
                param($ChecksumsPath, $NodePolicy, $CacheDir)
                $script:signatureInput = $ChecksumsPath
                return @("$Hash  $AssetName")
            }
            Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
        } $assetName $assetPath $cacheDir $hash

        $result | Should -Be $assetPath
    }

    It "ignores unsigned Node checksum lines outside the GPG-verified cleartext" {
        $cacheDir = Join-Path $script:testRoot "cache"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $assetName = "node-v1.2.3-win-arm64.zip"
        $assetPath = Join-Path $cacheDir $assetName
        Set-Content -LiteralPath $assetPath -Value "trusted node bytes" -NoNewline
        $trustedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
        $poisonPath = Join-Path $cacheDir "poison.bin"
        Set-Content -LiteralPath $poisonPath -Value "poisoned node bytes" -NoNewline
        $poisonHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $poisonPath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $cacheDir "node-v1.2.3-SHASUMS256.txt.asc") -Value @(
            "$poisonHash  $assetName",
            "-----BEGIN PGP SIGNED MESSAGE-----",
            "",
            "$trustedHash  $assetName",
            "-----BEGIN PGP SIGNATURE-----",
            "mock-signature"
        )

        $result = & (Get-Module CodexWoA.Build) {
            param($AssetName, $Path, $CacheDir, $TrustedHash)
            $script:Context = [pscustomobject]@{
                SupplyChainPolicy = @{
                    Node = @{
                        ChecksumsFile = "SHASUMS256.txt.asc"
                        RequireSignedChecksums = $true
                        ReleaseKeysDirectory = "C:\fake\node-release-keys"
                    }
                }
            }
            function Assert-NodeChecksumsSignature {
                param($ChecksumsPath, $NodePolicy, $CacheDir)
                return @("$TrustedHash  $AssetName")
            }
            Download-VerifiedNodeReleaseFile "1.2.3" $AssetName $Path $CacheDir
        } $assetName $assetPath $cacheDir $trustedHash

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
                        ReleaseKeysDirectory = "C:\fake\node-release-keys"
                    }
                }
                }
                function Assert-NodeChecksumsSignature {
                    param($ChecksumsPath, $NodePolicy, $CacheDir)
                    return @("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  $AssetName")
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
                        ReleaseKeysDirectory = "C:\fake\node-release-keys"
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

    It "finds Git-bundled gpg from a custom Git install root" {
        $gitRoot = Join-Path $script:testRoot "custom-git"
        $gitCmd = Join-Path $gitRoot "cmd\git.exe"
        $gpgPath = Join-Path $gitRoot "usr\bin\gpg.exe"
        New-Item -ItemType Directory -Path (Split-Path -Parent $gitCmd) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $gpgPath) -Force | Out-Null
        Set-Content -LiteralPath $gitCmd -Value "fake git" -NoNewline
        Set-Content -LiteralPath $gpgPath -Value "fake gpg" -NoNewline

        $result = & (Get-Module CodexWoA.Build) {
            param($GitPath)
            function Get-Command {
                param($Name)
                if ($Name -eq "git") {
                    return [pscustomobject]@{
                        Source = $GitPath
                        CommandType = "Application"
                    }
                }

                return $null
            }

            Get-GpgCommandPath
        } $gitCmd

        $result | Should -Be $gpgPath
    }

    It "imports vendored Node public keys into a temporary GPG home" {
        $cacheDir = Join-Path $script:testRoot "cache"
        $keyDir = Join-Path $script:testRoot "keys"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $keyDir "test.asc") -Value "public key" -NoNewline
        $checksumsPath = Join-Path $cacheDir "SHASUMS256.txt.asc"
        Set-Content -LiteralPath $checksumsPath -Value "signed checksums" -NoNewline

        $result = & (Get-Module CodexWoA.Build) {
            param($KeyDir, $CacheDir, $ChecksumsPath)
            $script:Context = [pscustomobject]@{
                Report = [ordered]@{
                    tools = [ordered]@{}
                }
            }
            $script:commands = New-Object System.Collections.Generic.List[object]
            function Get-GpgCommandPath {
                "C:\tools\gpg.exe"
            }
            function Invoke-Checked {
                param($FilePath, $Arguments)
                $script:commands.Add([pscustomobject]@{
                    FilePath = $FilePath
                    Arguments = @($Arguments)
                }) | Out-Null
                $outputIndex = @($Arguments).IndexOf("--output")
                if ($outputIndex -ge 0) {
                    Set-Content -LiteralPath $Arguments[$outputIndex + 1] -Value "verified checksums" -NoNewline
                }
                return 0
            }

            $verified = Assert-NodeChecksumsSignature `
                -ChecksumsPath $ChecksumsPath `
                -NodePolicy @{ RequireSignedChecksums = $true; ReleaseKeysDirectory = $KeyDir } `
                -CacheDir $CacheDir

            [pscustomobject]@{
                Commands = $script:commands.ToArray()
                Evidence = $script:Context.Report["tools"]["nodeReleaseKeys"]
                Verified = $verified
            }
        } $keyDir $cacheDir $checksumsPath

        $result.Commands.Count | Should -Be 2
        $result.Commands[0].Arguments | Should -Contain "--import"
        $result.Commands[0].Arguments -join " " | Should -Match "test\.asc"
        $result.Commands[1].Arguments | Should -Contain "--decrypt"
        $result.Commands[1].Arguments | Should -Contain "--output"
        $result.Verified | Should -Contain "verified checksums"
        $result.Evidence | Should -Be (Resolve-Path -LiteralPath $keyDir).Path
    }

    It "fails closed when the vendored Node keyring is missing" {
        {
            & (Get-Module CodexWoA.Build) {
                Get-NodeReleaseKeysDirectory @{ ReleaseKeysDirectory = "C:\does-not-exist\node-release-keys" }
            }
        } | Should -Throw "*was not found*"
    }

    It "fails closed when the vendored Node keyring contains no public keys" {
        $keyDir = Join-Path $script:testRoot "empty-keys"
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        {
            & (Get-Module CodexWoA.Build) {
                param($KeyDir)
                Get-NodeReleaseKeysDirectory @{ ReleaseKeysDirectory = $KeyDir }
            } $keyDir
        } | Should -Throw "*does not contain public keys*"
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
                throw "git should not be required"
            }
            function Get-GpgCommandPath {
                "C:\Program Files\Git\usr\bin\gpg.exe"
            }

            Assert-SupplyChainBuildPrerequisites
            $script:Context.Report.tools
        }

        $result.gpg | Should -Be "C:\Program Files\Git\usr\bin\gpg.exe"
        $result.Contains("git") | Should -BeFalse
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
