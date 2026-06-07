Describe "Build module architecture" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $privateRoot = Join-Path $repoRoot "src\CodexWoA.Build\Private"
    }

    It "has no legacy core file" {
        Test-Path -LiteralPath (Join-Path $privateRoot "LegacyCore.ps1") | Should -BeFalse
    }

    It "keeps all orchestration phases explicit" {
        $content = Get-Content -LiteralPath (Join-Path $privateRoot "Orchestration.ps1") -Raw
        foreach ($phase in @("Initialize", "Preflight", "Acquire", "Transform", "Package", "Validate", "Report")) {
            $content | Should -Match "Phase: $phase"
        }
    }

    It "uses the context instead of legacy global aliases" {
        $content = Get-ChildItem -LiteralPath $privateRoot -File -Filter "*.ps1" |
            Get-Content -Raw |
            Out-String
        $content | Should -Not -Match '\$script:(Report|ScriptRoot|DefaultOutputDir|WslPayloadRelativeDir)'
    }

    It "keeps supply-chain logic out of Common.ps1" {
        $common = Get-Content -LiteralPath (Join-Path $privateRoot "Common.ps1") -Raw
        $common | Should -Not -Match "Download-VerifiedGitHubReleaseAsset"
        $common | Should -Not -Match "Get-GitHubReleaseFromPolicy"
        $common | Should -Not -Match "Download-VerifiedNodeReleaseFile"
        Test-Path -LiteralPath (Join-Path $privateRoot "SupplyChain.ps1") | Should -BeTrue
    }
}
