#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MsixPath = "",
    [string]$CerPath = "",
    [string]$ExpectedCerThumbprint = "__EXPECTED_CER_THUMBPRINT__",
    [switch]$RemoveTrustedCertificateOnly,
    [switch]$TrustCertificateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    Get-Location
}

$script:ExpectedPackageIdentity = "__EXPECTED_PACKAGE_IDENTITY__"
$script:ExpectedPackageArchitecture = "arm64"
$script:ExpectedPackageVersion = "__EXPECTED_PACKAGE_VERSION__"

if ([string]::IsNullOrWhiteSpace($MsixPath)) {
    $MsixPath = Join-Path $script:ScriptRoot "__MSIX_FILE_NAME__"
}

if ([string]::IsNullOrWhiteSpace($CerPath)) {
    $CerPath = Join-Path $script:ScriptRoot "__CER_RELATIVE_PATH__"
    if (-not (Test-Path -LiteralPath $CerPath)) {
        $flatCerPath = Join-Path $script:ScriptRoot "CodexWoA.cer"
        if (Test-Path -LiteralPath $flatCerPath) {
            $CerPath = $flatCerPath
        }
    }
}

function Assert-MsixSignerMatchesCertificate {
    param(
        [string]$Path,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($null -eq $signature.SignerCertificate) {
        throw "MSIX does not contain an Authenticode signer: $Path"
    }

    if ($signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint) {
        throw "MSIX signer thumbprint $($signature.SignerCertificate.Thumbprint) does not match certificate file $($Certificate.Thumbprint)."
    }

    return $signature
}

function Assert-MsixManifestMatchesExpected {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq "AppxManifest.xml" } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "MSIX does not contain AppxManifest.xml: $Path"
        }

        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try {
                [xml]$manifest = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    $identity = $manifest.Package.Identity
    if ($identity.Name -ne $script:ExpectedPackageIdentity) {
        throw "MSIX identity $($identity.Name) does not match expected identity $script:ExpectedPackageIdentity."
    }
    if ($identity.ProcessorArchitecture -ne $script:ExpectedPackageArchitecture) {
        throw "MSIX architecture $($identity.ProcessorArchitecture) does not match expected architecture $script:ExpectedPackageArchitecture."
    }
    if ($identity.Version -ne $script:ExpectedPackageVersion) {
        throw "MSIX version $($identity.Version) does not match expected version $script:ExpectedPackageVersion."
    }

    return [pscustomobject][ordered]@{
        Identity = [string]$identity.Name
        Architecture = [string]$identity.ProcessorArchitecture
        Version = [string]$identity.Version
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentPowerShellExecutable {
    try {
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($processPath) -and (Test-Path -LiteralPath $processPath)) {
            return $processPath
        }
    }
    catch {
    }

    $pwsh = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) {
        return $pwsh.Source
    }

    return "powershell.exe"
}

