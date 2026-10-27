# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()][string]$RunManifestPath = './power-platform-run-manifest.json',
    [Parameter()][switch]$DiscardLastCopy,
    [Parameter()][switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $DiscardLastCopy.IsPresent) {
    throw 'Refusing to delete stateful Power Platform environment and run manifest without -DiscardLastCopy. Verify a backup exists or pass -DiscardLastCopy.'
}

if (-not (Test-Path -LiteralPath $RunManifestPath)) {
    throw "Run manifest not found at '$RunManifestPath'."
}

$isDryRun = $DryRun.IsPresent -or ($env:AVD_OPS_DRY_RUN -eq '1')
$runManifest = Get-Content -LiteralPath $RunManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$prefix = [string]$runManifest.prefix
$environment = [string]$runManifest.environment
$expectedStamp = "[avd-ops-$prefix-$environment]"
$expectedEpName = "ep-avd-$prefix-$environment"

if ([string]$runManifest.stamp -ne $expectedStamp) {
    throw "Run manifest stamp '$($runManifest.stamp)' does not match expected stamp '$expectedStamp'."
}

$removedItems = @()

# 1. Remove DLP Policy if created by this run and stamped
if ($null -ne $runManifest.PSObject.Properties['dlpPolicy'] -and $null -ne $runManifest.dlpPolicy) {
    $dlp = $runManifest.dlpPolicy
    if ($dlp.created -eq $true -and ([string]$dlp.displayName).StartsWith($expectedStamp)) {
        if ($PSCmdlet.ShouldProcess($dlp.displayName, 'Delete Power Platform DLP policy')) {
            if (-not $isDryRun -and -not [string]::IsNullOrWhiteSpace([string]$dlp.id)) {
                & az rest --method DELETE --url "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies/$($dlp.id)?api-version=2020-10-01" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete DLP policy '$($dlp.displayName)' ($($dlp.id))."
                }
            }
            $removedItems += "dlpPolicy:$($dlp.displayName)"
        }
    }
}

# 2. Remove Power Platform Environment if created by this run and stamped
if ($null -ne $runManifest.PSObject.Properties['powerPlatformEnvironment'] -and $null -ne $runManifest.powerPlatformEnvironment) {
    $ppEnv = $runManifest.powerPlatformEnvironment
    if ($ppEnv.created -eq $true -and ([string]$ppEnv.displayName).StartsWith($expectedStamp)) {
        if ($PSCmdlet.ShouldProcess($ppEnv.displayName, 'Delete Power Platform environment')) {
            if (-not $isDryRun -and -not [string]::IsNullOrWhiteSpace([string]$ppEnv.id)) {
                & az rest --method DELETE --url "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($ppEnv.id)?api-version=2023-06-01" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete Power Platform environment '$($ppEnv.displayName)' ($($ppEnv.id))."
                }
            }
            $removedItems += "powerPlatformEnvironment:$($ppEnv.displayName)"
        }
    }
}

# 3. Remove Bicep Enterprise Policy if created by this run and matching expected name
if ($null -ne $runManifest.PSObject.Properties['enterprisePolicy'] -and $null -ne $runManifest.enterprisePolicy) {
    $ep = $runManifest.enterprisePolicy
    if ($ep.deployed -eq $true -and $ep.created -eq $true -and [string]$ep.name -eq $expectedEpName) {
        if ($PSCmdlet.ShouldProcess($ep.name, 'Delete Microsoft.PowerPlatform/enterprisePolicies resource')) {
            if (-not $isDryRun -and -not [string]::IsNullOrWhiteSpace([string]$ep.id)) {
                & az resource delete --ids $ep.id | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete enterprise policy '$($ep.id)'."
                }
            }
            $removedItems += "enterprisePolicy:$($ep.name)"
        }
    }
}

# 4. Clean up local packed solution artifacts and run manifest
if ($null -ne $runManifest.PSObject.Properties['solution'] -and $null -ne $runManifest.solution) {
    $sol = $runManifest.solution
    foreach ($artifactPath in @($sol.packedZipPath, $sol.deploymentSettingsPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$artifactPath) -and (Test-Path -LiteralPath $artifactPath)) {
            if ($PSCmdlet.ShouldProcess($artifactPath, 'Remove generated solution artifact')) {
                Remove-Item -LiteralPath $artifactPath -Force
            }
        }
    }
}

if ($PSCmdlet.ShouldProcess($RunManifestPath, 'Remove Power Platform run manifest')) {
    Remove-Item -LiteralPath $RunManifestPath -Force
}

Write-Output ($removedItems -join ',')
