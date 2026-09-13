function Get-CrossTenantEntraIdGroups {
    <#
    .SYNOPSIS
        Lists all Entra ID groups in a target (customer) tenant using the
        cross-tenant Managed Identity federated credential flow.

    .DESCRIPTION
        Acquires a Microsoft Graph access token for the TARGET tenant via
        Get-CrossTenantAccessToken (Managed Identity federated credential on
        a multi-tenant App Registration) and then enumerates all groups in
        that tenant through the Microsoft Graph 'groups' endpoint, following
        '@odata.nextLink' pagination until every page has been retrieved.

        The App Registration's service principal must have been granted the
        'Group.Read.All' (or broader) application permission, with admin
        consent, in the target tenant.

    .PARAMETER TenantId
        Tenant ID (GUID) of the TARGET tenant whose groups should be listed.

    .PARAMETER ClientId
        Client (Application) ID of the multi-tenant App Registration that
        trusts the Managed Identity via a Federated Identity Credential.

    .EXAMPLE
        Get-CrossTenantEntraIdGroups -TenantId '11111111-1111-1111-1111-111111111111' -ClientId '22222222-2222-2222-2222-222222222222'

        Returns all Entra ID groups from the target tenant.

    .OUTPUTS
        System.Object[]. The collected Microsoft Graph group objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]
        $ClientId
    )

    Write-Host "Get-CrossTenantEntraIdGroups: acquiring access token for tenant '$TenantId'."
    $accessToken = Get-CrossTenantAccessToken -TenantId $TenantId -ClientId $ClientId -Scope 'https://graph.microsoft.com/.default'

    $groups = [System.Collections.Generic.List[object]]::new()
    $uri = 'https://graph.microsoft.com/v1.0/groups'
    $page = 0

    try {
        while ($uri) {
            $page++
            Write-Host "Get-CrossTenantEntraIdGroups: fetching page $page of groups from tenant '$TenantId'."
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $accessToken" } -ErrorAction Stop
            if ($response.value) {
                $groups.AddRange(@($response.value))
            }
            $uri = $response.'@odata.nextLink'
        }
    } catch {
        throw "Failed to list groups in tenant '$TenantId': $_"
    }

    Write-Host "Get-CrossTenantEntraIdGroups: retrieved $($groups.Count) group(s) from tenant '$TenantId' across $page page(s)."

    return $groups.ToArray()
}
