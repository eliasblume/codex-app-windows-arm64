Describe "Extracted build artifacts" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $templateRoot = Join-Path $repoRoot "src\CodexWoA.Build\Templates"
        $toolRoot = Join-Path $repoRoot "src\CodexWoA.Build\Tools"
    }

    It "keeps installer placeholders explicit" {
        $installTemplate = Get-Content -LiteralPath (Join-Path $templateRoot "Install.ps1") -Raw
        $installTemplate | Should -Match "__MSIX_FILE_NAME__"
        $installTemplate | Should -Match "__CER_RELATIVE_PATH__"
        $installTemplate | Should -Match "__EXPECTED_CER_THUMBPRINT__"
        $installTemplate | Should -Match "__EXPECTED_PACKAGE_IDENTITY__"
        $installTemplate | Should -Match "__EXPECTED_PACKAGE_VERSION__"
    }

    It "passes an expected thumbprint across elevated certificate trust" {
        $installTemplate = Get-Content -LiteralPath (Join-Path $templateRoot "Install.ps1") -Raw
        $installTemplate | Should -Match "ExpectedCerThumbprint"
        $installTemplate | Should -Match "Assert-ExpectedCertificateThumbprint"
        $installTemplate | Should -Match "X509Store"
        $installTemplate | Should -Match "RemoveTrustedCertificateOnly"
        $installTemplate | Should -Not -Match '\$ExpectedCerThumbprint\s*=\s*\$cert\.Thumbprint'
    }

    It "validates the generated MSIX manifest before certificate trust" {
        $installTemplate = Get-Content -LiteralPath (Join-Path $templateRoot "Install.ps1") -Raw
        $installTemplate | Should -Match "Assert-MsixManifestMatchesExpected"
        $installTemplate | Should -Match "ExpectedPackageIdentity"
        $installTemplate | Should -Match "ExpectedPackageArchitecture"
        $installTemplate | Should -Match "ExpectedPackageVersion"
        $installTemplate.IndexOf('Write-Host "Checking MSIX manifest') | Should -BeLessThan $installTemplate.IndexOf('Write-Host "Checking certificate trust')
    }

    It "keeps the batch template pointed at Install.ps1" {
        Get-Content -LiteralPath (Join-Path $templateRoot "Install.bat") -Raw |
            Should -Match "Install\.ps1"
    }

    It "keeps the tolerant ASAR extractor external" {
        $tool = Join-Path $toolRoot "extract-asar-tolerant.js"
        Test-Path -LiteralPath $tool | Should -BeTrue
        Get-Content -LiteralPath $tool -Raw | Should -Match "missingUnpacked"
    }
}
