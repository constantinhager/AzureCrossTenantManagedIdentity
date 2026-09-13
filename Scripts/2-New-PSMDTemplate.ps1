#Requires -Modules PSModuleDevelopment
<#
.SYNOPSIS
    Scaffolds the Function App project structure using the OFFICIAL
    "AzureFunction" template from PSModuleDevelopment (PSFramework project).

.DESCRIPTION
    Unlike an earlier version of this blog post, this no longer uses a
    custom-built template but the template that PSModuleDevelopment
    actually ships with:
    https://github.com/PowershellFrameworkCollective/PSModuleDevelopment/tree/development/templates/AzureFunction

    After running, the complete base structure (build/, function/, <Name>/)
    is created under -OutPath - your own code then goes into
    <Name>/functions/httpTrigger (or eventGridTrigger/timerTrigger/
    nonPublished).

    If the PSModuleDevelopment module isn't installed yet, it is installed
    for the current user automatically.

.PARAMETER OutPath
    Path in which the scaffolded project structure is created. Default:
    '.\AzureFunctionApp'.

.PARAMETER Name
    Name of the Function App project/module. Used as the folder name under
    -OutPath and as the project's identifier, so it must be a valid
    identifier (letters, digits, underscore, starting with a letter).
    Default: 'CrossTenantFunctionApp'.

.PARAMETER Author
    Author name recorded in the generated project metadata. Default:
    'Constantin Hager'.

.PARAMETER Company
    Company name recorded in the generated project metadata. Default:
    'the-itguy.de'.

.PARAMETER Description
    Description recorded in the generated project metadata. Default:
    'Cross-tenant Microsoft Graph access via a Managed Identity as a
    Federated Identity Credential.'

.EXAMPLE
    .\PSMDTemplate.ps1

    Scaffolds the project under '.\AzureFunctionApp\CrossTenantFunctionApp'
    using all default values.

.EXAMPLE
    .\PSMDTemplate.ps1 -OutPath 'C:\src' -Name 'MyFunctionApp' -Author 'Jane Doe'

    Scaffolds the project under 'C:\src\MyFunctionApp' with a custom name
    and author.

.OUTPUTS
    None. The script writes status messages via Write-Host and does not
    emit objects to the pipeline.

.NOTES
    Author: Constantin Hager (the-itguy.de)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $OutPath = '.\AzureFunctionApp',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]
    $Name = 'CrossTenantFunctionApp',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $Author = 'Constantin Hager',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $Company = 'the-itguy.de',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $Description = 'Cross-tenant Microsoft Graph access via a Managed Identity as a Federated Identity Credential.'
)

if (-not (Get-Module -ListAvailable -Name PSModuleDevelopment)) {
    Install-Module -Name PSModuleDevelopment -Scope CurrentUser -Force
}
Import-Module PSModuleDevelopment

Invoke-PSMDTemplate -TemplateName AzureFunction -OutPath $OutPath -Parameters @{
    name        = $Name
    author      = $Author
    company     = $Company
    description = $Description
}

Write-Host "Scaffold created at: $OutPath" -ForegroundColor Green
Write-Host 'Add your own code now under:'
Write-Host "  $OutPath\$Name\functions\httpTrigger\      <- automatically becomes HTTP endpoints"
Write-Host ''
Write-Host 'Then build with: .\build\build.ps1 [-AppRg <RG> -AppName <FunctionAppName>]'
