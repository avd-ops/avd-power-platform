# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$EntraManifestPath = './entra-manifest.json',
    [Parameter()][string]$AzureOutputsPath = './azure-outputs.json',
    [Parameter()][string]$OutputPath = './power-platform-manifest.json',
    [Parameter()][string]$RunManifestPath = './power-platform-run-manifest.json',
    [Parameter()][string]$SolutionSourcePath = '',
    [Parameter()][string]$PackedSolutionZipPath = '',
    [Parameter()][switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SolutionSourcePath)) {
    $SolutionSourcePath = Join-Path $repoRoot 'solutions/AvdDay2Automation'
}
if ([string]::IsNullOrWhiteSpace($PackedSolutionZipPath)) {
    $outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
    $PackedSolutionZipPath = Join-Path $outDir 'AvdDay2Automation.zip'
}

$isDryRun = $DryRun.IsPresent -or ($env:AVD_OPS_DRY_RUN -eq '1')

function Get-ContractPropertyValue {
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $null
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    $val = $prop.Value
    if ($null -ne $val -and $val -is [pscustomobject] -and $null -ne $val.PSObject.Properties['value']) {
        return $val.value
    }
    return $val
}

function ConvertTo-PackedSolutionZip {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationZip,
        [Parameter(Mandatory)][string]$UsersGroupId,
        [Parameter(Mandatory)][string]$HostPoolArmId
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-pp-pack-" + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -Path $SourceFolder -Destination $stageDir -Recurse -Force

        # Inject avd_UsersGroupId
        $usersXmlPath = Join-Path $stageDir 'environmentvariabledefinitions/avd_UsersGroupId/environmentvariabledefinition.xml'
        if (Test-Path -LiteralPath $usersXmlPath) {
            [xml]$usersXml = Get-Content -LiteralPath $usersXmlPath -Raw -Encoding UTF8
            $usersXml.environmentvariabledefinition.defaultvalue = $UsersGroupId
            $usersXml.Save($usersXmlPath)
        }
        $usersJsonPath = Join-Path $stageDir 'environmentvariabledefinitions/avd_UsersGroupId/environmentvariablevalues.json'
        if (Test-Path -LiteralPath $usersJsonPath) {
            $usersJson = Get-Content -LiteralPath $usersJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $usersJson.environmentvariablevalues.environmentvariablevalue.value = $UsersGroupId
            $usersJson | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $usersJsonPath -Encoding UTF8
        }

        # Inject avd_HostPoolArmId
        $hpXmlPath = Join-Path $stageDir 'environmentvariabledefinitions/avd_HostPoolArmId/environmentvariabledefinition.xml'
        if (Test-Path -LiteralPath $hpXmlPath) {
            [xml]$hpXml = Get-Content -LiteralPath $hpXmlPath -Raw -Encoding UTF8
            $hpXml.environmentvariabledefinition.defaultvalue = $HostPoolArmId
            $hpXml.Save($hpXmlPath)
        }
        $hpJsonPath = Join-Path $stageDir 'environmentvariabledefinitions/avd_HostPoolArmId/environmentvariablevalues.json'
        if (Test-Path -LiteralPath $hpJsonPath) {
            $hpJson = Get-Content -LiteralPath $hpJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hpJson.environmentvariablevalues.environmentvariablevalue.value = $HostPoolArmId
            $hpJson | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $hpJsonPath -Encoding UTF8
        }

        $destParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($DestinationZip))
        if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $DestinationZip) {
            Remove-Item -LiteralPath $DestinationZip -Force
        }

        $zipFullPath = [System.IO.Path]::GetFullPath($DestinationZip)
        $stageFullPath = [System.IO.Path]::GetFullPath($stageDir)
        $zipStream = [System.IO.File]::Open($zipFullPath, [System.IO.FileMode]::Create)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $files = Get-ChildItem -LiteralPath $stageFullPath -Recurse -File
                foreach ($file in $files) {
                    $relPath = $file.FullName.Substring($stageFullPath.Length).TrimStart('\', '/').Replace('\', '/')
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive,
                        $file.FullName,
                        $relPath,
                        [System.IO.Compression.CompressionLevel]::Optimal
                    ) | Out-Null
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $zipStream.Dispose()
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageDir) {
            Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 0. Parse input manifests
if (-not (Test-Path -LiteralPath $EntraManifestPath)) {
    throw "Entra manifest file not found at '$EntraManifestPath'."
}
if (-not (Test-Path -LiteralPath $AzureOutputsPath)) {
    throw "Azure outputs file not found at '$AzureOutputsPath'."
}

$entraManifest = Get-Content -LiteralPath $EntraManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$azureRaw = Get-Content -LiteralPath $AzureOutputsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$azureOutputs = if ($null -ne $azureRaw.PSObject.Properties['outputs'] -and $azureRaw.outputs -is [pscustomobject]) {
    $azureRaw.outputs
}
else {
    $azureRaw
}

$environment = [string](Get-ContractPropertyValue -InputObject $entraManifest -Name 'environment')
if ([string]::IsNullOrWhiteSpace($environment)) {
    $environment = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'environment')
}
if ([string]::IsNullOrWhiteSpace($environment)) {
    $environment = 'dev'
}
if ($environment -notin @('dev', 'test', 'prod')) {
    throw "Invalid environment '$environment'. Expected one of: dev, test, prod."
}

