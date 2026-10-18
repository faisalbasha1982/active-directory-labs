<#
.SYNOPSIS
  Step 3 (run on DC01 elevated): install Remote Access with Routing, enable LAN routing,
  and configure NAT so the Internal LAN reaches the internet through the External NIC.

.NOTES
  Lab only. In production RRAS/NAT does NOT belong on a domain controller - put it on a
  separate member server or an edge firewall. It's co-located here to keep the lab to 2 VMs.
  The NAT bits use netsh because Windows Server has no first-class cmdlets for RRAS NAT
  (New-NetNat is for Hyper-V/containers, not RRAS).
#>
[CmdletBinding()]
param(
    [string]$ExternalIf = 'External',
    [string]$InternalIf = 'Internal'
)

$ErrorActionPreference = 'Stop'

Install-WindowsFeature RemoteAccess, Routing, RSAT-RemoteAccess -IncludeManagementTools

# Configure RRAS for LAN routing only (no DirectAccess/VPN yet)
Install-RemoteAccess -VpnType RoutingOnly -ErrorAction SilentlyContinue

Set-Service RemoteAccess -StartupType Automatic
Start-Service RemoteAccess

# NAT: External = public side with address translation, Internal = private side
netsh routing ip nat install
netsh routing ip nat add interface name="$ExternalIf" mode=full
netsh routing ip nat add interface name="$InternalIf" mode=private

# Make sure the box forwards IPv4 between the two NICs
Set-NetIPInterface -InterfaceAlias $ExternalIf -Forwarding Enabled
Set-NetIPInterface -InterfaceAlias $InternalIf -Forwarding Enabled

Restart-Service RemoteAccess

# DNS forwarders so internal clients resolve public names via DC01
Set-DnsServerForwarder -IPAddress '1.1.1.1', '8.8.8.8' -UseRootHint $true

netsh routing ip nat show interface
Write-Host "NAT configured. From a LAN client: Test-NetConnection 8.8.8.8 ; Resolve-DnsName microsoft.com" -ForegroundColor Green

<# Optional - remote access for admins (SSTP/IKEv2 VPN). Needs a certificate and a
   reachable public name, so it is not automated here:
   Install-RemoteAccess -VpnType Vpn
   then RRAS console > Properties > Security > SSL cert binding, and
   NPS network policy restricted to an AD group such as GG-VPN-Users.
#>
