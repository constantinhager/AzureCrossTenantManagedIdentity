#Requires -Modules Az.Accounts, Az.Resources, Az.Storage, Az.Functions, Az.ManagedServiceIdentity
<#
.SYNOPSIS
    Provisions the complete infrastructure required for the "Managed
    Identity as Federated Identity Credential" scenario in the home tenant:
    Resource Group, Storage Account, User-Assigned Managed Identity, and
    the Azure Function App (PowerShell runtime, Flex Consumption plan),
    including assigning the UAMI to it.

.DESCRIPTION
    This script is step 0 - BEFORE creating the App Registration
    (script 1). Reason: the Federated Identity Credential in script 1
    needs the Object (Principal) ID of the Managed Identity, which is only
    created here.

    The script is idempotent: every resource is checked with Get-* first
    and only created if it does not already exist. For an already existing
    Function App, the script only ensures that the User-Assigned Managed
    Identity is assigned.

    Prerequisite: An active Az sign-in in the home tenant (Connect-AzAccount)
    with sufficient rights to create/modify Resource Groups, Storage
    Accounts, Managed Identities, and Function Apps, and to register the
    Microsoft.Storage, Microsoft.Web, and Microsoft.ManagedIdentity resource
    providers (the script registers them automatically if needed).

.PARAMETER ResourceGroupName
    Name of the Resource Group in which all resources are created. Created
    if it does not already exist.

.PARAMETER Location
    Azure region for all newly created resources, e.g. "westeurope".

.PARAMETER StorageAccountName
    Name of the Storage Account required by the Function App. Must be
    globally unique and comply with Azure's Storage Account naming rules
    (3-24 characters, lowercase letters and digits only).

.PARAMETER FunctionAppName
    Name of the Azure Function App created with the PowerShell runtime.
    Must be globally unique.

.PARAMETER UserAssignedIdentityName
    Name of the User-Assigned Managed Identity that is created and
    assigned to the Function App. Its Object (Principal) ID is then needed
    as the subject for the Federated Identity Credential in script 1.

.PARAMETER PowerShellVersion
    PowerShell runtime version of the Function App. Default: '7.6'. The
    Flex Consumption plan is always Functions v4 and does not accept a
    separate Functions version.

.EXAMPLE
    .\0-New-CrossTenantAzureResources.ps1 -ResourceGroupName 'rg-crosstenant' -Location 'westeurope' `
        -StorageAccountName 'stcrosstenant001' -FunctionAppName 'func-crosstenant-demo' `
        -UserAssignedIdentityName 'uami-crosstenant'

    Creates the Resource Group, Storage Account, Managed Identity, and
    Function App (PowerShell 7.6, Flex Consumption plan) using the default
    values.

.EXAMPLE
    .\0-New-CrossTenantAzureResources.ps1 -ResourceGroupName 'rg-crosstenant' -Location 'westeurope' `
        -StorageAccountName 'stcrosstenant001' -FunctionAppName 'func-crosstenant-demo' `
        -UserAssignedIdentityName 'uami-crosstenant' -PowerShellVersion '7.2' -Verbose

    Same as above, but explicitly with PowerShell runtime 7.2 and verbose
    output.

.OUTPUTS
    None. The script writes status messages via Write-Host and does not
    emit objects to the pipeline.

.NOTES
    Author: Constantin Hager (the-itguy.de)
    The Function App is created in the Flex Consumption plan, which only
    runs on Linux and is only available in a subset of Azure regions - pick
    a -Location that supports it (see 'az functionapp
    list-flexconsumption-locations').
    Next step after this script: 1-New-CrossTenantFederatedApp.ps1
    (requires the Object/Principal ID of the Managed Identity printed here).
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $ResourceGroupName = 'crosstenant-rg',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $Location = 'germanywestcentral',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]
    $StorageAccountName = 'chcrosstenantstorage001',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $FunctionAppName = 'chcrosstenantfuncapp001',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserAssignedIdentityName = 'chcrosstenantuami001',

    [Parameter()]
    [string]
    $PowerShellVersion = '7.4'
)

#region 0) Required resource providers
$requiredProviderNamespaces = 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.ManagedIdentity'
foreach ($providerNamespace in $requiredProviderNamespaces) {
    $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
    if ($provider.RegistrationState -ne 'Registered') {
        Write-Host "Registering resource provider '$providerNamespace'..." -ForegroundColor Cyan
        Register-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        $registrationTimeout = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
        } while ($provider.RegistrationState -ne 'Registered' -and (Get-Date) -lt $registrationTimeout)

        if ($provider.RegistrationState -ne 'Registered') {
            throw "Resource provider '$providerNamespace' did not reach state 'Registered' within 5 minutes."
        }
    }
}
#endregion

#region 1) Resource Group
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating Resource Group '$ResourceGroupName'..." -ForegroundColor Cyan
    $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop -WarningAction SilentlyContinue
}
if (-not $rg.ResourceId) { throw "Failed to create or find Resource Group '$ResourceGroupName'." }
#endregion

