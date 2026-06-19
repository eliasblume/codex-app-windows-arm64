$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "Bundled plugin helpers" {
    It "removes Node thin-LTO flags from classic-level MSVC project files" {
        InModuleScope CodexWoA.Build {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) "codex-woa-bundled-plugins-test-$([System.Guid]::NewGuid())"
            $classicLevelDir = Join-Path $root "node_modules\classic-level"
            $buildProject = Join-Path $classicLevelDir "build\classic_level.vcxproj"
            $depProject = Join-Path $classicLevelDir "deps\leveldb\leveldb.vcxproj"

            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $buildProject) -Force | Out-Null
                New-Item -ItemType Directory -Path (Split-Path -Parent $depProject) -Force | Out-Null
                Set-TextUtf8NoBom $buildProject "<AdditionalOptions>/ignore:4199 -flto=thin /opt:lldltojobs=2 %(AdditionalOptions)</AdditionalOptions>"
                Set-TextUtf8NoBom $depProject "<AdditionalOptions>-flto=thin /opt:lldltojobs=2 %(AdditionalOptions)</AdditionalOptions>"

                $script:Context = [pscustomobject]@{
                    Report = [pscustomobject]@{
                        replacements = New-Object "System.Collections.Generic.List[object]"
                    }
                }

                Remove-ClassicLevelMsvcLtoOptions $classicLevelDir

                $buildContent = Get-Content -LiteralPath $buildProject -Raw
                $depContent = Get-Content -LiteralPath $depProject -Raw

                $buildContent | Should -Not -Match "flto"
                $buildContent | Should -Not -Match "lldltojobs"
                $buildContent | Should -Match "/ignore:4199"
                $buildContent | Should -Match "%\(AdditionalOptions\)"
                $depContent | Should -Not -Match "flto"
                $depContent | Should -Not -Match "lldltojobs"
                $script:Context.Report.replacements[0].name | Should -Be "classic-level-msvc-lto-flags"
                $script:Context.Report.replacements[0].status | Should -Be "removed"
            }
            finally {
                Remove-IfExists $root
            }
        }
    }
}