function Invoke-ElevatedCertificateTrust {
    param(
        [string]$ResolvedCerPath,
        [string]$ExpectedThumbprint
    )

    Write-Host "LocalMachine certificate trust requires administrator rights. Requesting elevation..."
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-TrustCertificateOnly",
        "-CerPath", "`"$ResolvedCerPath`"",
        "-ExpectedCerThumbprint", $ExpectedThumbprint
    )
    $process = Start-Process -FilePath (Get-CurrentPowerShellExecutable) -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated certificate trust failed with exit code $($process.ExitCode)."
    }
}

function Invoke-ElevatedCertificateRemoval {
    param([string]$ExpectedThumbprint)

    Write-Host "Rolling back LocalMachine certificate trust. Requesting elevation..."
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-RemoveTrustedCertificateOnly",
        "-ExpectedCerThumbprint", $ExpectedThumbprint
    )
    $process = Start-Process -FilePath (Get-CurrentPowerShellExecutable) -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated certificate trust rollback failed with exit code $($process.ExitCode)."
    }
}

function Test-CertificateInStore {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$StorePath
    )

    $trustedPath = Join-Path $StorePath $Certificate.Thumbprint
    return (Test-Path -LiteralPath $trustedPath)
}

function Ensure-CertificateInStore {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$StorePath,
        [string]$StoreLabel
    )

    if (Test-CertificateInStore $Certificate $StorePath) {
        Write-Host "Certificate already trusted in ${StoreLabel}: $($Certificate.Thumbprint)"
        return
    }

    Write-Host "Trusting Codex WoA certificate in ${StoreLabel}: $($Certificate.Thumbprint)"
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($Certificate)
    }
    finally {
        $store.Dispose()
    }

    if (-not (Test-CertificateInStore $Certificate $StorePath)) {
        throw "Certificate import completed, but trust could not be confirmed in ${StoreLabel}: $($Certificate.Thumbprint)"
    }

    Write-Host "Certificate trust confirmed in $StoreLabel."
}

function Remove-CertificateFromStore {
    param(
        [string]$Thumbprint,
        [string]$StoreLabel
    )

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $matches = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Thumbprint,
            $false)
        foreach ($certificate in $matches) {
            Write-Host "Removing Codex WoA certificate from ${StoreLabel}: $Thumbprint"
            $store.Remove($certificate)
        }
    }
    finally {
        $store.Dispose()
    }
}

function Assert-ExpectedCertificateThumbprint {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$ExpectedThumbprint
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedThumbprint)) {
        throw "Expected certificate thumbprint is required for elevated trust operations."
    }

    if ($Certificate.Thumbprint -ne $ExpectedThumbprint) {
        throw "Certificate thumbprint $($Certificate.Thumbprint) does not match expected thumbprint $ExpectedThumbprint."
    }
}

function Clear-CodexBundledPluginCache {
    $cacheRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled"
    if (-not (Test-Path -LiteralPath $cacheRoot)) {
        return
    }

    $cacheDirs = @(
        (Join-Path $cacheRoot "browser"),
        (Join-Path $cacheRoot "chrome"),
        (Join-Path $cacheRoot "computer-use")
    )

    foreach ($cacheDir in $cacheDirs) {
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            continue
        }

        try {
            Write-Host "Clearing bundled plugin cache: $cacheDir"
            Remove-Item -LiteralPath $cacheDir -Recurse -Force
        }
        catch {
            Write-Warning "Could not clear bundled plugin cache '$cacheDir': $($_.Exception.Message). Close Codex and remove this directory manually before retesting bundled plugins."
        }
    }
}

$machineStorePath = "Cert:\LocalMachine\TrustedPeople"
$machineStoreLabel = "LocalMachine\TrustedPeople"

if ($RemoveTrustedCertificateOnly) {
    if (-not (Test-IsAdministrator)) {
        throw "Removing a LocalMachine certificate requires administrator rights."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedCerThumbprint)) {
        throw "Expected certificate thumbprint is required for elevated trust rollback."
    }
    Remove-CertificateFromStore $ExpectedCerThumbprint $machineStoreLabel
    exit 0
}

$CerPath = [System.IO.Path]::GetFullPath($CerPath)
if (-not (Test-Path -LiteralPath $CerPath)) {
    throw "Certificate not found: $CerPath"
}
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)
Assert-ExpectedCertificateThumbprint $cert $ExpectedCerThumbprint

if ($TrustCertificateOnly) {
    if (-not (Test-IsAdministrator)) {
        throw "Trusting a LocalMachine certificate requires administrator rights."
    }
    Assert-ExpectedCertificateThumbprint $cert $ExpectedCerThumbprint
    Ensure-CertificateInStore $cert $machineStorePath $machineStoreLabel
    exit 0
}

$MsixPath = [System.IO.Path]::GetFullPath($MsixPath)
if (-not (Test-Path -LiteralPath $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}

Write-Host "Checking MSIX signer..."
$signature = Assert-MsixSignerMatchesCertificate $MsixPath $cert

Write-Host "Checking MSIX manifest..."
$manifestIdentity = Assert-MsixManifestMatchesExpected $MsixPath

Write-Host "Checking certificate trust..."
$certificateWasTrusted = Test-CertificateInStore $cert $machineStorePath
if ((-not $certificateWasTrusted) -and (-not (Test-IsAdministrator))) {
    Invoke-ElevatedCertificateTrust $CerPath $ExpectedCerThumbprint
}

Ensure-CertificateInStore $cert $machineStorePath $machineStoreLabel

$signature | Out-Null
$manifestIdentity | Out-Null
Write-Host "Trusted certificate thumbprint: $ExpectedCerThumbprint"
Write-Host "Trusted certificate store: $machineStoreLabel"
Write-Host "Rollback: .\Install.ps1 -RemoveTrustedCertificateOnly"

$signatureAfterTrust = Get-AuthenticodeSignature -LiteralPath $MsixPath
if ($signatureAfterTrust.Status -ne "Valid") {
    Write-Warning "MSIX signature status is '$($signatureAfterTrust.Status)' after the certificate trust step. Add-AppxPackage will perform final deployment validation."
}

Write-Host "Installing $MsixPath..."
try {
    Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown
}
catch {
    if (-not $certificateWasTrusted) {
        try {
            if (Test-IsAdministrator) {
                Remove-CertificateFromStore $ExpectedCerThumbprint $machineStoreLabel
            }
            else {
                Invoke-ElevatedCertificateRemoval $ExpectedCerThumbprint
            }
        }
        catch {
            Write-Warning "Could not roll back certificate trust: $($_.Exception.Message)"
        }
    }
    throw
}
[Environment]::SetEnvironmentVariable("CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE", "1", "User")
Clear-CodexBundledPluginCache
Write-Host "Done. Restart Codex to enable Computer Use."
