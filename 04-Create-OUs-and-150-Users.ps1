<#
.SYNOPSIS
  Step 4 (run on DC01 as a Domain Admin): build an OU structure with 5 department OUs,
  a security group per department, and 150 users (30 per OU) with unique random passwords.

.OUTPUTS
  C:\LabSetup\initial-passwords.csv  - delete after distributing; it holds live credentials.
  Users must change password at first logon.
#>
[CmdletBinding()]
param(
    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Sales', 'Operations'),
    [int]     $UsersPerOU  = 30,
    [string]  $RootOUName  = 'Corp',
    [string]  $OutDir      = 'C:\LabSetup'
)

$ErrorActionPreference = 'Stop'

# Guard: this script configures a Windows SERVER VM. Never run it on your physical laptop.
$cs = Get-CimInstance Win32_ComputerSystem
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
    throw "This is a Windows client OS ($env:COMPUTERNAME). Run this script INSIDE the Windows Server VM (DC01), not on your host laptop."
}
if ($cs.Model -notmatch 'VMware|Virtual|KVM|QEMU') {
    throw "$env:COMPUTERNAME does not look like a VM (Model: $($cs.Model)). This lab reconfigures NICs and AD; run it inside the VMware guest."
}
Import-Module ActiveDirectory

$domainDN  = (Get-ADDomain).DistinguishedName
$upnSuffix = (Get-ADDomain).DNSRoot
$rootDN    = "OU=$RootOUName,$domainDN"

function New-OUIfMissing([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
    }
    return $dn
}

function New-RandomPassword([int]$Length = 16) {
    # Guarantees upper, lower, digit and symbol to satisfy domain complexity
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%^&*-_=+')
    $chars = foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] }
    $all = -join $sets
    $chars += 1..($Length - 4) | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

# Name pools - combinations give plenty of unique names
$first = 'Ahmed','Fatima','Omar','Aisha','Yusuf','Mariam','Khalid','Noura','Hassan','Layla',
         'Rashid','Huda','Saeed','Reem','Tariq','Sara','Imran','Zainab','Bilal','Hana',
         'John','Emma','Raj','Priya','Chen','Mei','Lucas','Sofia','David','Anna'
$last  = 'Khan','Ali','Rahman','Hussain','Siddiqui','Patel','Sharma','Smith','Brown','Wilson',
         'Mansoori','Haddad','Nasser','Qureshi','Farouk','Lee','Wang','Garcia','Fernandes','Mathew'

# --- OU structure -----------------------------------------------------------------------
$null = New-OUIfMissing $RootOUName $domainDN
$usersRoot     = New-OUIfMissing 'Users'     $rootDN
$computersRoot = New-OUIfMissing 'Computers' $rootDN
$groupsOU      = New-OUIfMissing 'Groups'    $rootDN

# Redirect new computer accounts out of the default CN=Computers container
# (GPOs can't link to CN=Computers, so this matters for step 7)
redircmp $computersRoot | Out-Null

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$report = [System.Collections.Generic.List[object]]::new()
$used   = @{}

foreach ($dept in $Departments) {
    $ouDN = New-OUIfMissing $dept $usersRoot
    $grp  = "GG-$dept"
    if (-not (Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $grp -GroupScope Global -GroupCategory Security -Path $groupsOU `
            -Description "All $dept department users"
    }

    for ($i = 1; $i -le $UsersPerOU; $i++) {
        do {
            $fn = Get-Random $first; $ln = Get-Random $last
            $sam = ("{0}.{1}" -f $fn, $ln).ToLower()
            if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
        } while ($used.ContainsKey($sam) -or (Get-ADUser -Filter "SamAccountName -eq '$sam'"))
        $used[$sam] = $true

        $pwd = New-RandomPassword
        New-ADUser -Name "$fn $ln" -GivenName $fn -Surname $ln `
            -SamAccountName $sam -UserPrincipalName "$sam@$upnSuffix" `
            -DisplayName "$fn $ln" -Department $dept -Title "$dept Staff" `
            -Path $ouDN -AccountPassword (ConvertTo-SecureString $pwd -AsPlainText -Force) `
            -Enabled $true -ChangePasswordAtLogon $true

        Add-ADGroupMember -Identity $grp -Members $sam
        $report.Add([pscustomobject]@{ Department = $dept; SamAccountName = $sam; UPN = "$sam@$upnSuffix"; InitialPassword = $pwd })
    }
    Write-Host "Created $UsersPerOU users in $dept" -ForegroundColor Green
}

$csv = Join-Path $OutDir 'initial-passwords.csv'
$report | Export-Csv $csv -NoTypeInformation
# Lock the file down to Domain Admins
icacls $csv /inheritance:r /grant:r "Domain Admins:F" "SYSTEM:F" | Out-Null

# Summary
Get-ADOrganizationalUnit -SearchBase $usersRoot -SearchScope OneLevel -Filter * | ForEach-Object {
    [pscustomobject]@{ OU = $_.Name; Users = (Get-ADUser -SearchBase $_.DistinguishedName -Filter *).Count }
} | Format-Table
Write-Warning "Initial passwords written to $csv - distribute securely, then delete it."
