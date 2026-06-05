Describe "Build-CodexWoA CLI contract" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $buildScriptPath = Join-Path $repoRoot "Build-CodexWoA.ps1"
        $tokens = $null
        $errors = $null
        $script:Ast = [Management.Automation.Language.Parser]::ParseFile(
            $buildScriptPath,
            [ref]$tokens,
            [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $script:Parameters = $script:Ast.ParamBlock.Parameters
    }

    It "keeps the established parameter names" {
        @($script:Parameters.Name.VariablePath.UserPath) | Should -Be @(
            "SourceMode",
            "SourceMsixPath",
            "OutputDir",
            "PackageIdentity",
            "DisplayName",
            "PackageVersionOverride",
            "PublisherSubject",
            "CodexReleaseTag",
            "InstallVsDependencies",
            "SkipVsDependencyCheck",
            "KeepWorkDir",
            "Force"
        )
    }

    It "keeps all supported source modes" {
        $sourceMode = $script:Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "SourceMode" }
        $validateSet = $sourceMode.Attributes | Where-Object { $_.TypeName.Name -eq "ValidateSet" }
        @($validateSet.PositionalArguments.Value) | Should -Be @("Prompt", "StoreMsix", "Installed", "StoreLatest", "Msix")
    }

    It "keeps the expected report sections" {
        $content = Get-Content -LiteralPath $buildScriptPath -Raw
        foreach ($section in @("versions", "replacements", "warnings", "validation", "outputs")) {
            $content | Should -Match "(?m)^\s+$section\s*="
        }
    }

    It "keeps source shape validation requirements" {
        $content = Get-Content -LiteralPath $buildScriptPath -Raw
        foreach ($path in @("AppxManifest.xml", "app\Codex.exe", "app\resources\app.asar", "app\resources\app.asar.unpacked")) {
            $content | Should -Match ([regex]::Escape($path))
        }
    }
}
