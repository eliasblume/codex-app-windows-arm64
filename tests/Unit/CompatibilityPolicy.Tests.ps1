Describe "Compatibility policy" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $policy = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Data\CompatibilityPolicy.psd1")
    }

    It "declares required ARM64 WSL payloads" {
        $policy.RequiredWslPayloads | Should -Contain "app\resources\codex"
        $policy.RequiredWslPayloads | Should -Contain "app\resources\codex-resources\bwrap"
    }

    It "keeps x64 fallback paths explicit and unique" {
        $policy.AllowedX64Fallbacks.Count | Should -BeGreaterThan 0
        @($policy.AllowedX64Fallbacks | Sort-Object -Unique).Count | Should -Be $policy.AllowedX64Fallbacks.Count
    }

    It "declares the closed-source Computer Use icon helper fallback" {
        $policy.AllowedX64Fallbacks | Should -Contain "app\resources\native\computer-use-app-icons.node"
    }
}
