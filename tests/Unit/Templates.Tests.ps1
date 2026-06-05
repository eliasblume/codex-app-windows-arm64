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
