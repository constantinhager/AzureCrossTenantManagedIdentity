#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns, Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Creates the Entra ID App Registration used by the GitHub Actions
    deployment workflow to sign in to Azure via OIDC (federated
    credential) and assigns it the Azure RBAC role needed to deploy the
    Function App.

.DESCRIPTION
    This script runs ONCE in the home tenant (the tenant that hosts the
    Function App). It is independent of the cross-tenant Managed Identity
    App Registration created by 1-New-CrossTenantFederatedApp.ps1 - that
    one is the RUNTIME identity used by the Function App to reach the
    target tenant, this one is the DEPLOYMENT identity used by
    'deploy-function.yml' to sign in to Azure from GitHub Actions and
    publish the Function App.

    It performs:
      1. Creates (or reuses) a single-tenant App Registration for the
         GitHub Actions workflow.
      2. Creates (or reuses) the corresponding Service Principal.
      3. Creates a Federated Identity Credential that trusts GitHub's OIDC
         issuer for the given repository and branch - no client secret is
         stored anywhere.
      4. Assigns an Azure RBAC role (default: 'Website Contributor') to
         the Service Principal, scoped to the Function App's Resource
         Group, so the workflow can publish to it.
      5. Prints the values to store as GitHub secrets
         (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID).

    The federated credential's subject is bound to a branch
    ('repo:<org>@<ownerId>/<repo>@<repoId>:ref:refs/heads/<branch>' for
    repositories using GitHub's immutable OIDC subject format, or the
    classic 'repo:<org>/<repo>:ref:refs/heads/<branch>' otherwise),
    matching the 'main' branch trigger used by 'deploy-function.yml'. This
    intentionally does NOT use a GitHub Environment.

.PARAMETER AppDisplayName
    Display name of the App Registration to create or reuse. Default:
    'CHGitHubActionsDeployApp'.

.PARAMETER HomeTenantId
    Tenant ID of the home tenant, where both the Function App and this
    deployment App Registration live.

.PARAMETER SubscriptionId
    Subscription ID that contains the Function App's Resource Group. Used
    both for the Az sign-in context and as part of the role assignment
    scope.

.PARAMETER ResourceGroupName
    Resource Group of the Function App. The Azure RBAC role is scoped to
    this Resource Group.

.PARAMETER GitHubOrganization
    GitHub organization or user that owns the repository, e.g.
    'constantinhager'.

.PARAMETER GitHubRepository
    Name of the GitHub repository, e.g. 'AzureCrossTenantManagedIdentity'.

.PARAMETER GitHubBranch
    Name of the branch the federated credential trusts. Default: 'main'.

.PARAMETER GitHubOwnerId
    Numeric ID of the GitHub organization/user (owner_id claim). For
    repositories created after 2026-07-15, or that opted in to GitHub's
    immutable OIDC subject claims, the 'sub' claim GitHub presents is
    'repo:<org>@<ownerId>/<repo>@<repoId>:ref:refs/heads/<branch>' instead
    of the classic 'repo:<org>/<repo>:ref:...' format. If not supplied,
    the script resolves it automatically via the public GitHub REST API.

.PARAMETER GitHubRepositoryId
    Numeric ID of the GitHub repository (repository_id claim). See
    -GitHubOwnerId. If not supplied, the script resolves it automatically
    via the public GitHub REST API.

.PARAMETER RoleDefinitionName
    Azure RBAC role assigned to the Service Principal on
    -ResourceGroupName. Default: 'Website Contributor'.

.EXAMPLE
    .\3-New-GitHubActionsFederatedApp.ps1 -HomeTenantId '00000000-0000-0000-0000-000000000000' `
        -SubscriptionId '33333333-3333-3333-3333-333333333333' -ResourceGroupName 'crosstenant-rg' `
        -GitHubOrganization 'constantinhager' -GitHubRepository 'AzureCrossTenantManagedIdentity'

    Creates the App Registration, Service Principal, and Federated
    Identity Credential for the 'main' branch, and assigns
    'Website Contributor' on the Resource Group.

.OUTPUTS
    None. The script writes status messages via Write-Host and does not
    emit objects to the pipeline.

.NOTES
    Author:     Constantin Hager (the-itguy.de)
    Prerequisite: an active Microsoft Graph sign-in
    (Connect-MgGraph -Scopes 'Application.ReadWrite.All') is established by
    the script itself, and an active Az sign-in
    (Connect-AzAccount -Tenant $HomeTenantId -Subscription $SubscriptionId)
    with rights to assign roles on -ResourceGroupName.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $AppDisplayName = 'CHGitHubActionsDeployApp',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]
    $HomeTenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]
    $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubOrganization,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepository,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubBranch = 'main',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubOwnerId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepositoryId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $RoleDefinitionName = 'Website Contributor'
)

Connect-MgGraph -TenantId $HomeTenantId -Scopes @(
    'Application.ReadWrite.All'
)

