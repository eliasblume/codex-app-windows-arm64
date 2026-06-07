$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "Native module build metadata guards" {
    BeforeEach {
        $script:testRoot = Join-Path $TestDrive "native-modules"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    It "rejects executable metadata in included gypi files" {
        $packageDir = Join-Path $script:testRoot "package"
        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $packageDir "binding.gyp") -Value @"
{
  'includes': [ 'common.gypi' ],
  'targets': []
}
"@
        Set-Content -LiteralPath (Join-Path $packageDir "common.gypi") -Value @"
{
  'actions': [
    {
      'action_name': 'run-from-gypi',
      'inputs': [],
      'outputs': [],
      'action': [ 'powershell', '-NoProfile', '-Command', 'Write-Host unsafe' ]
    }
  ]
}
"@

        {
            & (Get-Module CodexWoA.Build) {
                param($PackageDir)
                Assert-NativeBuildMetadataSafe $PackageDir "test-package"
            } $packageDir
        } | Should -Throw "*common.gypi*source-package build actions*"
    }

    It "rejects gyp command expansions before native rebuilds" {
        $packageDir = Join-Path $script:testRoot "package"
        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $packageDir "binding.gyp") -Value @"
{
  'targets': [
    {
      'target_name': 'native',
      'sources': [ '<!@(powershell -NoProfile -Command Write-Output unsafe)' ]
    }
  ]
}
"@

        {
            & (Get-Module CodexWoA.Build) {
                param($PackageDir)
                Assert-NativeBuildMetadataSafe $PackageDir "test-package"
            } $packageDir
        } | Should -Throw "*binding.gyp*source-package build commands*"
    }
}
