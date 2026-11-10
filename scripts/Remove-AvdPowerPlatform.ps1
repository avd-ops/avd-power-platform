# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()][ValidateSet('commercial', 'usgov')][string]$Cloud = 'commercial',
    [Parameter()][string]$RunManifestPath = './power-platform-run-manifest.json',
    [Parameter()][switch]$DiscardLastCopy,
    [Parameter()][switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$cloudExplicit = $PSBoundParameters.ContainsKey('Cloud')

function Resolve-AvdCloudEnvironment {
    param(
        [Parameter(Mandatory)][ValidateSet('commercial', 'usgov')][string]$CloudProfile,
        [Parameter()][string]$ContractPath = (Join-Path $repoRoot 'contracts/cloud-environments.json')
    )
    if (-not (Test-Path -LiteralPath $ContractPath)) {
        throw "Cloud environments contract (C26) not found at '$ContractPath'."
    }
    $c26 = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $null
    if ($null -ne $c26.PSObject.Properties['clouds'] -and $null -ne $c26.clouds.PSObject.Properties[$CloudProfile]) {
        $entry = $c26.clouds.$CloudProfile
    }
    if ($null -eq $entry -and $null -ne $c26.PSObject.Properties['environments']) {
        $entry = @($c26.environments | Where-Object { $_.id -eq $CloudProfile }) | Select-Object -First 1
    }
    if ($null -eq $entry) {
        throw "Cloud profile '$CloudProfile' not found in '$ContractPath'."
    }

    $bapEndpoint = if ($CloudProfile -eq 'usgov') {
        'https://gov.api.bap.microsoft.us'
    }
    else {
        [string]$entry.powerPlatform.bapEndpoint
    }

    return [pscustomobject]@{
        id                = $CloudProfile
        azCloudName       = [string]$entry.azCloudName
        psEnvironmentName = [string]$entry.psEnvironmentName
        entraEnvironment  = [string]$entry.entraEnvironment
        bapEndpoint       = $bapEndpoint
        pacCloud          = [string]$entry.powerPlatform.pacCloud
    }
}

if (-not $DiscardLastCopy.IsPresent) {
    throw 'Refusing to delete stateful Power Platform environment and run manifest without -DiscardLastCopy. Verify a backup exists or pass -DiscardLastCopy.'
}

if (-not (Test-Path -LiteralPath $RunManifestPath)) {
    throw "Run manifest not found at '$RunManifestPath'."
}

$isDryRun = $DryRun.IsPresent -or ($env:AVD_OPS_DRY_RUN -eq '1')
$runManifest = Get-Content -LiteralPath $RunManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$manifestCloud = if ($null -ne $runManifest.PSObject.Properties['cloud']) { [string]$runManifest.cloud } else { '' }
if (-not $cloudExplicit -and $manifestCloud -in @('commercial', 'usgov')) {
    $Cloud = $manifestCloud
}
if ($cloudExplicit -and -not [string]::IsNullOrWhiteSpace($manifestCloud) -and $manifestCloud -ne $Cloud) {
    throw "Cloud mismatch: power-platform-run-manifest.json declares cloud '$manifestCloud', which does not match target cloud '$Cloud'."
}

$cloudEnv = Resolve-AvdCloudEnvironment -CloudProfile $Cloud
if (Get-Command -Name 'Get-AzContext' -ErrorAction SilentlyContinue) {
    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -ne $azCtx -and $null -ne $azCtx.Environment -and -not [string]::IsNullOrWhiteSpace([string]$azCtx.Environment.Name)) {
        if ([string]$azCtx.Environment.Name -ne $cloudEnv.psEnvironmentName) {
            throw "Cloud mismatch: active Az PowerShell environment '$($azCtx.Environment.Name)' does not match expected '$($cloudEnv.psEnvironmentName)' for cloud '$($cloudEnv.id)'."
        }
    }
}
if (-not $isDryRun -and (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    $activeAzCloudRaw = & az cloud show --query name -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($activeAzCloudRaw)) {
        $activeAzCloud = $activeAzCloudRaw.Trim()
        if ($activeAzCloud -ne $cloudEnv.azCloudName) {
            throw "Cloud mismatch: active Azure CLI cloud '$activeAzCloud' does not match expected '$($cloudEnv.azCloudName)' for cloud '$($cloudEnv.id)'."
        }
    }
}

$prefix = [string]$runManifest.prefix
$environment = [string]$runManifest.environment
$expectedStamp = "[avd-ops-$prefix-$environment]"
$expectedEpName = "ep-avd-$prefix-$environment"
$bapBase = $cloudEnv.bapEndpoint.TrimEnd('/')

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
                $deleteDlpUrl = "$bapBase/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies/$($dlp.id)?api-version=2020-10-01"
                & az rest --method DELETE --url $deleteDlpUrl | Out-Null
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
                $deleteEnvUrl = "$bapBase/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($ppEnv.id)?api-version=2023-06-01"
                & az rest --method DELETE --url $deleteEnvUrl | Out-Null
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

