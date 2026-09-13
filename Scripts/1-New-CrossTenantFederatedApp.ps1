#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
    Sets up a multi-tenant App Registration that trusts a Managed Identity
    via a Federated Identity Credential (FIC) - "Managed Identity as FIC".

.DESCRIPTION
    This script runs ONCE in the "home tenant" (the tenant that hosts your
    Azure Function and the User-Assigned Managed Identity).

    It performs:
      1. Creates (or reuses) an App Registration with
         signInAudience = AzureADMultipleOrgs (multi-tenant).
      2. Sets the required Microsoft Graph application permissions
         (e.g. Group.Read.All) on the App Registration.
      3. Creates a Federated Identity Credential that trusts NOT a
         client secret/certificate, but a User-Assigned Managed Identity
         in the same tenant.
      4. Prints the admin consent URL to send to the target tenant
         (customer tenant) so a service principal for your app is created
         there and the permissions are granted.

.PARAMETER AppDisplayName
    Display name of the App Registration to create or reuse. Default:
    'crossten-func-graph-connector'.

.PARAMETER HomeTenantId
    Tenant ID of the home tenant, where the App Registration and the
    User-Assigned Managed Identity both live.

.PARAMETER UserAssignedIdentityObjectId
    Object (Principal) ID of the User-Assigned Managed Identity. Used as
    the 'Subject' of the Federated Identity Credential.

.PARAMETER UserAssignedIdentityName
    Name of the User-Assigned Managed Identity, used only for the
    Federated Identity Credential's description text.

.PARAMETER UserAssignedIdentityResourceGroup
    Resource Group of the User-Assigned Managed Identity, used only for
    the Federated Identity Credential's description text.

.PARAMETER GraphApplicationPermissions
    Microsoft Graph application permissions (app roles, not delegated
    permissions) that the app is granted on the App Registration. Default:
    'Group.Read.All'.

.EXAMPLE
    .\1-New-CrossTenantFederatedApp.ps1 -HomeTenantId '00000000-0000-0000-0000-000000000000' `
        -UserAssignedIdentityObjectId '11111111-1111-1111-1111-111111111111' `
        -UserAssignedIdentityName 'uami-crosstenant' -UserAssignedIdentityResourceGroup 'rg-crosstenant'

    Creates the App Registration with the default display name and default
    Graph permissions, and prints the admin consent URL for the target
    tenant.

.OUTPUTS
    None. The script writes status messages via Write-Host and does not
    emit objects to the pipeline.

.NOTES
    Author:     Constantin Hager (the-itguy.de)
    Important:  The App Registration AND the Managed Identity must live in
                the same tenant. Only the REQUEST (the token the app later
                fetches) goes to the foreign target tenant.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $AppDisplayName = 'CHCrossTenantApp',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]
    $HomeTenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]
    $UserAssignedIdentityObjectId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserAssignedIdentityName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserAssignedIdentityResourceGroup,

    # Microsoft Graph application permissions the app will use in the
    # target tenant later (app roles, not delegated permissions!)
    [ValidateNotNullOrEmpty()]
    [string[]] $GraphApplicationPermissions = @('Group.Read.All')
)

Connect-MgGraph -TenantId $HomeTenantId -Scopes @(
    'Application.ReadWrite.All'
)

#region 1) Create or reuse the App Registration (multi-tenant)
$existingApp = Get-MgApplication -Filter "displayName eq '$AppDisplayName'"

# The admin-consent flow (region 4) redirects back to a Reply URL after consent -
# without at least one registered, it fails with AADSTS500113. This app never
# actually receives an interactive sign-in (only client-credentials/JWT-bearer is
# used at runtime), so a plain, always-reachable HTTPS placeholder is sufficient.
# NOTE: 'https://login.microsoftonline.com/common/oauth2/nativeclient' looks like
# the obvious choice, but it is only special-cased under the 'Public client/native'
# platform - registered as a Web Reply URL (as required here) it causes Entra ID's
# post-consent redirect to fail with "This is not the right page".
$placeholderRedirectUri = 'https://portal.azure.com'