$prefix = [string](Get-ContractPropertyValue -InputObject $entraManifest -Name 'prefix')
if ([string]::IsNullOrWhiteSpace($prefix)) {
    $prefix = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'prefix')
}
if ([string]::IsNullOrWhiteSpace($prefix)) {
    $prefix = 'avd'
}

$avdUsersGroupId = $null
$groupsObj = Get-ContractPropertyValue -InputObject $entraManifest -Name 'groups'
if ($null -ne $groupsObj) {
    $avdUsersGroupId = [string](Get-ContractPropertyValue -InputObject $groupsObj -Name 'avdUsersGroupId')
}
if ([string]::IsNullOrWhiteSpace($avdUsersGroupId)) {
    $avdUsersGroupId = [string](Get-ContractPropertyValue -InputObject $entraManifest -Name 'avdUsersGroupId')
}
if ([string]::IsNullOrWhiteSpace($avdUsersGroupId)) {
    throw "groups.avdUsersGroupId is required in '$EntraManifestPath'."
}

$location = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'location')
if ([string]::IsNullOrWhiteSpace($location)) {
    $location = 'eastus'
}

$resourceGroupName = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'resourceGroupName')
if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    $rgsObj = Get-ContractPropertyValue -InputObject $azureOutputs -Name 'resourceGroups'
    if ($null -ne $rgsObj) {
        $resourceGroupName = [string](Get-ContractPropertyValue -InputObject $rgsObj -Name 'controlPlane')
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            $resourceGroupName = [string](Get-ContractPropertyValue -InputObject $rgsObj -Name 'network')
        }
    }
}
if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    $resourceGroupName = "rg-$prefix-$environment"
}

$hostPoolArmId = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'hostPoolArmId')
if ([string]::IsNullOrWhiteSpace($hostPoolArmId)) {
    $hostPoolArmId = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'hostPoolResourceId')
}
if ([string]::IsNullOrWhiteSpace($hostPoolArmId)) {
    $hostPoolsArr = Get-ContractPropertyValue -InputObject $azureOutputs -Name 'hostPools'
    if ($null -ne $hostPoolsArr -and @($hostPoolsArr).Count -gt 0) {
        $firstPool = @($hostPoolsArr)[0]
        $poolId = Get-ContractPropertyValue -InputObject $firstPool -Name 'id'
        if ([string]::IsNullOrWhiteSpace([string]$poolId)) {
            $poolId = Get-ContractPropertyValue -InputObject $firstPool -Name 'resourceId'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$poolId)) {
            $hostPoolArmId = [string]$poolId
        }
        else {
            $poolName = [string](Get-ContractPropertyValue -InputObject $firstPool -Name 'name')
            if (-not [string]::IsNullOrWhiteSpace($poolName)) {
                $hostPoolArmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$resourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$poolName"
            }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($hostPoolArmId)) {
    throw "hostPoolArmId (or hostPoolResourceId / hostPools[0]) is required in '$AzureOutputsPath'."
}

$delegatedSubnetId = [string](Get-ContractPropertyValue -InputObject $azureOutputs -Name 'powerPlatformDelegatedSubnetId')
if ([string]::IsNullOrWhiteSpace($delegatedSubnetId)) {
    $networkObj = Get-ContractPropertyValue -InputObject $azureOutputs -Name 'network'
    if ($null -ne $networkObj) {
        $delegatedSubnetId = [string](Get-ContractPropertyValue -InputObject $networkObj -Name 'powerPlatformDelegatedSubnetId')
    }
}

$stamp = "[avd-ops-$prefix-$environment]"
$environmentDisplayName = "$stamp AVD Day-2 Automation"
$dlpPolicyDisplayName = "$stamp AVD Day-2 Automation Strict DLP Policy"
$enterprisePolicyName = "ep-avd-$prefix-$environment"

$existingRunManifest = $null
if (Test-Path -LiteralPath $RunManifestPath) {
    try {
        $existingRunManifest = Get-Content -LiteralPath $RunManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $existingRunManifest = $null
    }
}

if (-not $PSCmdlet.ShouldProcess($environmentDisplayName, 'Deploy Power Platform environment, VNet policy, strict DLP policy, and packed solution')) {
    return
}

# Step 1: Preflight SKU Check (Power Automate / Power Platform service plans)
$detectedSkus = @()
if ($isDryRun) {
    $detectedSkus = @('FLOW_FREE')
}
else {
    $skuResponseRaw = & az rest --method GET --url 'https://graph.microsoft.com/v1.0/subscribedSkus' -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($skuResponseRaw)) {
        throw 'Failed to query Microsoft Graph subscribedSkus during preflight check.'
    }
    $skuResponse = $skuResponseRaw | ConvertFrom-Json
    foreach ($sku in @($skuResponse.value)) {
        if ($sku.capabilityStatus -eq 'Enabled') {
            foreach ($plan in @($sku.servicePlans)) {
                if ($plan.servicePlanName -match '^(FLOW_|POWERAPPS_|POWER_AUTOMATE)') {
                    $detectedSkus += [string]$plan.servicePlanName
                }
            }
        }
    }
    $detectedSkus = @($detectedSkus | Select-Object -Unique)
}

