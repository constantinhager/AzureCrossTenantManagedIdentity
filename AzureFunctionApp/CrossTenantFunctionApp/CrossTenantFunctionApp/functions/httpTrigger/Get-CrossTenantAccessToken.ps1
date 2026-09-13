function Get-CrossTenantAccessToken {
    <#
    .SYNOPSIS
        Gets an access token for a foreign (customer) Entra ID tenant using
        the Function App's User-Assigned Managed Identity as a Federated
        Identity Credential on a multi-tenant App Registration.

    .DESCRIPTION
        Implements the "Managed Identity as Federated Identity Credential"
        cross-tenant flow:

        1. Requests a token for the Managed Identity itself (audience
           'api://AzureADTokenExchange') from the Function App's identity
           endpoint. This token is used as a client assertion and never
           leaves the home tenant.
        2. Exchanges that assertion for an access token in the TARGET
           (customer) tenant, using the multi-tenant App Registration's
           client ID, via the OAuth2 client-credentials/JWT-bearer flow.

        The Managed Identity is selected via the MANAGED_IDENTITY_CLIENT_ID
        environment variable, which must be the client ID of the
        User-Assigned Managed Identity configured as the Federated Identity
        Credential's subject on the App Registration.

    .PARAMETER TenantId
        Tenant ID (GUID) of the TARGET tenant to request the access token
        from, i.e. the customer tenant where the App Registration's service
        principal was granted admin consent.

    .PARAMETER ClientId
        Client (Application) ID of the multi-tenant App Registration that
        trusts the Managed Identity via a Federated Identity Credential.

    .PARAMETER Scope
        OAuth2 scope to request the access token for. Defaults to
        'https://graph.microsoft.com/.default'.

    .EXAMPLE
        Get-CrossTenantAccessToken -TenantId '11111111-1111-1111-1111-111111111111' -ClientId '22222222-2222-2222-2222-222222222222'

        Returns a Microsoft Graph access token for the target tenant.

    .OUTPUTS
        System.String. The access token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]
        $ClientId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Scope = 'https://graph.microsoft.com/.default'
    )

    $managedIdentityClientId = $env:MANAGED_IDENTITY_CLIENT_ID
    if ([string]::IsNullOrWhiteSpace($managedIdentityClientId)) {
        throw "Environment variable 'MANAGED_IDENTITY_CLIENT_ID' is not set."
    }

    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeaderValue = $env:IDENTITY_HEADER
    if ([string]::IsNullOrWhiteSpace($identityEndpoint) -or [string]::IsNullOrWhiteSpace($identityHeaderValue)) {
        throw "Managed Identity endpoint is not available ('IDENTITY_ENDPOINT'/'IDENTITY_HEADER' missing) - is a Managed Identity attached to this Function App?"
    }

    Write-Host "Get-CrossTenantAccessToken: requesting Managed Identity assertion token (clientId '$managedIdentityClientId') for token exchange."

    # Step 1: get a Managed Identity token for the token-exchange audience; this is used only as the client assertion below and never leaves the home tenant.
    $assertionUri = '{0}?resource={1}&api-version=2019-08-01&client_id={2}' -f $identityEndpoint, [uri]::EscapeDataString('api://AzureADTokenExchange'), [uri]::EscapeDataString($managedIdentityClientId)

    try {
        $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $identityHeaderValue } -ErrorAction Stop
    } catch {
        throw "Failed to acquire a Managed Identity assertion token: $_"
    }

    $clientAssertion = $assertionResponse.access_token
    if ([string]::IsNullOrWhiteSpace($clientAssertion)) {
        throw 'Managed Identity endpoint did not return an access token.'
    }

    Write-Host "Get-CrossTenantAccessToken: Managed Identity assertion acquired, exchanging it for an access token in tenant '$TenantId' (scope '$Scope')."

    # Step 2: exchange the assertion for an access token issued by the target tenant.
    $tokenUri = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/token' -f $TenantId
    $body = @{
        client_id             = $ClientId
        scope                 = $Scope
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'client_credentials'
    }

    try {
        $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        throw "Failed to exchange the Managed Identity assertion for a token in tenant '$TenantId': $_"
    }

    $accessToken = $tokenResponse.access_token
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Token endpoint for tenant '$TenantId' did not return an access token."
    }

    Write-Host "Get-CrossTenantAccessToken: access token for tenant '$TenantId' acquired successfully."

    return $accessToken
}
