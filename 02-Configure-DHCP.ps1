<#
.SYNOPSIS
  Step 2 (run on DC01 as a Domain Admin): install DHCP, authorize it in AD,
  create the LAN scope with router/DNS/domain options, bind it to the Internal NIC only.
#>
[CmdletBinding()]
param(
    [string]$DomainName  = 'corp.lab',
    [string]$ServerFQDN  = "DC01.corp.lab",
    [string]$ServerIP    = '192.168.10.10',
    [string]$ScopeId     = '192.168.10.0',
    [string]$SubnetMask  = '255.255.255.0',
    [string]$StartRange  = '192.168.10.100',
    [string]$EndRange    = '192.168.10.200',
    [string]$Gateway     = '192.168.10.10',   # DC01 does NAT, so it is the gateway
    [timespan]$Lease     = (New-TimeSpan -Days 8)
)

$ErrorActionPreference = 'Stop'

Install-WindowsFeature DHCP -IncludeManagementTools

# Local security groups DHCP Administrators / DHCP Users
netsh dhcp add securitygroups | Out-Null
Restart-Service DHCPServer

# Authorize in AD (otherwise the service refuses to lease in a domain)
if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $ServerIP)) {
    Add-DhcpServerInDC -DnsName $ServerFQDN -IPAddress $ServerIP
}

# Silence the "post-install configuration not complete" flag in Server Manager
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2

# Scope
if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'Corp-LAN' -StartRange $StartRange -EndRange $EndRange `
        -SubnetMask $SubnetMask -LeaseDuration $Lease -State Active
}

# Reserve the static range below .100 implicitly by scope bounds; exclude a few for printers etc.
Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange '192.168.10.100' -EndRange '192.168.10.109' -ErrorAction SilentlyContinue

# Options: 003 Router, 006 DNS, 015 DNS domain name
Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $ServerIP -DnsDomain $DomainName

# Secure dynamic DNS updates on behalf of clients
Set-DhcpServerv4DnsSetting -ComputerName $ServerFQDN -DynamicUpdates Always -DeleteDnsRRonLeaseExpiry $true

# Only answer on the Internal NIC - never hand out leases onto the upstream/NAT network
Get-DhcpServerv4Binding | ForEach-Object {
    $alias = (Get-NetIPAddress -IPAddress $_.IPAddress -ErrorAction SilentlyContinue).InterfaceAlias
    Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState ($alias -eq 'Internal')
}

Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, State
Get-DhcpServerv4OptionValue -ScopeId $ScopeId | Format-Table OptionId, Name, Value
