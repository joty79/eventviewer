@{
    RootModule        = 'WinRMWorkshop.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7afb9c88-6ff0-4712-81d6-05eb999318c4'
    Author            = 'joty79'
    CompanyName       = 'Personal'
    Copyright         = '(c) 2026 joty79. All rights reserved.'
    Description       = 'Verified exact-target WinRM client preparation for the workshop convenience profile.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Add-WinRMWorkshopTrustedHost'
        'Get-WinRMWorkshopTrustedHost'
        'Remove-WinRMWorkshopTrustedHost'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('WinRM', 'TrustedHosts', 'Workshop', 'PowerShell', 'Windows')
            ProjectUri = 'https://github.com/joty79/.agent-shared'
        }
    }
}
