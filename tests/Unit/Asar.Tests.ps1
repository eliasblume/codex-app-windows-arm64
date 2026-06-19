$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "ASAR helpers" {
    It "patches Owl feature binding lookups to fall back on stock Electron" {
        InModuleScope CodexWoA.Build {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) "codex-woa-asar-test-$([System.Guid]::NewGuid())"
            $buildDir = Join-Path $root ".vite\build"
            $bundlePath = Join-Path $buildDir "workspace-root-drop-handler-test.js"

            try {
                New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
                Set-TextUtf8NoBom $bundlePath "var Ge={parse:e=>e};function Ze(e){return Qe().isOwlFeatureEnabled(e)}function Qe(){let e=process._linkedBinding;if(typeof e!=``function``)throw Error(``Owl feature binding is unavailable``);return Ge.parse(e.call(process,``electron_common_owl_features``))}"

                $script:Context = [pscustomobject]@{
                    Report = [pscustomobject]@{
                        replacements = New-Object "System.Collections.Generic.List[object]"
                    }
                }

                Patch-OwlFeatureBindingFallback $root

                $content = Get-Content -LiteralPath $bundlePath -Raw
                $content | Should -Match "isOwlFeatureEnabled:\(\)=>!1"
                $content | Should -Not -Match "throw Error\(``Owl feature binding is unavailable``\)"
                $script:Context.Report.replacements[0].name | Should -Be "owl-feature-binding-fallback"
                $script:Context.Report.replacements[0].status | Should -Be "patched"
            }
            finally {
                Remove-IfExists $root
            }
        }
    }
}
