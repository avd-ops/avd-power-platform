// Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
targetScope = 'resourceGroup'

@description('Name of the Power Platform VNet enterprise policy.')
param enterprisePolicyName string = 'ep-avd-powerplatform'

@description('Azure region for the enterprise policy.')
param location string = resourceGroup().location

@description('Resource ID of the delegated subnet in avd-azure.')
param delegatedSubnetId string

resource vnetPolicy 'Microsoft.PowerPlatform/enterprisePolicies@2020-10-30-preview' = {
  name: enterprisePolicyName
  location: location
  kind: 'NetworkInjection'
  properties: {
    networkInjection: {
      virtualNetworks: [
        {
          id: substring(delegatedSubnetId, 0, indexOf(delegatedSubnetId, '/subnets/'))
          subnet: {
            name: last(split(delegatedSubnetId, '/'))
          }
        }
      ]
    }
  }
}

output enterprisePolicyId string = vnetPolicy.id