#region 1) Create or reuse the App Registration (single-tenant)
$existingApp = Get-MgApplication -Filter "displayName eq '$AppDisplayName'"

if (-not $existingApp) {
    Write-Host "Creating new App Registration '$AppDisplayName'..." -ForegroundColor Cyan

    $Parameters = @{
        DisplayName    = $AppDisplayName
        SignInAudience = 'AzureADMyOrg'
    }
    $app = New-MgApplication @Parameters
} else {
    Write-Host "App Registration '$AppDisplayName' already exists, reusing it." -ForegroundColor Yellow
    $app = $existingApp
}

Write-Host "  AppId (Client ID): $($app.AppId)"
Write-Host "  Object ID:         $($app.Id)"
#endregion

#region 2) Create or reuse the Service Principal for the App Registration
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
if (-not $sp) {
    Write-Host 'Creating Service Principal for the App Registration...' -ForegroundColor Cyan
    $sp = New-MgServicePrincipal -AppId $app.AppId
} else {
    Write-Host 'Service Principal already exists, reusing it.' -ForegroundColor Yellow
}

Write-Host "  Service Principal Object ID: $($sp.Id)"
#endregion

#region 3) Create the Federated Identity Credential trusting GitHub's OIDC issuer
# GitHub uses an immutable 'repo:<org>@<ownerId>/<repo>@<repoId>:ref:...' subject
# for repositories created/renamed/transferred after 2026-07-15 (or opted in earlier) -
# resolve the numeric IDs via the public GitHub REST API unless explicitly supplied.
if (-not $GitHubOwnerId -or -not $GitHubRepositoryId) {
    Write-Host "Resolving GitHub owner/repository IDs for '$GitHubOrganization/$GitHubRepository'..." -ForegroundColor Cyan
    $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOrganization/$GitHubRepository" -Headers @{ 'User-Agent' = 'AzureCrossTenantManagedIdentity' } -ErrorAction Stop
    if (-not $GitHubOwnerId) { $GitHubOwnerId = $repoInfo.owner.id }
    if (-not $GitHubRepositoryId) { $GitHubRepositoryId = $repoInfo.id }
}
Write-Host "  Owner ID:      $GitHubOwnerId"
Write-Host "  Repository ID: $GitHubRepositoryId"

$ficParams = @{
    Name        = "github-actions-$GitHubBranch"
    Issuer      = 'https://token.actions.githubusercontent.com'
    Subject     = "repo:$($GitHubOrganization)@$($GitHubOwnerId)/$($GitHubRepository)@$($GitHubRepositoryId):ref:refs/heads/$($GitHubBranch)"
    Audiences   = @('api://AzureADTokenExchange')
    Description = "Trusts GitHub Actions in '$GitHubOrganization/$GitHubRepository' on branch '$GitHubBranch' (immutable subject)."
}

$existingFic = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id |
Where-Object { $_.Name -eq $ficParams.Name }

if (-not $existingFic) {
    New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $ficParams | Out-Null
    Write-Host 'Federated Identity Credential created.' -ForegroundColor Green
} elseif ($existingFic.Subject -ne $ficParams.Subject) {
    Update-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -FederatedIdentityCredentialId $existingFic.Id -BodyParameter $ficParams | Out-Null
    Write-Host "Federated Identity Credential subject updated (was '$($existingFic.Subject)', now '$($ficParams.Subject)')." -ForegroundColor Green
} else {
    Write-Host 'Federated Identity Credential already exists and matches, skipping.' -ForegroundColor Yellow
}
#endregion

#region 4) Assign the Azure RBAC role scoped to the Function App's Resource Group
$null = Connect-AzAccount -Tenant $HomeTenantId -Subscription $SubscriptionId

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
$roleScope = $rg.ResourceId

$existingAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $RoleDefinitionName -Scope $roleScope -ErrorAction SilentlyContinue
if (-not $existingAssignment) {
    Write-Host "Assigning role '$RoleDefinitionName' to the Service Principal on '$ResourceGroupName'..." -ForegroundColor Cyan
    $null = New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $RoleDefinitionName -Scope $roleScope
    Write-Host 'Role assignment created.' -ForegroundColor Green
} else {
    Write-Host "Role '$RoleDefinitionName' is already assigned on '$ResourceGroupName', skipping." -ForegroundColor Yellow
}
#endregion

#region 5) Print the GitHub Actions secrets
Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host 'Store these as GitHub Actions secrets (Settings > Secrets and variables > Actions):'
Write-Host "  AZURE_CLIENT_ID:       $($app.AppId)"
Write-Host "  AZURE_TENANT_ID:       $HomeTenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID: $SubscriptionId"
Write-Host ''
Write-Host "Federated credential subject: $($ficParams.Subject)"
Write-Host 'This only works for workflow runs triggered on that exact branch (push or workflow_dispatch against it).'
#endregion
