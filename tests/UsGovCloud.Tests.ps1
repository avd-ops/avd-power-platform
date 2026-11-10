# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    $script:TestDrive = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-shim-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestDrive -Force | Out-Null
    $script:beforeEachBlocks = [System.Collections.Generic.List[scriptblock]]::new()

    function script:BeforeAll([Parameter(Mandatory)][scriptblock]$Block) {
        . $Block
    }
    function script:BeforeEach([Parameter(Mandatory)][scriptblock]$Block) {
        $script:beforeEachBlocks.Add($Block)
    }
    function script:Describe([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Block) {
        $prevCount = $script:beforeEachBlocks.Count
        Write-Host "Describing $Name"
        try {
            . $Block
        }
        finally {
            while ($script:beforeEachBlocks.Count -gt $prevCount) {
                $script:beforeEachBlocks.RemoveAt($script:beforeEachBlocks.Count - 1)
            }
        }
    }
    function script:It([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Block) {
        foreach ($be in $script:beforeEachBlocks) {
            . $be
        }
        . $Block
        Write-Host "  [+] $Name"
    }
    function script:Should {
        param(
            [Parameter(ValueFromPipeline)]$ActualValue,
            [switch]$Not,
            [switch]$BeTrue,
            [switch]$BeFalse,
            [switch]$BeNullOrEmpty,
            $Be,
            $BeGreaterThan,
            $Contain,
            $Match,
            $Throw,
            [string]$Because = ''
        )
        begin {
            $items = [System.Collections.Generic.List[object]]::new()
        }
        process {
            $items.Add($ActualValue)
        }
        end {
            $val = if ($items.Count -eq 0) { $null } elseif ($items.Count -eq 1) { $items[0] } else { $items.ToArray() }
            if ($PSBoundParameters.ContainsKey('Throw')) {
                $threw = $false
                $msg = ''
                try {
                    & $val | Out-Null
                }
                catch {
                    $threw = $true
                    $msg = $_.Exception.Message
                }
                if ($Not) {
                    if ($threw) { throw "Expected scriptblock not to throw, but it threw: $msg" }
                }
                else {
                    if (-not $threw) { throw "Expected scriptblock to throw '$Throw', but it did not throw." }
                    if (-not [string]::IsNullOrWhiteSpace([string]$Throw) -and $msg -notlike $Throw) {
                        throw "Expected exception message matching '$Throw', got '$msg'."
                    }
                }
                return
            }
            if ($BeTrue) {
                $ok = ([bool]$val -eq $true)
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected True (Not=$Not), got '$val'. $Because" }
                return
            }
            if ($BeFalse) {
                $ok = ([bool]$val -eq $false)
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected False (Not=$Not), got '$val'. $Because" }
                return
            }
            if ($BeNullOrEmpty) {
                $isEmpty = ($null -eq $val) -or ($val -is [string] -and [string]::IsNullOrEmpty($val)) -or ($val -is [System.Collections.ICollection] -and $val.Count -eq 0)
                $ok = if ($Not) { -not $isEmpty } else { $isEmpty }
                if (-not $ok) { throw "Expected NullOrEmpty (Not=$Not), got '$val'. $Because" }
                return
            }
            if ($PSBoundParameters.ContainsKey('Be')) {
                if ($Be -is [array] -and $val -is [array]) {
                    $ok = (($val -join '|') -eq ($Be -join '|'))
                }
                else {
                    $ok = ($val -eq $Be)
                }
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected '$Be' (Not=$Not), got '$val'. $Because" }
                return
            }
            if ($PSBoundParameters.ContainsKey('BeGreaterThan')) {
                $ok = ($val -gt $BeGreaterThan)
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected > $BeGreaterThan, got '$val'. $Because" }
                return
            }
            if ($PSBoundParameters.ContainsKey('Contain')) {
                $ok = ($items -contains $Contain) -or ($val -contains $Contain)
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected collection to contain '$Contain'. $Because" }
                return
            }
            if ($PSBoundParameters.ContainsKey('Match')) {
                $ok = ([string]$val -match $Match)
                if ($Not) { $ok = -not $ok }
                if (-not $ok) { throw "Expected '$val' to match '$Match' (Not=$Not). $Because" }
                return
            }
        }
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:deployScript = Join-Path $script:repoRoot 'scripts/Deploy-AvdPowerPlatform.ps1'
    $script:removeScript = Join-Path $script:repoRoot 'scripts/Remove-AvdPowerPlatform.ps1'
    $script:c26Path = Join-Path $script:repoRoot 'contracts/cloud-environments.json'
    $script:assessC26Path = Join-Path (Split-Path -Parent $script:repoRoot) 'avd-assess/contracts/cloud-environments.json'
    $script:manifestSchema = Join-Path $script:repoRoot 'contracts/power-platform-manifest.schema.json'
}

Describe 'C26 Cloud Environment Contract and Zero-Commercial-URI AST Guard' {
    It 'has a valid contracts/cloud-environments.json (C26) matching avd-assess when present' {
        Test-Path -LiteralPath $script:c26Path | Should -BeTrue
        $c26 = Get-Content -LiteralPath $script:c26Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $c26.schema | Should -Be 'avd-cloud-environments/v1'
        $c26.clouds.commercial.powerPlatform.bapEndpoint | Should -Be 'https://api.bap.microsoft.com'
        $c26.clouds.commercial.powerPlatform.pacCloud | Should -Be 'Public'
        $c26.clouds.usgov.powerPlatform.pacCloud | Should -Be 'UsGovHigh'
        $c26.clouds.usgov.powerPlatform.dataverseSuffixes | Should -Contain 'crm9.dynamics.com'

        if (Test-Path -LiteralPath $script:assessC26Path) {
            $localHash = (Get-FileHash -LiteralPath $script:c26Path -Algorithm SHA256).Hash
            $upstreamHash = (Get-FileHash -LiteralPath $script:assessC26Path -Algorithm SHA256).Hash
            $localHash | Should -Be $upstreamHash
        }
    }

    It 'declares [ValidateSet("commercial", "usgov")] -Cloud on Deploy-AvdPowerPlatform.ps1 and Remove-AvdPowerPlatform.ps1' {
        foreach ($scriptPath in @($script:deployScript, $script:removeScript)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $cloudParam = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Cloud' }
            $cloudParam | Should -Not -BeNullOrEmpty -Because $scriptPath
            $validateSet = $cloudParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
            @($validateSet.PositionalArguments.Value) | Should -Be @('commercial', 'usgov')
        }
    }

    It 'contains zero hardcoded commercial Graph, BAP, or ARM URIs in scripts/*.ps1' {
        $forbiddenLiterals = @(
            'management.azure.com',
            'graph.microsoft.com',
            'login.microsoftonline.com',
            'api.bap.microsoft.com',
            '.windows.net'
        )
        $psFiles = Get-ChildItem -Path (Join-Path $script:repoRoot 'scripts') -Filter '*.ps1' -Recurse -File
        $psFiles.Count | Should -BeGreaterThan 0

        foreach ($file in $psFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $stringLiterals = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
            foreach ($strAst in $stringLiterals) {
                foreach ($forbidden in $forbiddenLiterals) {
                    $strAst.Value | Should -Not -Match ([regex]::Escape($forbidden)) -Because "$($file.Name) must resolve endpoints from C26"
                }
            }
        }
    }
}

Describe 'US Government (GCC High) Deployment, VNet Parity Fallback, and Live CLI Routing' {
    BeforeEach {
        $script:testDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
        $script:entraPath = Join-Path $script:testDir 'entra-manifest.json'
        $script:azurePath = Join-Path $script:testDir 'azure-outputs.json'
        $script:outManifest = Join-Path $script:testDir 'power-platform-manifest.json'
        $script:runManifest = Join-Path $script:testDir 'power-platform-run-manifest.json'
        $script:zipPath = Join-Path $script:testDir 'AvdDay2Automation.zip'

        @{
            schema             = 'avd-ops-entra-manifest/v1'
            cloud              = 'usgov'
            environment        = 'prod'
            prefix             = 'avd'
            groups             = @{
                avdUsersGroupId            = '00000000-0000-0000-0000-000000001111'
                avdAdminsGroupId           = '00000000-0000-0000-0000-000000002222'
                sessionHostsDynamicGroupId = '00000000-0000-0000-0000-000000003333'
                breakGlassExcludeGroupId   = '00000000-0000-0000-0000-000000004444'
            }
            conditionalAccess  = @()
            entraKerberosReady = $true
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:entraPath -Encoding UTF8

        @{
            schema                         = 'avd-ops-azure-outputs/v1'
            cloud                          = 'usgov'
            environment                    = 'prod'
            location                       = 'usgovvirginia'
            resourceGroupName              = 'rg-avd-cp-prod'
            hostPoolArmId                  = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avd-cp-prod/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-prod'
            powerPlatformDelegatedSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avd-net-prod/providers/Microsoft.Network/virtualNetworks/vnet-avd-prod/subnets/snet-powerplatform'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:azurePath -Encoding UTF8
    }

    It 'skips Bicep VNet enterprise policy in usgovvirginia and stamps skipped: unsupported-in-usgov in manifest' {
        & $script:deployScript `
            -Cloud 'usgov' `
            -EntraManifestPath $script:entraPath `
            -AzureOutputsPath $script:azurePath `
            -OutputPath $script:outManifest `
            -RunManifestPath $script:runManifest `
            -PackedSolutionZipPath $script:zipPath `
            -DryRun `
            -Confirm:$false

        $manifest = Get-Content -LiteralPath $script:outManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.cloud | Should -Be 'usgov'
        $manifest.enterprisePolicyStatus | Should -Be 'skipped: unsupported-in-usgov'
        $manifest.vnetInjectionStatus | Should -Be 'skipped: unsupported-in-usgov'
        $manifest.enterprisePolicy.status | Should -Be 'skipped'
        $manifest.enterprisePolicy.reason | Should -Be 'unsupported-in-usgov'

        $run = Get-Content -LiteralPath $script:runManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $run.cloud | Should -Be 'usgov'
        $run.enterprisePolicy.deployed | Should -BeFalse
        $run.enterprisePolicy.status | Should -Be 'skipped'
        $run.enterprisePolicy.reason | Should -Be 'unsupported-in-usgov'
        $run.powerPlatformEnvironment.bapEndpoint | Should -Be 'https://gov.api.bap.microsoft.us'
        $run.powerPlatformEnvironment.dataverseSuffix | Should -Be 'crm9.dynamics.com'
        $run.powerPlatformEnvironment.dataverseUrl | Should -Be 'https://avd-prod.crm9.dynamics.com'
        $run.powerPlatformEnvironment.flowEndpoint | Should -Be 'https://gov.flow.microsoft.us'
        $run.powerPlatformEnvironment.powerPlatformCloud | Should -Be 'High.powerplatform.us'
        $run.powerPlatformEnvironment.pacCloud | Should -Be 'UsGovHigh'
    }

    It 'routes live az rest calls to gov.api.bap.microsoft.us and graph.microsoft.us and authenticates pac with --cloud UsGovHigh' {
        $global:capturedAzCalls = [System.Collections.Generic.List[string]]::new()
        $global:capturedPacCalls = [System.Collections.Generic.List[string]]::new()

        function global:az {
            $joined = ($args -join ' ')
            $global:capturedAzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'cloud show*') {
                return 'AzureUSGovernment'
            }
            if ($joined -like '*subscribedSkus*') {
                return '{"value":[{"capabilityStatus":"Enabled","servicePlans":[{"servicePlanName":"FLOW_P2"}]}]}'
            }
            if ($joined -like '*scopes/admin/environments*') {
                return '{"value":[]}'
            }
            if ($joined -like '*POST*Microsoft.BusinessAppPlatform/environments*') {
                return '{"name":"env-usgov-001"}'
            }
            if ($joined -like '*scopes/admin/apiPolicies*' -and $joined -like '*GET*') {
                return '{"value":[]}'
            }
            if ($joined -like '*scopes/admin/apiPolicies*' -and $joined -like '*PUT*') {
                return '{"name":"dlp-usgov-001"}'
            }
            return '{}'
        }

        function global:pac {
            $joined = ($args -join ' ')
            $global:capturedPacCalls.Add($joined)
            $global:LASTEXITCODE = 0
            return 'OK'
        }

        try {
            & $script:deployScript `
                -Cloud 'usgov' `
                -EntraManifestPath $script:entraPath `
                -AzureOutputsPath $script:azurePath `
                -OutputPath $script:outManifest `
                -RunManifestPath $script:runManifest `
                -PackedSolutionZipPath $script:zipPath `
                -Confirm:$false

            ($global:capturedAzCalls | Where-Object { $_ -like '*https://graph.microsoft.us/v1.0/subscribedSkus*' }) | Should -Not -BeNullOrEmpty
            ($global:capturedAzCalls | Where-Object { $_ -like '*https://gov.api.bap.microsoft.us/providers/Microsoft.BusinessAppPlatform/environments*' }) | Should -Not -BeNullOrEmpty
            ($global:capturedAzCalls | Where-Object { $_ -like '*https://gov.api.bap.microsoft.us/providers/Microsoft.BusinessAppPlatform/scopes/admin/apiPolicies*' }) | Should -Not -BeNullOrEmpty
            ($global:capturedAzCalls | Where-Object { $_ -like '*deployment group create*' }) | Should -BeNullOrEmpty
            ($global:capturedAzCalls | Where-Object { $_ -like '*.microsoft.com*' -or $_ -like '*.azure.com*' }) | Should -BeNullOrEmpty

            ($global:capturedPacCalls | Where-Object { $_ -like 'auth create --cloud UsGovHigh --environment https://avd-prod.crm9.dynamics.com*' }) | Should -Not -BeNullOrEmpty
            ($global:capturedPacCalls | Where-Object { $_ -like 'solution import*--environment env-usgov-001*' }) | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path Function:\global:az -ErrorAction SilentlyContinue
            Remove-Item -Path Function:\global:pac -ErrorAction SilentlyContinue
            Remove-Variable -Name capturedAzCalls -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name capturedPacCalls -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed when -Cloud conflicts with entra-manifest.json or azure-outputs.json or active Az context' {
        {
            & $script:deployScript `
                -Cloud 'commercial' `
                -EntraManifestPath $script:entraPath `
                -AzureOutputsPath $script:azurePath `
                -OutputPath $script:outManifest `
                -RunManifestPath $script:runManifest `
                -PackedSolutionZipPath $script:zipPath `
                -DryRun `
                -Confirm:$false
        } | Should -Throw '*Cloud mismatch*'

        function global:Get-AzContext {
            return [pscustomobject]@{
                Environment = [pscustomobject]@{
                    Name = 'AzureCloud'
                }
            }
        }
        try {
            {
                & $script:deployScript `
                    -Cloud 'usgov' `
                    -EntraManifestPath $script:entraPath `
                    -AzureOutputsPath $script:azurePath `
                    -OutputPath $script:outManifest `
                    -RunManifestPath $script:runManifest `
                    -PackedSolutionZipPath $script:zipPath `
                    -DryRun `
                    -Confirm:$false
            } | Should -Throw '*Cloud mismatch*active Az PowerShell environment*'
        }
        finally {
            Remove-Item -Path Function:\global:Get-AzContext -ErrorAction SilentlyContinue
        }
    }
}