# Step 2: Conditional Bicep VNet Injection (Microsoft.PowerPlatform/enterprisePolicies)
$enterprisePolicyRecord = [ordered]@{
    deployed          = $false
    created           = $false
    name              = $enterprisePolicyName
    resourceGroupName = $resourceGroupName
    id                = $null
    delegatedSubnetId = $null
}

if (-not [string]::IsNullOrWhiteSpace($delegatedSubnetId)) {
    $bicepTemplatePath = Join-Path $repoRoot 'bicep/main.bicep'
    if (-not (Test-Path -LiteralPath $bicepTemplatePath)) {
        throw "Bicep template not found at '$bicepTemplatePath'."
    }
    if ($isDryRun) {
        $alreadyExisted = (
            $null -ne $existingRunManifest -and
            $null -ne $existingRunManifest.PSObject.Properties['enterprisePolicy'] -and
            $existingRunManifest.enterprisePolicy.deployed -eq $true -and
            $existingRunManifest.enterprisePolicy.name -eq $enterprisePolicyName
        )
        $epId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$resourceGroupName/providers/Microsoft.PowerPlatform/enterprisePolicies/$enterprisePolicyName"
        $enterprisePolicyRecord = [ordered]@{
            deployed          = $true
            created           = (-not $alreadyExisted)
            name              = $enterprisePolicyName
            resourceGroupName = $resourceGroupName
            id                = $epId
            delegatedSubnetId = $delegatedSubnetId
        }
    }
    else {
        $existingEpRaw = & az resource show --resource-group $resourceGroupName --resource-type 'Microsoft.PowerPlatform/enterprisePolicies' --name $enterprisePolicyName -o json 2>$null
        $epExisted = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingEpRaw))

        $epId = & az deployment group create `
            --resource-group $resourceGroupName `
            --template-file $bicepTemplatePath `
            --parameters enterprisePolicyName=$enterprisePolicyName location=$location delegatedSubnetId=$delegatedSubnetId `
            --query 'properties.outputs.enterprisePolicyId.value' `
            -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($epId)) {
            throw "Failed to deploy Bicep enterprise policy '$enterprisePolicyName' in resource group '$resourceGroupName'."
        }
        $enterprisePolicyRecord = [ordered]@{
            deployed          = $true
            created           = (-not $epExisted)
            name              = $enterprisePolicyName
            resourceGroupName = $resourceGroupName
            id                = $epId.Trim()
            delegatedSubnetId = $delegatedSubnetId
        }
    }
}

# Step 3: Provision / Verify Power Platform Environment & Apply DLP Baseline
$dlpBaselinePath = Join-Path $repoRoot 'dlp/avd-dlp-baseline.json'
$dlpBaseline = Get-Content -LiteralPath $dlpBaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$businessConnectors = @($dlpBaseline.businessConnectors)

$environmentRecord = [ordered]@{
    id          = $null
    displayName = $environmentDisplayName
    location    = $location
    created     = $false
}
$dlpPolicyRecord = [ordered]@{
    id                              = $null
    displayName                     = $dlpPolicyDisplayName
    defaultConnectorsClassification = [string]$dlpBaseline.defaultConnectorsClassification
    businessConnectors              = $businessConnectors
    created                         = $false
}

if ($isDryRun) {
    $envExisted = (
        $null -ne $existingRunManifest -and
        $null -ne $existingRunManifest.PSObject.Properties['powerPlatformEnvironment'] -and
        $existingRunManifest.powerPlatformEnvironment.displayName -eq $environmentDisplayName
    )
    $envId = if ($envExisted -and -not [string]::IsNullOrWhiteSpace([string]$existingRunManifest.powerPlatformEnvironment.id)) {
        [string]$existingRunManifest.powerPlatformEnvironment.id
    }
    else {
        '00000000-0000-0000-0000-000000000301'
    }
    $environmentRecord.id = $envId
    $environmentRecord.created = (-not $envExisted)

    $dlpExisted = (
        $null -ne $existingRunManifest -and
        $null -ne $existingRunManifest.PSObject.Properties['dlpPolicy'] -and
        $existingRunManifest.dlpPolicy.displayName -eq $dlpPolicyDisplayName
    )
    $dlpId = if ($dlpExisted -and -not [string]::IsNullOrWhiteSpace([string]$existingRunManifest.dlpPolicy.id)) {
        [string]$existingRunManifest.dlpPolicy.id
    }
    else {
        '00000000-0000-0000-0000-000000000401'
    }
    $dlpPolicyRecord.id = $dlpId
    $dlpPolicyRecord.created = (-not $dlpExisted)
}
else {
    $envListRaw = & az rest --method GET --url 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01' -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($envListRaw)) {
        throw 'Failed to list Power Platform environments via BAP REST API.'
    }
    $envList = $envListRaw | ConvertFrom-Json
    $matchedEnv = @($envList.value | Where-Object { $_.properties.displayName -eq $environmentDisplayName }) | Select-Object -First 1

    if ($null -ne $matchedEnv) {
        $environmentRecord.id = [string]$matchedEnv.name
        $environmentRecord.created = $false
    }
    else {
        $createEnvBody = @{
            location   = 'unitedstates'
            properties = @{
                displayName    = $environmentDisplayName
                environmentSku = 'Sandbox'
                azureRegion    = $location
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $createdEnvRaw = & az rest --method POST --url 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments?api-version=2023-06-01' --headers 'Content-Type=application/json' --body $createEnvBody -o json
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($createdEnvRaw)) {
            throw "Failed to create Power Platform environment '$environmentDisplayName'."
        }
        $createdEnv = $createdEnvRaw | ConvertFrom-Json
        $environmentRecord.id = [string]$createdEnv.name
        $environmentRecord.created = $true
    }

    $dlpListRaw = & az rest --method GET --url 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies?api-version=2020-10-01' -o json
    $matchedDlp = $null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($dlpListRaw)) {
        $dlpList = $dlpListRaw | ConvertFrom-Json
        $matchedDlp = @($dlpList.value | Where-Object { $_.properties.displayName -eq $dlpPolicyDisplayName }) | Select-Object -First 1
    }

    if ($null -ne $matchedDlp) {
        $dlpPolicyRecord.id = [string]$matchedDlp.name
        $dlpPolicyRecord.created = $false
    }
    else {
        $policyNameGuid = [guid]::NewGuid().ToString()
        $dlpBody = @{
            properties = @{
                displayName                     = $dlpPolicyDisplayName
                defaultConnectorsClassification = [string]$dlpBaseline.defaultConnectorsClassification
                connectorGroups                 = @(
                    @{
                        classification = 'Confidential'
                        connectors     = @($businessConnectors | ForEach-Object { @{ id = $_; name = ($_ -split '/')[-1]; type = 'Microsoft.PowerApps/apis' } })
                    }
                )
                environments                    = @(
                    @{
                        id   = "/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($environmentRecord.id)"
                        name = $environmentRecord.id
                        type = 'Microsoft.BusinessAppPlatform/scopes/environments'
                    }
                )
            }
        } | ConvertTo-Json -Depth 10 -Compress
        & az rest --method PUT --url "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies/$($policyNameGuid)?api-version=2020-10-01" --headers 'Content-Type=application/json' --body $dlpBody -o json | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create DLP policy '$dlpPolicyDisplayName'."
        }
        $dlpPolicyRecord.id = $policyNameGuid
        $dlpPolicyRecord.created = $true
    }
}

# Step 4: Pack Solution .zip, Inject Environment Variables, and Import
ConvertTo-PackedSolutionZip `
    -SourceFolder $SolutionSourcePath `
    -DestinationZip $PackedSolutionZipPath `
    -UsersGroupId $avdUsersGroupId `
    -HostPoolArmId $hostPoolArmId

$settingsFilePath = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($PackedSolutionZipPath))) 'deploymentSettings.json'
$deploymentSettings = [ordered]@{
    EnvironmentVariables = @(
        [ordered]@{
            SchemaName = 'avd_UsersGroupId'
            Value      = $avdUsersGroupId
        },
        [ordered]@{
            SchemaName = 'avd_HostPoolArmId'
            Value      = $hostPoolArmId
        }
    )
    ConnectionReferences = @()
}
$deploymentSettings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsFilePath -Encoding UTF8

$solutionExisted = (
    $null -ne $existingRunManifest -and
    $null -ne $existingRunManifest.PSObject.Properties['solution'] -and
    $existingRunManifest.solution.uniqueName -eq 'AvdDay2Automation'
)

if (-not $isDryRun) {
    $pacCmd = Get-Command -Name 'pac' -ErrorAction SilentlyContinue
    if ($null -ne $pacCmd) {
        & pac solution import --path $PackedSolutionZipPath --environment $environmentRecord.id --settings-file $settingsFilePath --publish-changes --async
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to import solution '$PackedSolutionZipPath' into environment '$($environmentRecord.id)' via pac CLI."
        }
    }
    else {
        throw "Power Platform CLI ('pac') is required for live solution import when not running in -DryRun mode."
    }
}

$workflowFiles = Get-ChildItem -Path (Join-Path $SolutionSourcePath 'Workflows') -Filter '*.json' -File | Sort-Object Name
$activeWorkflows = @()
foreach ($wfFile in $workflowFiles) {
    $wfJson = Get-Content -LiteralPath $wfFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$wfJson.displayName)) {
        $activeWorkflows += [string]$wfJson.displayName
    }
}

# Step 5: Emit power-platform-manifest.json and power-platform-run-manifest.json
$outputParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$handoffManifest = [ordered]@{
    schema                       = 'avd-ops-power-platform-manifest/v1'
    environment                  = $environment
    powerPlatformEnvironmentName = $environmentDisplayName
    dlpPolicyName                = $dlpPolicyDisplayName
    activeWorkflows              = $activeWorkflows
}
$handoffManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$runParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($RunManifestPath))
if (-not [string]::IsNullOrWhiteSpace($runParent) -and -not (Test-Path -LiteralPath $runParent)) {
    New-Item -ItemType Directory -Path $runParent -Force | Out-Null
}

$runManifest = [ordered]@{
    schema                   = 'avd-ops-power-platform-run-manifest/v1'
    stamp                    = $stamp
    environment              = $environment
    prefix                   = $prefix
    dryRun                   = [bool]$isDryRun
    preflightSkus            = $detectedSkus
    powerPlatformEnvironment = $environmentRecord
    dlpPolicy                = $dlpPolicyRecord
    enterprisePolicy         = $enterprisePolicyRecord
    solution                 = [ordered]@{
        uniqueName             = 'AvdDay2Automation'
        version                = '1.0.0.0'
        packedZipPath          = [System.IO.Path]::GetFullPath($PackedSolutionZipPath)
        deploymentSettingsPath = [System.IO.Path]::GetFullPath($settingsFilePath)
        created                = (-not $solutionExisted)
        environmentVariables   = [ordered]@{
            avd_UsersGroupId  = $avdUsersGroupId
            avd_HostPoolArmId = $hostPoolArmId
        }
    }
    activeWorkflows          = $activeWorkflows
}
$runManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RunManifestPath -Encoding UTF8

$validateScript = Join-Path $repoRoot 'scripts/validate.py'
$pythonExe = $null
foreach ($candidate in @('python3', 'python', 'py')) {
    $cmd = Get-Command -Name $candidate -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source -notlike '*WindowsApps*') {
        $pythonExe = $cmd.Source
        break
    }
}
if ($null -ne $pythonExe) {
    & $pythonExe $validateScript --manifest $OutputPath
    if ($LASTEXITCODE -ne 0) {
        throw "Contract validation failed for '$OutputPath'."
    }
}