if (-not $existingApp) {
    Write-Host "Creating new multi-tenant App Registration '$AppDisplayName'..." -ForegroundColor Cyan

    $Parameters = @{
        DisplayName    = $AppDisplayName
        SignInAudience = 'AzureADMultipleOrgs'
        Web            = @{ RedirectUris = @($placeholderRedirectUri) }
    }
    $app = New-MgApplication @Parameters
} else {
    Write-Host "App Registration '$AppDisplayName' already exists, reusing it." -ForegroundColor Yellow

    # Get-MgApplication -Filter returns a reduced property set - 'Web' is often $null
    # there even when it IS set, so re-fetch by ID with an explicit -Property to get
    # the authoritative current value before deciding whether an update is needed.
    $app = Get-MgApplication -ApplicationId $existingApp.Id -Property 'id,appId,web'
    $currentRedirectUris = @($app.Web.RedirectUris)
    Write-Host "  Current Reply URL(s): $(if ($currentRedirectUris) { $currentRedirectUris -join ', ' } else { '<none>' })"

    if ($currentRedirectUris -notcontains $placeholderRedirectUri) {
        Write-Host 'Reply URL missing or outdated (would cause AADSTS500113 / "wrong page" on admin consent), updating...' -ForegroundColor Cyan
        Update-MgApplication -ApplicationId $app.Id -Web @{ RedirectUris = @($placeholderRedirectUri) } -ErrorAction Stop
        $app = Get-MgApplication -ApplicationId $app.Id -Property 'id,appId,web'
        Write-Host "  Reply URL(s) after update: $($app.Web.RedirectUris -join ', ')" -ForegroundColor Green
    }
}

Write-Host "  AppId (Client ID): $($app.AppId)"
Write-Host "  Object ID:         $($app.Id)"
#endregion

#region 2) Set the Microsoft Graph application permissions
# Well-known App ID of Microsoft Graph
$graphResourceAppId = '00000003-0000-0000-c000-000000000000'
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphResourceAppId'"

$resourceAccess = foreach ($permissionName in $GraphApplicationPermissions) {
    $appRole = $graphSp.AppRoles |
    Where-Object { $_.Value -eq $permissionName -and $_.AllowedMemberTypes -contains 'Application' }

    if (-not $appRole) {
        throw "App role '$permissionName' was not found on Microsoft Graph."
    }

    @{
        Id   = $appRole.Id
        Type = 'Role'   # 'Role' = application permission (not 'Scope'!)
    }
}

Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess @(
    @{
        ResourceAppId  = $graphResourceAppId
        ResourceAccess = @($resourceAccess)
    }
) -ErrorAction Stop

Write-Host "Application permissions set: $($GraphApplicationPermissions -join ', ')" -ForegroundColor Cyan
#endregion

#region 3) Create the Federated Identity Credential pointing to the Managed Identity
$ficParams = @{
    Name        = 'trust-function-managed-identity'
    Issuer      = "https://login.microsoftonline.com/$HomeTenantId/v2.0"
    Subject     = $UserAssignedIdentityObjectId   # Object (Principal) ID of the UAMI!
    Audiences   = @('api://AzureADTokenExchange')
    Description = "Trusts the Managed Identity '$UserAssignedIdentityName' (RG: $UserAssignedIdentityResourceGroup) as issuer."
}

$existingFic = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id |
Where-Object { $_.Name -eq $ficParams.Name }

if (-not $existingFic) {
    New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $ficParams | Out-Null
    Write-Host 'Federated Identity Credential created.' -ForegroundColor Green
} else {
    Write-Host 'Federated Identity Credential already exists, skipping.' -ForegroundColor Yellow
}
#endregion

#region 4) Print the admin consent URL for the target tenant
$consentUrl = "https://login.microsoftonline.com/organizations/adminconsent?client_id=$($app.AppId)&redirect_uri=$([uri]::EscapeDataString($placeholderRedirectUri))"

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host "Note this AppId (Client ID) for later use: $($app.AppId)"
Write-Host ''
Write-Host 'Send this link to a Global Admin / Privileged Role Admin' -ForegroundColor Cyan
Write-Host 'in the TARGET TENANT (the customer tenant whose data you want to read):'
Write-Host $consentUrl
Write-Host ''
Write-Host 'After consent, an Enterprise Application / Service Principal for your'
Write-Host 'app exists there - that is exactly what is needed for the token exchange.'
#endregion
