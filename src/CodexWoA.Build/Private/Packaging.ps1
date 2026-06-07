function Update-AppxManifest {
    param(
        [string]$ManifestPath,
        [string]$IdentityName,
        [string]$DisplayNameValue,
        [string]$PublisherValue,
        [string]$VersionValue = ""
    )

    Write-Step "Rewriting AppxManifest.xml"
    [xml]$manifest = Get-Content -LiteralPath $ManifestPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $ns.AddNamespace("mp", "http://schemas.microsoft.com/appx/2014/phone/manifest")

    $identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $ns)
    if ($null -eq $identity) {
        throw "Manifest Identity node not found"
    }
    $identity.SetAttribute("Name", $IdentityName)
    $identity.SetAttribute("ProcessorArchitecture", "arm64")
    $identity.SetAttribute("Publisher", $PublisherValue)
    if (-not [string]::IsNullOrWhiteSpace($VersionValue)) {
        $identity.SetAttribute("Version", $VersionValue)
    }

    $properties = $manifest.SelectSingleNode("/f:Package/f:Properties", $ns)
    if ($null -ne $properties) {
        $displayNode = $properties.SelectSingleNode("f:DisplayName", $ns)
        if ($null -ne $displayNode) {
            $displayNode.InnerText = $DisplayNameValue
        }
        $publisherDisplayNode = $properties.SelectSingleNode("f:PublisherDisplayName", $ns)
        if ($null -ne $publisherDisplayNode) {
            $publisherDisplayNode.InnerText = $DisplayNameValue
        }
    }

    $visualElements = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application/uap:VisualElements", $ns)
    if ($null -ne $visualElements) {
        $visualElements.SetAttribute("DisplayName", $DisplayNameValue)
        $visualElements.SetAttribute("Description", $DisplayNameValue)
    }

    $phoneIdentity = $manifest.SelectSingleNode("/f:Package/mp:PhoneIdentity", $ns)
    if ($null -ne $phoneIdentity) {
        $phoneIdentity.ParentNode.RemoveChild($phoneIdentity) | Out-Null
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($ManifestPath, $settings)
    try {
        $manifest.Save($writer)
    }
    finally {
        $writer.Close()
    }
}

function Remove-SourcePackageMetadata {
    param([string]$PackageRoot)

    foreach ($relative in @(
        "AppxBlockMap.xml",
        "AppxSignature.p7x",
        "AppxMetadata",
        "microsoft.system.package.metadata"
    )) {
        Remove-IfExists (Join-Path $PackageRoot $relative)
    }
}

function Ensure-SigningCertificate {
    param(
        [string]$Subject,
        [string]$CertificateDir
    )

    New-Item -ItemType Directory -Path $CertificateDir -Force | Out-Null
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $cert) {
        Write-Step "Creating self-signed code signing certificate"
        $cert = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $Subject `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -KeyUsage DigitalSignature `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}false") `
            -NotAfter (Get-Date).AddYears(5)
    }
    else {
        Write-Step "Reusing existing self-signed certificate $($cert.Thumbprint)"
    }

    $cerPath = Join-Path $CertificateDir "CodexWoA.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

    $script:Context.Report.outputs.certificate = $cerPath
    $script:Context.Report.outputs.certificateThumbprint = $cert.Thumbprint
    return $cert
}

function New-InstallScript {
    param(
        [string]$OutputPath,
        [string]$MsixFileName,
        [string]$CerRelativePath,
        [string]$ExpectedCerThumbprint,
        [string]$ExpectedPackageIdentity,
        [string]$ExpectedPackageVersion
    )

    $content = Get-Content -LiteralPath (Join-Path $script:Context.Paths.RepoRoot "src\CodexWoA.Build\Templates\Install.ps1") -Raw

    $content = $content.
        Replace("__MSIX_FILE_NAME__", $MsixFileName).
        Replace("__CER_RELATIVE_PATH__", $CerRelativePath).
        Replace("__EXPECTED_CER_THUMBPRINT__", $ExpectedCerThumbprint).
        Replace("__EXPECTED_PACKAGE_IDENTITY__", $ExpectedPackageIdentity).
        Replace("__EXPECTED_PACKAGE_VERSION__", $ExpectedPackageVersion)

    Set-TextUtf8NoBom $OutputPath $content
}

function New-InstallBatchScript {
    param([string]$OutputPath)

    $content = Get-Content -LiteralPath (Join-Path $script:Context.Paths.RepoRoot "src\CodexWoA.Build\Templates\Install.bat") -Raw

    Set-TextUtf8NoBom $OutputPath $content
}

function Pack-And-SignMsix {
    param(
        [string]$PackageRoot,
        [string]$MsixPath,
        [string]$MakeAppxPath,
        [string]$SignToolPath,
        [object]$Certificate
    )

    Write-Step "Packing MSIX"
    Remove-IfExists $MsixPath
    Invoke-Checked $MakeAppxPath @("pack", "/d", $PackageRoot, "/p", $MsixPath, "/o")

    Write-Step "Signing MSIX"
    Invoke-Checked $SignToolPath @(
        "sign",
        "/fd", "SHA256",
        "/sha1", $Certificate.Thumbprint,
        $MsixPath
    )
}
