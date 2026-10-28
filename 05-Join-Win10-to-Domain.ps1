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

# Guard: this script joins a Windows 10/11 CLIENT VM. Never run it on your physical laptop.
$cs = Get-CimInstance Win32_ComputerSystem
if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {
    throw "This is a server OS. Run 05 on the Windows 10/11 client VM (WS-001)."
}
if ($cs.Model -notmatch 'VMware|Virtual|KVM|QEMU') {
    throw "$env:COMPUTERNAME does not look like a VM (Model: $($cs.Model)). Run this inside the Windows 10 VMware guest, not on your host laptop."
}

# 1. Get an address from DC01's DHCP
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses
if ((Get-CimInstance Win32_OperatingSystem).Caption -match 'Home') {
    throw 'Windows 10/11 Home cannot join a domain. Use Pro, Enterprise or Education.'
}
ipconfig /release | Out-Null; ipconfig /renew | Out-Null
Start-Sleep -Seconds 5
Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex
$prefix = $DCIP.Substring(0, $DCIP.LastIndexOf('.') + 1)
$ip = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).IPAddress
if (-not ($ip | Where-Object { $_.StartsWith($prefix) })) {
    throw "Client got $ip, not a $prefix* lease from DC01. In VMware the client NIC must be on the SAME LAN Segment (or host-only VMnet with VMware's DHCP disabled) as DC01's Internal NIC."
}

# 2. Pre-flight: DC reachable and the domain's SRV records resolve
if (-not (Test-Connection $DCIP -Count 2 -Quiet)) { throw "Cannot reach DC at $DCIP" }
Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV | Format-Table NameTarget, Port
Test-NetConnection $DCIP -Port 389 | Select-Object ComputerName, RemotePort, TcpTestSucceeded

# 3. Join + rename in one reboot, straight into the Computers OU
$cred = Get-Credential -Message "Domain Admin (e.g. CORP\Administrator)"
Add-Computer -DomainName $DomainName -NewName $NewName -OUPath $OUPath -Credential $cred -Restart -Force
