$password = New-Object System.Security.SecureString
$credential = New-Object System.Management.Automation.PSCredential("cbx_t", $password)
& "d:\Users\joty79\scripts\eventviewer\Analyze-EventViewer.ps1" -ComputerName 192.168.1.47 -Credential $credential
