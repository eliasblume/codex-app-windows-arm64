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

    It "declares the Node upstream checksum file" {
        $policy.Node.ChecksumsFile | Should -Be "SHASUMS256.txt.asc"
    }
}
