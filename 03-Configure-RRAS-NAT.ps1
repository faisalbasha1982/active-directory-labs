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

# Must run elevated
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Not elevated. Close this window, right-click Windows PowerShell > Run as administrator, and run the script again.'
}

# Guard: this script configures a Windows SERVER VM. Never run it on your physical laptop.
$cs = Get-CimInstance Win32_ComputerSystem
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
    throw "This is a Windows client OS ($env:COMPUTERNAME). Run this script INSIDE the Windows Server VM (DC01), not on your host laptop."
}
if ($cs.Model -notmatch 'VMware|Virtual|KVM|QEMU') {
    throw "$env:COMPUTERNAME does not look like a VM (Model: $($cs.Model)). This lab reconfigures NICs and AD; run it inside the VMware guest."
}

Install-WindowsFeature RemoteAccess, Routing, RSAT-RemoteAccess -IncludeManagementTools

foreach ($if in $ExternalIf, $InternalIf) {
    if (-not (Get-NetAdapter -Name $if -ErrorAction SilentlyContinue)) {
        throw "No adapter named '$if'. Run 01 first (it renames the NICs) or check Get-NetAdapter."
    }
}

# Configure RRAS for LAN routing only (no DirectAccess/VPN yet).
# -ErrorAction can't swallow this cmdlet's terminating error on a rerun, so check first.
$ra = Get-RemoteAccess -ErrorAction SilentlyContinue
if (-not $ra -or $ra.RoutingStatus -ne 'Installed') {
    Install-RemoteAccess -VpnType RoutingOnly
}

Set-Service RemoteAccess -StartupType Automatic
Start-Service RemoteAccess

# NAT: External = public side with address translation, Internal = private side.
# netsh is a native exe: it never throws, so check its output instead.
function Invoke-Netsh([string]$NetshArgs) {
    $out = (cmd /c "netsh $NetshArgs" 2>&1 | Out-String).Trim()
    if ($out -match 'command was not found') {
        throw "netsh $NetshArgs -> $out`nRRAS isn't configured yet: open 'Routing and Remote Access', right-click the server > Configure and Enable > Custom > NAT + LAN routing, then rerun."
    }
    if ($out -and $out -notmatch '^Ok\.?$') { Write-Warning "netsh $NetshArgs -> $out" }  # e.g. 'already exists' on rerun
}
Invoke-Netsh 'routing ip nat install'
Invoke-Netsh "routing ip nat add interface name=`"$ExternalIf`" mode=full"
Invoke-Netsh "routing ip nat add interface name=`"$InternalIf`" mode=private"

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
