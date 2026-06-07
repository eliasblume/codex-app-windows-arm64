function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    $script:Context.Report.warnings.Add($Message)
    Write-Warning $Message
}

function Add-Replacement {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    $script:Context.Report.replacements.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
    })
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function New-CleanDirectory {
    param([string]$Path)
    Remove-IfExists $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Test-IsPathUnderDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $directoryFull = [System.IO.Path]::GetFullPath($Directory).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($directoryFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-CleanDirectoryUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-IsPathUnderDirectory $pathFull $rootFull)) {
        throw "Refusing to clean generated directory outside expected root. Path: $pathFull Root: $rootFull"
    }

    return New-CleanDirectory $pathFull
}

function Set-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Require-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found: $Name"
    }
    return $command.Source
}

function Add-CommandEvidence {
    param([hashtable]$Evidence)

    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $contextVariable -or $null -eq $contextVariable.Value) {
        return
    }

    $reportProperty = $contextVariable.Value.PSObject.Properties["Report"]
    if ($null -eq $reportProperty -or $null -eq $reportProperty.Value) {
        return
    }

    $report = $reportProperty.Value
    if ($report -is [System.Collections.IDictionary]) {
        $commandEvidence = $report["commandEvidence"]
    }
    else {
        $commandEvidenceProperty = $report.PSObject.Properties["commandEvidence"]
        $commandEvidence = if ($null -ne $commandEvidenceProperty) { $commandEvidenceProperty.Value } else { $null }
    }

    if ($null -eq $commandEvidence) {
        return
    }

    $commandEvidence.Add($Evidence) | Out-Null
}

function Format-CommandForLog {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $parts = New-Object "System.Collections.Generic.List[string]"
    $parts.Add($FilePath) | Out-Null
    foreach ($argument in @($Arguments)) {
        if ($argument -match "\s") {
            $parts.Add(('"{0}"' -f ($argument -replace '"', '\"'))) | Out-Null
        }
        else {
            $parts.Add($argument) | Out-Null
        }
    }

    return ($parts -join " ")
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0)
    )

    $workingDirectory = (Get-Location).Path
    $commandLine = Format-CommandForLog $FilePath $Arguments
    Write-Verbose ("Running: {0}" -f $commandLine)
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    foreach ($line in $output) {
        $line | Out-Host
    }

    Add-CommandEvidence @{
        command = $commandLine
        workingDirectory = $workingDirectory
        exitCode = $exitCode
        outputTail = @($output | Select-Object -Last 20 | ForEach-Object { [string]$_ })
    }

    if ($SuccessExitCodes -notcontains $exitCode) {
        $tail = @($output | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join "`n"
        throw "Command failed with exit code $exitCode in ${workingDirectory}: $commandLine`n$tail"
    }
    return $exitCode
}

function Copy-DirectoryRobust {
    param(
        [string]$Source,
        [string]$Destination,
        [ValidateSet("Mirror", "Merge")]
        [string]$Mode = "Mirror"
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $copyMode = if ($Mode -eq "Mirror") { "/MIR" } else { "/E" }
    $workingDirectory = (Get-Location).Path
    $output = @(& robocopy $Source $Destination $copyMode /R:2 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $line | Out-Host
    }

    Add-CommandEvidence @{
        command = "robocopy"
        workingDirectory = $workingDirectory
        exitCode = $exitCode
        outputTail = @($output | Select-Object -Last 20 | ForEach-Object { [string]$_ })
    }

    if ($exitCode -gt 7) {
        $tail = @($output | Select-Object -Last 20 | ForEach-Object { [string]$_ }) -join "`n"
        throw "robocopy failed with exit code $exitCode in ${workingDirectory}: $Source -> $Destination`n$tail"
    }
}

function Normalize-PercentEncodedScopedPackageDirs {
    param(
        [string]$Root,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $normalized = New-Object "System.Collections.Generic.List[string]"
    $encodedDirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)%40" } |
        Sort-Object { $_.FullName.Length } -Descending)

    foreach ($dir in $encodedDirs) {
        if (-not (Test-Path -LiteralPath $dir.FullName)) {
            continue
        }

        $decodedName = $dir.Name -replace "(?i)%40", "@"
        if ($decodedName -eq $dir.Name) {
            continue
        }

        $target = Join-Path $dir.Parent.FullName $decodedName
        if (Test-Path -LiteralPath $target) {
            Copy-DirectoryRobust $dir.FullName $target -Mode Merge
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        }
        else {
            Rename-Item -LiteralPath $dir.FullName -NewName $decodedName
        }

        $normalized.Add((Get-RelativePath $Root $target)) | Out-Null
    }

    if ($normalized.Count -gt 0) {
        Add-Replacement $Label "normalized" ($normalized -join ", ")
    }
}



