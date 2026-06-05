#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MsixPath = "",
    [string]$CerPath = "",
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
    param([string]$ResolvedCerPath)

    Write-Host "LocalMachine certificate trust requires administrator rights. Requesting elevation..."
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-TrustCertificateOnly",
        "-CerPath", "`"$ResolvedCerPath`""
    )
    $process = Start-Process -FilePath (Get-CurrentPowerShellExecutable) -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated certificate trust failed with exit code $($process.ExitCode)."
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
        [string]$Path,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$StorePath,
        [string]$StoreLabel
    )

    if (Test-CertificateInStore $Certificate $StorePath) {
        Write-Host "Certificate already trusted in ${StoreLabel}: $($Certificate.Thumbprint)"
        return
    }

    Write-Host "Trusting Codex WoA certificate in ${StoreLabel}: $($Certificate.Thumbprint)"
    Import-Certificate -FilePath $Path -CertStoreLocation $StorePath | Out-Null

    if (-not (Test-CertificateInStore $Certificate $StorePath)) {
        throw "Certificate import completed, but trust could not be confirmed in ${StoreLabel}: $($Certificate.Thumbprint)"
    }

    Write-Host "Certificate trust confirmed in $StoreLabel."
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

$CerPath = [System.IO.Path]::GetFullPath($CerPath)
if (-not (Test-Path -LiteralPath $CerPath)) {
    throw "Certificate not found: $CerPath"
}
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)

if ($TrustCertificateOnly) {
    if (-not (Test-IsAdministrator)) {
        throw "Trusting a LocalMachine certificate requires administrator rights."
    }
    Ensure-CertificateInStore $CerPath $cert $machineStorePath $machineStoreLabel
    exit 0
}

$MsixPath = [System.IO.Path]::GetFullPath($MsixPath)
if (-not (Test-Path -LiteralPath $MsixPath)) {
    throw "MSIX not found: $MsixPath"
}

Write-Host "Checking MSIX signer..."
$signature = Assert-MsixSignerMatchesCertificate $MsixPath $cert

Write-Host "Checking certificate trust..."
if ((-not (Test-CertificateInStore $cert $machineStorePath)) -and (-not (Test-IsAdministrator))) {
    Invoke-ElevatedCertificateTrust $CerPath
}

Ensure-CertificateInStore $CerPath $cert $machineStorePath $machineStoreLabel

$signatureAfterTrust = Get-AuthenticodeSignature -LiteralPath $MsixPath
if ($signatureAfterTrust.Status -ne "Valid") {
    Write-Warning "MSIX signature status is '$($signatureAfterTrust.Status)' after the certificate trust step. Add-AppxPackage will perform final deployment validation."
}

Write-Host "Installing $MsixPath..."
Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown
[Environment]::SetEnvironmentVariable("CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE", "1", "User")
Clear-CodexBundledPluginCache
Write-Host "Done. Restart Codex to enable Computer Use."