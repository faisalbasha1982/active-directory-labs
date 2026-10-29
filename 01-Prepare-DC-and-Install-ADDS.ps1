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

# --- 0. Pre-flight ---------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Run this from an elevated (Run as administrator) Windows PowerShell window.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
}

# --- 1. Rename adapters so later scripts are unambiguous --------------------------------
# Skip if already done on a previous run
$haveExt = Get-NetAdapter -Name 'External' -ErrorAction SilentlyContinue
$haveInt = Get-NetAdapter -Name 'Internal' -ErrorAction SilentlyContinue
if (-not ($haveExt -and $haveInt)) {
    $ext = Get-NetAdapter -Name $ExternalAdapter -ErrorAction SilentlyContinue
    $int = Get-NetAdapter -Name $InternalAdapter -ErrorAction SilentlyContinue

    if (-not ($ext -and $int)) {
        # Names didn't match (Server 2022/2025 often uses "Ethernet" / "Ethernet 2").
        # Auto-detect: the NIC with a default gateway is External, the other is Internal.
        $nics = @(Get-NetAdapter -Physical | Sort-Object ifIndex)
        if ($nics.Count -ne 2) {
            Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress
            throw "Expected exactly 2 NICs, found $($nics.Count). Add a second network adapter to the VM in VMware (VM > Settings > Add > Network Adapter)."
        }
        $gwIdx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).ifIndex
        $ext = $nics | Where-Object { $_.ifIndex -in $gwIdx } | Select-Object -First 1
        if (-not $ext) {
            Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
            throw "Can't tell which NIC is External (none has a default gateway). Rerun with -ExternalAdapter '<name>' -InternalAdapter '<name>' using the names above."
        }
        $int = $nics | Where-Object ifIndex -ne $ext.ifIndex
        Write-Host "Auto-detected: External = '$($ext.Name)', Internal = '$($int.Name)'" -ForegroundColor Yellow
    }
    if (-not $haveExt) { Rename-NetAdapter -Name $ext.Name -NewName 'External' }
    if (-not $haveInt) { Rename-NetAdapter -Name $int.Name -NewName 'Internal' }
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
if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    Write-Host "$env:COMPUTERNAME is already a domain controller - nothing to do. Continue with 02." -ForegroundColor Green
    return
}
# Promotion fails if the built-in local Administrator has a blank/weak password:
#   net user Administrator *     (set a complex one first, then rerun)
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