function Find-WindowsKitTool {
    param([string]$ToolName)

    $preferredArches = @("arm64", "x64", "x86")
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne "Arm64") {
        $preferredArches = @("x64", "arm64", "x86")
    }

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitRoot) {
        $versions = Get-ChildItem -LiteralPath $kitRoot -Directory |
            Where-Object { $_.Name -match "^\d+\.\d+\.\d+\.\d+$" } |
            Sort-Object { [version]$_.Name } -Descending

        foreach ($version in $versions) {
            foreach ($arch in $preferredArches) {
                $candidate = Join-Path $version.FullName (Join-Path $arch $ToolName)
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "Could not find Windows SDK tool: $ToolName"
}

function Expand-ZipClean {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            Assert-ArchiveEntryPathSafe $entry.FullName $ZipPath
        }
    }
    finally {
        $archive.Dispose()
    }

    Invoke-ControlledExtraction $Destination {
        param($ExtractDestination)
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractDestination -Force
    } $ZipPath
}

function Expand-MsixClean {
    param(
        [string]$MsixPath,
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($MsixPath)
    try {
        foreach ($entry in $archive.Entries) {
            Assert-ArchiveEntryPathSafe $entry.FullName $MsixPath
        }
    }
    finally {
        $archive.Dispose()
    }

    Invoke-ControlledExtraction $Destination {
        param($ExtractDestination)
        [System.IO.Compression.ZipFile]::ExtractToDirectory($MsixPath, $ExtractDestination)
    } $MsixPath
}

function Get-TarCommandPath {
    $command = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    $command = Get-Command "tar" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    throw "Required command not found: tar.exe"
}

function Expand-TarGzClean {
    param(
        [string]$TarGzPath,
        [string]$Destination
    )

    $tar = Get-TarCommandPath
    $listOutput = @(& $tar -tzf $TarGzPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "tar listing failed with exit code $exitCode`: $($listOutput -join "`n")"
    }
    foreach ($entry in $listOutput) {
        Assert-ArchiveEntryPathSafe ([string]$entry) $TarGzPath
    }

    Invoke-ControlledExtraction $Destination {
        param($ExtractDestination)
        Invoke-Checked $tar @("-xzf", $TarGzPath, "-C", $ExtractDestination) | Out-Null
    } $TarGzPath
}





function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-IsPathUnderDirectory $pathFull $rootFull)) {
        throw "Path is not under root. Root: $rootFull Path: $pathFull"
    }
    return $pathFull.Substring($rootFull.Length + 1).Replace("/", "\")
}

function Assert-ArchiveEntryPathSafe {
    param(
        [string]$EntryName,
        [string]$ArchivePath
    )

    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        return
    }

    if ($EntryName -match "[\x00-\x1F\x7F]") {
        throw "Archive entry contains a control character in ${ArchivePath}: $EntryName"
    }
    if ([System.IO.Path]::IsPathRooted($EntryName)) {
        throw "Archive entry uses an absolute path in ${ArchivePath}: $EntryName"
    }

    $segments = @($EntryName -split "[/\\]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments -contains "..") {
        throw "Archive entry escapes the destination in ${ArchivePath}: $EntryName"
    }
}

function Assert-ExtractedTreeSafe {
    param(
        [string]$Root,
        [string]$ArchivePath
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $items = @(Get-ChildItem -LiteralPath $rootFull -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        $itemFull = [System.IO.Path]::GetFullPath($item.FullName)
        if (-not (Test-IsPathUnderDirectory $itemFull $rootFull)) {
            throw "Archive output escaped the destination in ${ArchivePath}: $itemFull"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Archive output contains a reparse point in ${ArchivePath}: $itemFull"
        }
    }
}

function Invoke-ControlledExtraction {
    param(
        [string]$Destination,
        [scriptblock]$Extract,
        [string]$ArchivePath
    )

    $destinationFull = [System.IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Parent $destinationFull
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent (".extract-" + [System.IO.Path]::GetFileName($destinationFull) + "-" + [guid]::NewGuid().ToString("N"))
    New-CleanDirectoryUnderRoot $temp $parent | Out-Null
    try {
        & $Extract $temp
        Assert-ExtractedTreeSafe $temp $ArchivePath
        New-CleanDirectoryUnderRoot $destinationFull $parent | Out-Null
        Copy-DirectoryRobust $temp $destinationFull
    }
    finally {
        Remove-IfExists $temp
    }
}








































































































































