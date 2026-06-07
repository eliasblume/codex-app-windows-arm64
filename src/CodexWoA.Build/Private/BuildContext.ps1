function New-BuildContext {
    param(
        [hashtable]$Options,
        [string]$RepoRoot
    )

    $report = [ordered]@{
        startedAt = (Get-Date).ToString("o")
        sourceMode = $Options.SourceMode
        packageIdentity = $Options.PackageIdentity
        displayName = $Options.DisplayName
        publisherSubject = $Options.PublisherSubject
        versions = [ordered]@{}
        replacements = New-Object System.Collections.Generic.List[object]
        supplyChain = New-Object System.Collections.Generic.List[object]
        commandEvidence = New-Object System.Collections.Generic.List[object]
        warnings = New-Object System.Collections.Generic.List[string]
        validation = [ordered]@{}
        outputs = [ordered]@{}
    }

    $policyPath = Join-Path $script:ModuleRoot "Data\CompatibilityPolicy.psd1"
    $policy = Import-PowerShellDataFile -LiteralPath $policyPath
    $supplyChainPolicy = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot "Data\SupplyChainPolicy.psd1")
    $buildTools = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot "Data\BuildTools.psd1")

    return [pscustomobject][ordered]@{
        Options = $Options
        Paths = [ordered]@{
            RepoRoot = $RepoRoot
            DefaultOutputDir = Join-Path $RepoRoot "dist"
            WslPayloadRelativeDir = $policy.WslPayloadRelativeDir
        }
        Tools = $buildTools
        Policy = $policy
        SupplyChainPolicy = $supplyChainPolicy
        Report = $report
    }
}
