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

    It "preserves case-insensitive x64 fallback matching" {
        $result = & (Get-Module CodexWoA.Build) {
            $script:Context = [pscustomobject]@{
                Policy = [pscustomobject]@{
                    AllowedX64Fallbacks = @("app\resources\node_repl.exe")
                }
            }

            $fallbacks = New-AllowedX64FallbackSet
            [pscustomobject]@{
                Type = $fallbacks.GetType().FullName
                ContainsDifferentCase = $fallbacks.Contains("APP\RESOURCES\NODE_REPL.EXE")
            }
        }

        $result.Type | Should -Match "^System\.Collections\.Generic\.HashSet"
        $result.ContainsDifferentCase | Should -BeTrue
    }

    It "allows explicitly allowlisted x64 native node payloads" {
        $result = InModuleScope CodexWoA.Build {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) "codex-woa-validation-test-$([System.Guid]::NewGuid())"
            $verifyDir = Join-Path $root "verify"

            try {
                $script:Context = [pscustomobject]@{
                    Policy = [pscustomobject]@{
                        AllowedX64Fallbacks = @("app\resources\native\computer-use-app-icons.node")
                        RequiredWslPayloads = @(
                            "app\resources\codex",
                            "app\resources\codex-resources\bwrap"
                        )
                    }
                    Report = [ordered]@{
                        validation = [ordered]@{}
                    }
                }
                $script:testVerifyDir = $verifyDir

                Mock Invoke-Checked {
                    param(
                        [string]$FilePath,
                        [string[]]$Arguments,
                        [int[]]$SuccessExitCodes
                    )

                    if ($Arguments -contains "unpack") {
                        $nativeDir = Join-Path $script:testVerifyDir "app\resources\native"
                        New-Item -ItemType Directory -Path $nativeDir -Force | Out-Null
                        Set-TextUtf8NoBom (Join-Path $nativeDir "computer-use-app-icons.node") "x64 native fixture"

                        $wslDir = Join-Path $script:testVerifyDir "app\resources\codex-resources"
                        New-Item -ItemType Directory -Path $wslDir -Force | Out-Null
                        Set-TextUtf8NoBom (Join-Path $script:testVerifyDir "app\resources\codex") "arm64 codex fixture"
                        Set-TextUtf8NoBom (Join-Path $wslDir "bwrap") "arm64 bwrap fixture"
                    }
                }
                Mock Test-MsixManifest {
                    [pscustomobject]@{
                        Identity = "OpenAI.Codex.WoA"
                        Architecture = "arm64"
                        Executable = "app/Codex.exe"
                        Protocol = "codex"
                    }
                }
                Mock Assert-WindowsSandboxSetupAsInvokerManifest {}
                Mock Get-PeMachine {
                    param([string]$Path)

                    if ($Path -like "*computer-use-app-icons.node") {
                        return "x64"
                    }

                    return "NotPE"
                }
                Mock Get-ElfMachine {
                    param([string]$Path)

                    if ($Path -like "*\codex" -or $Path -like "*\bwrap") {
                        return "arm64"
                    }

                    return "NotELF"
                }
                Mock Get-AuthenticodeSignature {
                    [pscustomobject]@{
                        SignerCertificate = [pscustomobject]@{
                            Thumbprint = "ABC123"
                        }
                    }
                }
                Mock Add-AppxPackage {}

                Test-MsixPackage "fake.msix" $verifyDir "makeappx" "signtool" "mt" "OpenAI.Codex.WoA" "ABC123"
                [pscustomobject]@{
                    X64Fallbacks = @($script:Context.Report.validation.x64Fallbacks)
                }
            }
            finally {
                Remove-IfExists $root
                Remove-Variable -Name testVerifyDir -Scope Script -ErrorAction SilentlyContinue
            }
        }

        $result.X64Fallbacks | Should -Contain "app\resources\native\computer-use-app-icons.node"
    }
}
