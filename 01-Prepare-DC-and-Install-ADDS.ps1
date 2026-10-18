<#
.SYNOPSIS
  Step 1 (run on the server, elevated): rename NICs, set static IP on the internal NIC,
  rename the host, install AD DS and promote to the first DC of a new forest.

.NOTES
  Topology assumed (VMware / EVE-NG):
    NIC "External" -> VMware NAT or bridged (DHCP from upstream, gets internet)
    NIC "Internal" -> LAN segment / host-only (no DHCP; this server will serve it)
  Run once, reboot when prompted (rename), run again -> it promotes, reboots again.
#>
[CmdletBinding()]
param(
    [string]$ServerName      = 'DC01',
    [string]$DomainName      = 'corp.lab',
    [string]$NetBiosName     = 'CORP',
    [string]$InternalIP      = '192.168.10.10',
    [int]   $PrefixLength    = 24,
    # Map current adapter names to roles. Check with Get-NetAdapter first.
    [string]$ExternalAdapter = 'Ethernet0',
    [string]$InternalAdapter = 'Ethernet1'
)

$ErrorActionPreference = 'Stop'

# --- 1. Rename adapters so later scripts are unambiguous --------------------------------
if (Get-NetAdapter -Name $ExternalAdapter -ErrorAction SilentlyContinue) {
    Rename-NetAdapter -Name $ExternalAdapter -NewName 'External'
}
if (Get-NetAdapter -Name $InternalAdapter -ErrorAction SilentlyContinue) {
    Rename-NetAdapter -Name $InternalAdapter -NewName 'Internal'
}

# --- 2. Static IP on Internal (no gateway: the DC IS the gateway for the LAN) -----------
$existing = Get-NetIPAddress -InterfaceAlias 'Internal' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object IPAddress -eq $InternalIP
if (-not $existing) {
    Set-NetIPInterface -InterfaceAlias 'Internal' -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias 'Internal' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceAlias 'Internal' -IPAddress $InternalIP -PrefixLength $PrefixLength | Out-Null
}
# DC points at itself for DNS (loopback second is Microsoft's recommendation)
Set-DnsClientServerAddress -InterfaceAlias 'Internal' -ServerAddresses $InternalIP, '127.0.0.1'
# Stop the external NIC registering a NAT/ISP address in AD-integrated DNS
Set-DnsClient -InterfaceAlias 'External' -RegisterThisConnectionsAddress $false

# --- 3. Rename host (requires reboot before promotion) ----------------------------------
if ($env:COMPUTERNAME -ne $ServerName) {
    Rename-Computer -NewName $ServerName -Force
    Write-Warning "Renamed to $ServerName. Reboot, then run this script again to promote."
    Restart-Computer -Confirm
    return
}

# --- 4. Install AD DS + DNS and create the forest ---------------------------------------
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools

$dsrm = Read-Host -AsSecureString 'Enter DSRM (Directory Services Restore Mode) password'

Install-ADDSForest `
    -DomainName                    $DomainName `
    -DomainNetbiosName             $NetBiosName `
    -ForestMode                    'WinThreshold' `
    -DomainMode                    'WinThreshold' `
    -InstallDns `
    -SafeModeAdministratorPassword $dsrm `
    -NoRebootOnCompletion:$false `
    -Force
# Server reboots automatically. Log back in as CORP\Administrator.
