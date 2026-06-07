$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force

Describe "Common build helpers" {
    BeforeEach {
        $script:testRoot = Join-Path $TestDrive "common"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    It "rejects relative paths outside the requested root" {
        {
            & (Get-Module CodexWoA.Build) {
                param($Root, $Path)
                Get-RelativePath $Root $Path
            } (Join-Path $script:testRoot "root") (Join-Path $script:testRoot "other\file.txt")
        } | Should -Throw "*Path is not under root*"
    }

    It "extracts a valid ZIP through controlled extraction" {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipPath = Join-Path $script:testRoot "valid.zip"
        $sourceDir = Join-Path $script:testRoot "source"
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceDir "file.txt") -Value "ok" -NoNewline
        [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $zipPath)

        $destination = Join-Path $script:testRoot "destination"
        & (Get-Module CodexWoA.Build) {
            param($ZipPath, $Destination)
            Expand-ZipClean $ZipPath $Destination
        } $zipPath $destination

        Get-Content -LiteralPath (Join-Path $destination "file.txt") -Raw | Should -Be "ok"
    }

    It "rejects ZIP entries that escape the destination" {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipPath = Join-Path $script:testRoot "traversal.zip"
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry("../evil.txt")
            $stream = $entry.Open()
            try {
                $writer = New-Object System.IO.StreamWriter($stream)
                try {
                    $writer.Write("evil")
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }

        {
            & (Get-Module CodexWoA.Build) {
                param($ZipPath, $Destination)
                Expand-ZipClean $ZipPath $Destination
            } $zipPath (Join-Path $script:testRoot "destination")
        } | Should -Throw "*escapes the destination*"
    }

    It "rejects unsafe TAR entry names before extraction" {
        {
            & (Get-Module CodexWoA.Build) {
                Assert-ArchiveEntryPathSafe "../evil" "payload.tar.gz"
            }
        } | Should -Throw "*escapes the destination*"
    }

    It "reports exit code, working directory, command output, and command text for failed native commands" {
        $batPath = Join-Path $script:testRoot "fail.bat"
        Set-Content -LiteralPath $batPath -Value @(
            "@echo off",
            "echo stdout-line",
            "echo stderr-line 1>&2",
            "exit /b 7"
        )

        {
            & (Get-Module CodexWoA.Build) {
                param($Path)
                Invoke-Checked $Path @()
            } $batPath
        } | Should -Throw "*exit code 7*stdout-line*stderr-line*"
    }
}
