<#
.SYNOPSIS
  Step 6: verification. Run the -Role DC block on DC01 and -Role Client on the Win10 box
  after logging on as a domain user (e.g. CORP\ahmed.khan).
#>
[CmdletBinding()]
param(
    [ValidateSet('DC', 'Client')] [string]$Role = 'Client',
    [string]$DomainName = 'corp.lab',
    [string]$DCIP       = '192.168.10.10'
)

function Check($name, [scriptblock]$test) {
    try   { $ok = & $test } catch { $ok = $false }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name) -ForegroundColor $color
}

if ($Role -eq 'DC') {
    Check 'AD DS service running'        { (Get-Service NTDS).Status -eq 'Running' }
    Check 'DNS service running'          { (Get-Service DNS).Status -eq 'Running' }
    Check 'DHCP authorized in AD'        { [bool](Get-DhcpServerInDC) }
    Check 'DHCP scope active'            { (Get-DhcpServerv4Scope).State -contains 'Active' }
    Check 'RRAS running'                 { (Get-Service RemoteAccess).Status -eq 'Running' }
    Check 'DC SRV record resolves'       { [bool](Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV) }
    Check '150 users under OU=Corp'      { (Get-ADUser -SearchBase "OU=Users,OU=Corp,$((Get-ADDomain).DistinguishedName)" -Filter *).Count -ge 150 }
    Check '5 department OUs'             { (Get-ADOrganizationalUnit -SearchBase "OU=Users,OU=Corp,$((Get-ADDomain).DistinguishedName)" -SearchScope OneLevel -Filter *).Count -eq 5 }
    Check 'Internet via External NIC'    { Test-Connection 8.8.8.8 -Count 1 -Quiet }

    Write-Host "`n--- dcdiag summary (failures only) ---"
    dcdiag /q
    Write-Host "`n--- DHCP leases ---"
    Get-DhcpServerv4Lease -ScopeId 192.168.10.0 | Format-Table IPAddress, HostName, ClientId, AddressState
    Write-Host "`n--- Domain computers ---"
    Get-ADComputer -Filter * -Properties LastLogonDate, OperatingSystem | Format-Table Name, OperatingSystem, LastLogonDate, DistinguishedName
    Write-Host "`n--- Recent Kerberos TGT requests (4768) - proves users authenticated against DC01 ---"
    Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4768 } -MaxEvents 10 |
        Select-Object TimeCreated, @{n='Account'; e={ $_.Properties[0].Value }}, @{n='Client'; e={ $_.Properties[9].Value }} | Format-Table
}
else {
    Check 'Leased IP in 192.168.10.0/24' { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like '192.168.10.*').PrefixOrigin -contains 'Dhcp' }
    Check 'Ping DC01'                    { Test-Connection $DCIP -Count 2 -Quiet }
    Check 'Resolve DC01 by name'         { [bool](Resolve-DnsName "DC01.$DomainName") }
    Check 'LDAP 389 open'                { (Test-NetConnection $DCIP -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded }
    Check 'Kerberos 88 open'             { (Test-NetConnection $DCIP -Port 88  -WarningAction SilentlyContinue).TcpTestSucceeded }
    Check 'Secure channel to domain'     { Test-ComputerSecureChannel }
    Check 'Logged on with domain account'{ $env:USERDOMAIN -eq ($DomainName.Split('.')[0].ToUpper()) }
    Check 'SYSVOL accessible'            { Test-Path "\\$DomainName\SYSVOL" }
    Check 'Internet via NAT'             { Test-Connection 8.8.8.8 -Count 1 -Quiet }
    Check 'Public DNS via forwarder'     { [bool](Resolve-DnsName microsoft.com) }

    Write-Host "`n--- Identity ---";       whoami /upn; whoami /groups /fo table | Select-String 'GG-'
    Write-Host "`n--- Kerberos tickets ---"; klist
    Write-Host "`n--- Logon DC ---";       nltest /dsgetdc:$DomainName
    Write-Host "`n--- Applied GPOs ---";   gpresult /r /scope:user | Select-String -Pattern 'Applied Group Policy Objects' -Context 0,8
}
