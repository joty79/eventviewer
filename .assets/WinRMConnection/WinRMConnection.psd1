@{
    RootModule        = 'WinRMConnection.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'faffc83f-52b9-4ada-bd7b-00f29fc51cd9'
    Author            = 'joty79'
    CompanyName       = 'Personal'
    Copyright         = '(c) 2026 joty79. All rights reserved.'
    Description       = 'Bounded, observable, and reusable authenticated WinRM session handling.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Connect-WinRMSession'
        'Get-WinRMCredentialProfile'
        'Get-WinRMConnectionErrorCategory'
        'Invoke-WinRMCommand'
        'New-WinRMBlankPasswordCredential'
        'Remove-WinRMCredentialProfile'
        'Save-WinRMCredentialProfile'
        'Test-WinRMConnection'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('WinRM', 'Connection', 'Retry', 'PowerShell', 'Windows')
            ProjectUri = 'https://github.com/joty79/.agent-shared'
        }
    }
}
