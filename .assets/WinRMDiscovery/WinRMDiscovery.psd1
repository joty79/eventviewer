@{
    RootModule        = 'WinRMDiscovery.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = '822b5f8e-c91c-4f87-9855-bec01e9a0f76'
    Author            = 'joty79'
    CompanyName       = 'Personal'
    Copyright         = '(c) 2026 joty79. All rights reserved.'
    Description       = 'Reusable, PC-only LAN discovery for WinRM PowerShell tools.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Find-WinRMComputer'
        'Get-WinRMNetworkIdentity'
        'Get-WinRMDiscoveryDiagnostics'
        'Get-WinRMDiscoveryStateRoot'
        'Set-WinRMDiscoveryStateRoot'
        'Get-WinRMConnectionHistory'
        'Add-WinRMConnectionHistoryEntry'
        'Resolve-WinRMHistoryTargetAddress'
        'Test-WinRMDiscoveryIPv4'
        'ConvertTo-WinRMDiscoveryHostDisplayName'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('WinRM', 'Discovery', 'Windows', 'PowerShell')
            ProjectUri = 'https://github.com/joty79/.agent-shared'
        }
    }
}
