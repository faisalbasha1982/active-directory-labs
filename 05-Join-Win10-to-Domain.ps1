<#
.SYNOPSIS
  Step 5 (run on the Windows 10 client, elevated). Win10 Pro/Enterprise/Education only -
  Home edition cannot join a domain.
  Client NIC must be on the same LAN segment as DC01's "Internal" NIC.
#>
[CmdletBinding()]
param(
    [string]$DomainName   = 'corp.lab',
    [string]$NewName      = 'WS-001',
    [string]$OUPath       = 'OU=Computers,OU=Corp,DC=corp,DC=lab',
    [string]$DCIP         = '192.168.10.10'
)

$ErrorActionPreference = 'Stop'

# 1. Get an address from DC01's DHCP
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses
ipconfig /release | Out-Null; ipconfig /renew | Out-Null
Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex

# 2. Pre-flight: DC reachable and the domain's SRV records resolve
if (-not (Test-Connection $DCIP -Count 2 -Quiet)) { throw "Cannot reach DC at $DCIP" }
Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV | Format-Table NameTarget, Port
Test-NetConnection $DCIP -Port 389 | Select-Object ComputerName, RemotePort, TcpTestSucceeded

# 3. Join + rename in one reboot, straight into the Computers OU
$cred = Get-Credential -Message "Domain Admin (e.g. CORP\Administrator)"
Add-Computer -DomainName $DomainName -NewName $NewName -OUPath $OUPath -Credential $cred -Restart -Force
