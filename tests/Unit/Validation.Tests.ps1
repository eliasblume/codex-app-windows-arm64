$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "Package validation helpers" {
    BeforeAll {
        $testRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:manifestPath = Join-Path $testRepoRoot "tests\Fixtures\AppxManifest.valid.xml"
    }

    It "accepts the expected ARM64 manifest contract" {
        $result = & (Get-Module CodexWoA.Build) {
            param($Path)
            Test-MsixManifest $Path "OpenAI.Codex.WoA"
        } $script:manifestPath
        $result.Architecture | Should -Be "arm64"
        $result.Protocol | Should -Be "codex"
    }

    It "rejects an unexpected manifest identity" {
        {
            & (Get-Module CodexWoA.Build) {
                param($Path)
                Test-MsixManifest $Path "Wrong.Identity"
            } $script:manifestPath
        } | Should -Throw
    }

    It "recognizes non-PE and non-ELF fixture files" {
        $result = & (Get-Module CodexWoA.Build) {
            param($Path)
            [pscustomobject]@{
                PE = Get-PeMachine $Path
                ELF = Get-ElfMachine $Path
            }
        } $script:manifestPath
        $result.PE | Should -Be "NotPE"
        $result.ELF | Should -Be "NotELF"
    }
}
