[CmdletBinding()]
param(
    [string]$ComputerName = '192.168.1.47',
    [string]$UserName = 'cbx_t'
)

& (Join-Path $PSScriptRoot 'Analyze-EventViewer.ps1') `
    -ComputerName $ComputerName `
    -UserName $UserName `
    -BlankPassword
