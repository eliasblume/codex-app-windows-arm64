Describe "Source package resolution" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force
        $html = Get-Content -LiteralPath (Join-Path $repoRoot "tests\Fixtures\store-packages.html") -Raw
    }

    It "selects the latest x64 Store package from fixture HTML" {
        $result = Resolve-CodexStorePackage -Html $html
        $result.storeVersion | Should -Be "26.2.3.4"
        $result.msixFile | Should -Be "OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix"
        $result.msixSha1 | Should -Be "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    }

    It "applies a valid package version override" {
        $result = Resolve-CodexStorePackage -Html $html -VersionOverride "30.1.2.3"
        $result.packageVersion | Should -Be "30.1.2.3"
        $result.releaseTag | Should -Be "30.1.2.3"
        $result.shouldBuild | Should -BeTrue
    }

    It "rejects invalid package version overrides" {
        { Resolve-CodexStorePackage -Html $html -VersionOverride "30.1" } | Should -Throw
    }

    It "signals when GitHub release comparison cannot use gh" {
        $result = & (Get-Module CodexWoA.Build) {
            param($Html)
            function Get-Command {
                param([string]$Name)
                if ($Name -eq "gh") {
                    return $null
                }

                Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
            }

            Resolve-CodexStorePackage -Html $Html -Repo "owner/repo" 3>$null
        } $html

        $result.latestReleaseTag | Should -Be "0.0.0"
        $result.latestReleaseWarning | Should -Match "gh"
    }

    It "rejects Store package URLs outside the Microsoft delivery allowlist" {
        $badHtml = @"
<table>
  <tr><td><a href="https://example.test/latest.msix">OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix</a></td><td>latest</td><td>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</td><td>2 MB</td></tr>
</table>
"@

        { Resolve-CodexStorePackage -Html $badHtml } | Should -Throw "*not allowlisted*"
    }

    It "rejects decoded Store metadata control characters" {
        $badHtml = @"
<table>
  <tr><td><a href="https://tlu.dl.delivery.mp.microsoft.com/latest.msix&#10;release_tag=evil">OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix</a></td><td>latest</td><td>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</td><td>2 MB</td></tr>
</table>
"@

        { Resolve-CodexStorePackage -Html $badHtml } | Should -Throw "*control character*"
    }

    It "rejects a source MSIX when Authenticode status is not valid" {
        {
            & (Get-Module CodexWoA.Build) {
                function Get-AuthenticodeSignature {
                    [pscustomobject]@{
                        Status = "HashMismatch"
                        SignerCertificate = [pscustomobject]@{
                            Subject = "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B"
                            Issuer = "CN=Microsoft Marketplace CA G 024, O=Microsoft Corporation"
                        }
                    }
                }

                Assert-CodexSourceMsixSignature "C:\fake\OpenAI.Codex.msix"
            }
        } | Should -Throw "*expected Valid*"
    }
}