#region 2) User-Assigned Managed Identity
$Parameters = @{
    ResourceGroupName = $ResourceGroupName
    Name              = $UserAssignedIdentityName
    ErrorAction       = 'SilentlyContinue'
}
$uami = Get-AzUserAssignedIdentity @Parameters
if (-not $uami) {
    Write-Host "Creating User-Assigned Managed Identity '$UserAssignedIdentityName'..." -ForegroundColor Cyan
    $Parameters = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $UserAssignedIdentityName
        Location          = $Location
        ErrorAction       = 'Stop'
        WarningAction     = 'SilentlyContinue'
    }
    $uami = New-AzUserAssignedIdentity @Parameters
}
if (-not $uami.Id) { throw "Failed to create or find User-Assigned Managed Identity '$UserAssignedIdentityName'." }

Write-Host "  Object (Principal) ID: $($uami.PrincipalId)   <- needed as 'Subject' in script 1"
Write-Host "  Client ID:             $($uami.ClientId)       <- needed in the Function App settings"
#endregion

#region 3) Storage Account (required for Function Apps)
$Parameters = @{
    ResourceGroupName = $ResourceGroupName
    Name              = $StorageAccountName
    ErrorAction       = 'SilentlyContinue'
}
$storage = Get-AzStorageAccount @Parameters
if (-not $storage) {
    Write-Host "Creating Storage Account '$StorageAccountName'..." -ForegroundColor Cyan
    $Parameters = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $StorageAccountName
        Location          = $Location
        SkuName           = 'Standard_LRS'
        Kind              = 'StorageV2'
        ErrorAction       = 'Stop'
        WarningAction     = 'SilentlyContinue'
    }
    $storage = New-AzStorageAccount @Parameters
}
if (-not $storage.Id) { throw "Failed to create or find Storage Account '$StorageAccountName'." }
#endregion

#region 4) Function App with PowerShell runtime + assigned UAMI (Flex Consumption plan)
$Parameters = @{
    ResourceGroupName = $ResourceGroupName
    Name              = $FunctionAppName
    ErrorAction       = 'SilentlyContinue'
}
$functionApp = Get-AzFunctionApp @Parameters
if (-not $functionApp) {
    Write-Host "Creating Function App '$FunctionAppName' (PowerShell $PowerShellVersion, Flex Consumption plan)..." -ForegroundColor Cyan

    # Flex Consumption apps run on Linux only and have no -OSType/-FunctionsVersion (always Functions v4).
    $Parameters = @{
        ResourceGroupName       = $ResourceGroupName
        Name                    = $FunctionAppName
        StorageAccountName      = $StorageAccountName
        FlexConsumptionLocation = $Location
        Runtime                 = 'PowerShell'
        RuntimeVersion          = $PowerShellVersion
        UserAssignedIdentity    = @($uami.Id)
        MaximumInstanceCount    = 100
        InstanceMemoryMB        = 2048
        ErrorAction             = 'Stop'
        WarningAction           = 'SilentlyContinue'
    }

    # Az.Functions hardcodes en-US date strings internally (e.g. runtime EOL checks); a non-US
    # thread culture makes [DateTime]::Parse() throw, so switch to en-US just for this call.
    $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    try {
        $functionApp = New-AzFunctionApp @Parameters
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    }
} else {
    Write-Host 'Function App already exists, assigning the Managed Identity (if not already done)...' -ForegroundColor Yellow
    $Parameters = @{
        ResourceGroupName    = $ResourceGroupName
        Name                 = $FunctionAppName
        UserAssignedIdentity = @($uami.Id)
        Force                = $true
        ErrorAction          = 'Stop'
        WarningAction        = 'SilentlyContinue'
    }
    Update-AzFunctionApp @Parameters
}
if (-not $functionApp.Id) { throw "Failed to create or find Function App '$FunctionAppName'." }
#endregion

#region 5) Prepare App Settings for the token exchange
# CROSSTENANT_APP_CLIENT_ID only comes from script 1 (AppId of the App Registration)
# and is deliberately left out here - after script 1, just add it:
#
#   Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName -Name $FunctionAppName `
#       -AppSetting @{ CROSSTENANT_APP_CLIENT_ID = '<AppId from script 1>' }

Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -AppSetting @{
    MANAGED_IDENTITY_CLIENT_ID = $uami.ClientId
} -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
#endregion

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host "Resource Group:            $ResourceGroupName"
Write-Host "Function App:              $FunctionAppName"
Write-Host "Managed Identity (Name):   $UserAssignedIdentityName"
Write-Host "Managed Identity (Object): $($uami.PrincipalId)"
Write-Host "Managed Identity (Client): $($uami.ClientId)"
Write-Host ''
Write-Host 'Continue with script 1 (App Registration + Federated Credential):'
$homeTenantId = (Get-AzContext).Tenant.Id
Write-Host @"
`$Parameters = @{
    UserAssignedIdentityObjectId      = '$($uami.PrincipalId)'
    UserAssignedIdentityName          = '$UserAssignedIdentityName'
    UserAssignedIdentityResourceGroup = '$ResourceGroupName'
    HomeTenantId                      = '$homeTenantId'
}
.\1-New-CrossTenantFederatedApp.ps1 @Parameters
"@
