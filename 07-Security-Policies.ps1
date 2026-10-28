<#
.SYNOPSIS
  Step 7 (run on DC01 as a Domain Admin): domain account policy, a stricter fine-grained
  policy for IT/admins, and GPOs for workstation hardening and user restrictions.

  Note: password & lockout policy for normal users MUST be set at the domain level
  (Default Domain Policy / Set-ADDefaultDomainPasswordPolicy). Linking a password GPO to
  an OU does nothing for domain accounts - that's what fine-grained PSOs are for.
#>
[CmdletBinding()]
param([string]$RootOU = 'Corp')

$ErrorActionPreference = 'Stop'

# Guard: this script configures a Windows SERVER VM. Never run it on your physical laptop.
$cs = Get-CimInstance Win32_ComputerSystem
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
    throw "This is a Windows client OS ($env:COMPUTERNAME). Run this script INSIDE the Windows Server VM (DC01), not on your host laptop."
}
if ($cs.Model -notmatch 'VMware|Virtual|KVM|QEMU') {
    throw "$env:COMPUTERNAME does not look like a VM (Model: $($cs.Model)). This lab reconfigures NICs and AD; run it inside the VMware guest."
}
Import-Module ActiveDirectory, GroupPolicy

$domain    = Get-ADDomain
$domainDN  = $domain.DistinguishedName
$usersOU   = "OU=Users,OU=$RootOU,$domainDN"
$compsOU   = "OU=Computers,OU=$RootOU,$domainDN"

