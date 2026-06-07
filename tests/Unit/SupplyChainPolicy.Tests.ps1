Describe "Supply-chain policy" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $policy = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Data\SupplyChainPolicy.psd1")
    }

    It "keeps fast-moving release assets provenance-based instead of version-pinned" {
        $policy.ContainsKey("AssetHashes") | Should -BeFalse
        $policy.ContainsKey("CodexReleaseTag") | Should -BeFalse
        $policy.ContainsKey("RipgrepReleaseTag") | Should -BeFalse
        $policy.ContainsKey("NativePackages") | Should -BeFalse
    }

    It "declares trusted GitHub release sources and asset patterns" {
        $policy.GitHubReleases.Electron.Owner | Should -Be "electron"
        $policy.GitHubReleases.Electron.Repo | Should -Be "electron"
        $policy.GitHubReleases.Codex.Owner | Should -Be "openai"
        $policy.GitHubReleases.Codex.Repo | Should -Be "codex"
        $policy.GitHubReleases.Ripgrep.Owner | Should -Be "BurntSushi"
        $policy.GitHubReleases.Ripgrep.Repo | Should -Be "ripgrep"
        foreach ($entry in $policy.GitHubReleases.GetEnumerator()) {
            $entry.Value.AssetNamePattern | Should -Not -BeNullOrEmpty
            $entry.Value.AllowPrerelease | Should -BeFalse
        }
    }

    It "pins the expected Store source identity" {
        $policy.StoreSource.ExpectedIdentityName | Should -Be "OpenAI.Codex"
        $policy.StoreSource.ExpectedArchitecture | Should -Be "x64"
        $policy.StoreSource.ExpectedPublisher | Should -Match "^CN="
        $policy.StoreSource.AllowedUrlHosts | Should -Contain "tlu.dl.delivery.mp.microsoft.com"
    }

    It "declares signed Node upstream checksum verification" {
        $policy.Node.ChecksumsFile | Should -Be "SHASUMS256.txt.asc"
        $policy.Node.RequireSignedChecksums | Should -BeTrue
        $policy.Node.ReleaseKeysRepo | Should -Be "https://github.com/nodejs/release-keys.git"
        $policy.Node.ReleaseKeysRef | Should -Not -BeNullOrEmpty
        $policy.Node.ReleaseKeysGpgDirectory | Should -Be "gpg"
        $policy.Node.ContainsKey("PinnedAssetHashes") | Should -BeFalse
    }

    It "keeps rcedit as an explicit direct-download pin because upstream publishes no signed checksum" {
        $policy.GitHubReleases.ContainsKey("Rcedit") | Should -BeFalse
        $policy.DirectDownloads.Rcedit.Version | Should -Be "v2.0.0"
        $policy.DirectDownloads.Rcedit.AssetName | Should -Be "rcedit-x64.exe"
        $policy.DirectDownloads.Rcedit.Url | Should -Match "^https://github\.com/electron/rcedit/releases/download/"
        $policy.DirectDownloads.Rcedit.Sha256 | Should -Match "^[A-F0-9]{64}$"
    }

    It "documents Git and GPG as build requirements for Node signature verification" {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot "README.md") -Raw
        $readme | Should -Match "Git and GPG"
        $readme | Should -Match "SHASUMS256\.txt\.asc"
        $readme | Should -Match "gpg"
    }

    It "keeps workflow Store source checks sourced from supply-chain policy" {
        $workflow = Get-Content -LiteralPath (Join-Path $repoRoot ".github\workflows\build-codex-woa.yml") -Raw
        $workflow | Should -Match "SupplyChainPolicy\.psd1"
        $workflow | Should -Match '\$storePolicy\.AllowedUrlHosts'
        $workflow | Should -Match '\$storePolicy\.ExpectedPublisher'
        $workflow | Should -Match '\$storePolicy\.RequiredSignerIssuerContains'
        $workflow | Should -Not -Match "tlu\.dl\.delivery\.mp\.microsoft\.com"
        $workflow | Should -Not -Match "50BDFD77-8903-4850-9FFE-6E8522F64D5B"
        $workflow | Should -Not -Match "Microsoft Marketplace CA"
    }
}
