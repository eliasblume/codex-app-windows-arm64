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

    It "passes electron-rebuild modules as one compatible argument" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Match '"better-sqlite3,node-pty"'
        $nativeContent | Should -Not -Match '"better-sqlite3",\s*\r?\n\s*"-w"'
    }

    It "overrides electron-rebuild transitive node-gyp" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Match '"node-gyp"\s*=\s*\$script:Context\.Tools\.NodeGyp'
        $nativeContent | Should -Match 'overrides:\r?\n\s+node-gyp:\s+\$\(\$script:Context\.Tools\.NodeGyp\)'
    }
}
