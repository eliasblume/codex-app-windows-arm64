Describe "Pinned build tools" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $tools = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Data\BuildTools.psd1")
    }

    It "pins every native build helper" {
        foreach ($name in @("Pnpm", "ElectronRebuild", "NodeGyp", "PrebuildInstall")) {
            $tools[$name] | Should -Match "^\d+\.\d+\.\d+$"
        }
    }

    It "does not use latest for native build dependencies" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Not -Match '"latest"'
    }

    It "does not execute node-gyp through registry-resolved dlx" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $pluginContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\BundledPlugins.ps1") -Raw
        "$nativeContent`n$pluginContent" | Should -Not -Match '"dlx",\s*\r?\n\s*"node-gyp'
        "$nativeContent`n$pluginContent" | Should -Match "Get-PinnedNodeGypCommand"
    }

    It "blocks source-package gyp actions before native rebuilds" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $pluginContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\BundledPlugins.ps1") -Raw
        "$nativeContent`n$pluginContent" | Should -Match "Assert-NativeBuildMetadataSafe"
    }

    It "does not permanently pin Work Louder native package versions" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Not -Match "Assert-PolicyNativePackageVersion"
        $nativeContent | Should -Match "Report\.versions\.nodeHid"
        $nativeContent | Should -Match "Report\.versions\.serialPortBindingsCpp"
    }

    It "passes electron-rebuild modules as one compatible argument" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Match '"better-sqlite3,node-pty"'
        $nativeContent | Should -Not -Match '"better-sqlite3",\s*\r?\n\s*"-w"'
    }
}