# --- 1. Domain password + lockout policy (all users) -----------------------------------
Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
    -MinPasswordLength 12 -ComplexityEnabled $true -PasswordHistoryCount 24 `
    -MaxPasswordAge (New-TimeSpan -Days 90) -MinPasswordAge (New-TimeSpan -Days 1) `
    -LockoutThreshold 5 -LockoutDuration (New-TimeSpan -Minutes 15) `
    -LockoutObservationWindow (New-TimeSpan -Minutes 15) -ReversibleEncryptionEnabled $false

# --- 2. Fine-grained policy: stricter for IT dept + Domain Admins ----------------------
if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO-Privileged'")) {
    New-ADFineGrainedPasswordPolicy -Name 'PSO-Privileged' -Precedence 10 `
        -MinPasswordLength 16 -ComplexityEnabled $true -PasswordHistoryCount 24 `
        -MaxPasswordAge (New-TimeSpan -Days 60) -MinPasswordAge (New-TimeSpan -Days 1) `
        -LockoutThreshold 3 -LockoutDuration (New-TimeSpan -Minutes 30) `
        -LockoutObservationWindow (New-TimeSpan -Minutes 30) -ReversibleEncryptionEnabled $false
}
Add-ADFineGrainedPasswordPolicySubject -Identity 'PSO-Privileged' -Subjects 'GG-IT', 'Domain Admins'

# Helper
function New-LinkedGPO([string]$Name, [string]$Target, [string]$Comment) {
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $Name -Comment $Comment }
    if (-not ((Get-GPInheritance -Target $Target).GpoLinks.DisplayName -contains $Name)) {
        New-GPLink -Name $Name -Target $Target -LinkEnabled Yes | Out-Null
    }
    $gpo
}

# --- 3. Workstation hardening (computer settings) -> Computers OU ----------------------
$ws = New-LinkedGPO 'SEC-Workstation-Baseline' $compsOU 'Machine hardening for domain workstations'
$k  = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-GPRegistryValue -Name $ws.DisplayName -Key $k -ValueName 'InactivityTimeoutSecs' -Type DWord -Value 600   # lock after 10 min
Set-GPRegistryValue -Name $ws.DisplayName -Key $k -ValueName 'DontDisplayLastUserName' -Type DWord -Value 1
Set-GPRegistryValue -Name $ws.DisplayName -Key $k -ValueName 'LegalNoticeCaption' -Type String -Value 'Authorized use only'
Set-GPRegistryValue -Name $ws.DisplayName -Key $k -ValueName 'LegalNoticeText' -Type String -Value 'This system is for authorized users of CORP. Activity is monitored and logged.'
# Block USB mass storage
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' -ValueName 'Deny_All' -Type DWord -Value 1
# Disable LLMNR (poisoning vector)
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -ValueName 'EnableMulticast' -Type DWord -Value 0
# Disable SMBv1 client/server
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ValueName 'SMB1' -Type DWord -Value 0
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SYSTEM\CurrentControlSet\Services\mrxsmb10' -ValueName 'Start' -Type DWord -Value 4
# Require SMB signing
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ValueName 'RequireSecuritySignature' -Type DWord -Value 1
# NTLMv2 only, refuse LM & NTLMv1
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' -ValueName 'LmCompatibilityLevel' -Type DWord -Value 5
# Firewall on for all profiles
foreach ($p in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
    Set-GPRegistryValue -Name $ws.DisplayName -Key "HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall\$p" -ValueName 'EnableFirewall' -Type DWord -Value 1
}
# PowerShell script-block logging (pairs well with 4104 collection in a SIEM)
Set-GPRegistryValue -Name $ws.DisplayName -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -ValueName 'EnableScriptBlockLogging' -Type DWord -Value 1

# --- 4. Standard user restrictions -> each non-IT department OU ------------------------
$ur = Get-GPO -Name 'SEC-Standard-User-Restrictions' -ErrorAction SilentlyContinue
if (-not $ur) { $ur = New-GPO -Name 'SEC-Standard-User-Restrictions' -Comment 'User-side restrictions for non-IT staff' }
$uk = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies'
Set-GPRegistryValue -Name $ur.DisplayName -Key "$uk\Explorer" -ValueName 'NoControlPanel' -Type DWord -Value 1
Set-GPRegistryValue -Name $ur.DisplayName -Key "$uk\System"   -ValueName 'DisableRegistryTools' -Type DWord -Value 1
Set-GPRegistryValue -Name $ur.DisplayName -Key 'HKCU\Software\Policies\Microsoft\Windows\System' -ValueName 'DisableCMD' -Type DWord -Value 2   # 2 = block prompt, allow .bat
# Password-protected screensaver as a user-side backstop
$sk = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Set-GPRegistryValue -Name $ur.DisplayName -Key $sk -ValueName 'ScreenSaveActive'    -Type String -Value '1'
Set-GPRegistryValue -Name $ur.DisplayName -Key $sk -ValueName 'ScreenSaverIsSecure' -Type String -Value '1'
Set-GPRegistryValue -Name $ur.DisplayName -Key $sk -ValueName 'ScreenSaveTimeOut'   -Type String -Value '600'

Get-ADOrganizationalUnit -SearchBase $usersOU -SearchScope OneLevel -Filter "Name -ne 'IT'" | ForEach-Object {
    if (-not ((Get-GPInheritance -Target $_.DistinguishedName).GpoLinks.DisplayName -contains $ur.DisplayName)) {
        New-GPLink -Name $ur.DisplayName -Target $_.DistinguishedName | Out-Null
    }
}

# --- 5. Logon hours example: Sales restricted to 07:00-20:00 Sun-Thu (UAE work week) --
# 21-byte bitmap, UTC-based. Build it rather than hand-coding bytes.
function Get-LogonHoursBytes([int[]]$Days, [int]$StartLocal, [int]$EndLocal, [int]$UtcOffset = 4) {
    $bits = New-Object bool[] 168
    foreach ($d in $Days) { for ($h = $StartLocal; $h -lt $EndLocal; $h++) {
        $bits[((($d * 24 + $h - $UtcOffset) % 168) + 168) % 168] = $true } }
    $bytes = New-Object byte[] 21
    for ($i = 0; $i -lt 168; $i++) { if ($bits[$i]) { $bytes[[math]::Floor($i / 8)] += [byte](1 -shl ($i % 8)) } }
    ,$bytes
}
$hours = Get-LogonHoursBytes -Days 0, 1, 2, 3, 4 -StartLocal 7 -EndLocal 20   # 0 = Sunday
Get-ADUser -SearchBase "OU=Sales,$usersOU" -Filter * | Set-ADUser -Replace @{ logonHours = $hours }

# --- 6. Audit policy -------------------------------------------------------------------
# Advanced Audit Policy isn't registry-based, so set it in GPMC (one-time, ~2 minutes):
#   Default Domain Controllers Policy > Computer Config > Policies > Windows Settings >
#   Security Settings > Advanced Audit Policy Configuration:
#     Account Logon: Credential Validation, Kerberos Auth Service  -> Success, Failure
#     Account Management: User/Security Group Management           -> Success, Failure
#     Logon/Logoff: Logon, Account Lockout                         -> Success, Failure
#     DS Access: Directory Service Changes                         -> Success
#   Same Logon/Logoff settings in SEC-Workstation-Baseline.

Write-Host "`nPolicies applied. On the client: gpupdate /force, then gpresult /h C:\gp.html" -ForegroundColor Green
Get-ADDefaultDomainPasswordPolicy | Format-List MinPasswordLength, LockoutThreshold, LockoutDuration, MaxPasswordAge
Get-GPO -All | Where-Object DisplayName -like 'SEC-*' | Format-Table DisplayName, GpoStatus, ModificationTime
