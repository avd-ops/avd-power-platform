# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$EntraManifestPath = './entra-manifest.json',
    [Parameter()][string]$AzureOutputsPath = './azure-outputs.json',
    [Parameter()][string]$OutputPath = './power-platform-manifest.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ShouldProcess('Power Platform', 'Deploy AVD environment, DLP policy and approval-gated workflows')) {
    & bash ./scripts/deploy-power-platform.sh $EntraManifestPath $AzureOutputsPath $OutputPath
}
