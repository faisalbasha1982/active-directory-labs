# CORP.LAB — AD DS / DHCP / RRAS-NAT / GPO lab

Two VMs: **DC01** (Windows Server 2019/2022/2025, 2 NICs) and **WS-001** (Windows 10 Pro/Enterprise, 1 NIC).

```
   Internet
      │
 [VMware NAT / bridged]
      │  External NIC (DHCP from upstream)
  ┌───┴──────────────────────────────┐
  │ DC01  AD DS · DNS · DHCP · RRAS/NAT │
  └───┬──────────────────────────────┘
      │  Internal NIC 192.168.10.10/24  (LAN segment / host-only, no VMware DHCP)
      │
   WS-001  ← DHCP 192.168.10.110–.200, GW + DNS = 192.168.10.10
```

| Item | Value |
|---|---|
| Domain / NetBIOS | `corp.lab` / `CORP` |
| DC01 internal IP | `192.168.10.10/24` |
| DHCP scope | `.100–.200`, `.100–.109` excluded, 8-day lease |
| OUs | `Corp\Users\{IT,HR,Finance,Sales,Operations}`, `Corp\Computers`, `Corp\Groups` |
| Users | 150 (30 per OU), `first.last`, random 16-char passwords, change at first logon |

## Run order

| # | Script | Where | Notes |
|---|---|---|---|
| 1 | `01-Prepare-DC-and-Install-ADDS.ps1` | DC01 | Run, reboot (rename), run again (promotes, reboots). Check `Get-NetAdapter` names first. |
| 2 | `02-Configure-DHCP.ps1` | DC01 | Binds DHCP to Internal NIC only. |
| 3 | `03-Configure-RRAS-NAT.ps1` | DC01 | LAN routing + NAT + DNS forwarders. |
| 4 | `04-Create-OUs-and-150-Users.ps1` | DC01 | Also runs `redircmp` so new computers land in `Corp\Computers`. Writes `C:\LabSetup\initial-passwords.csv`. |
| 5 | `05-Join-Win10-to-Domain.ps1` | WS-001 | Pre-flights DNS SRV + LDAP before joining. |
| 7 | `07-Security-Policies.ps1` | DC01 | Run **before** step 6 so verification shows GPOs applied. Audit policy is a short manual GPMC step (in the script comments). |
| 6 | `06-Verify.ps1 -Role DC` / `-Role Client` | both | Client run: log on as a domain user from the CSV (forced password change on first logon). |

Allow scripts first: `Set-ExecutionPolicy -Scope Process Bypass`.

## What the security step applies

- **Domain account policy:** 12-char min, complexity, 24 history, 90-day max age, lockout 5 attempts / 15 min.
- **PSO-Privileged** (GG-IT + Domain Admins): 16-char, 60-day, lockout after 3.
- **SEC-Workstation-Baseline** → `Corp\Computers`: 10-min idle lock, logon banner, hide last user, block USB storage, LLMNR off, SMBv1 off, SMB signing required, NTLMv2-only, firewall on, PowerShell script-block logging.
- **SEC-Standard-User-Restrictions** → every department OU except IT: no Control Panel, no regedit, no CMD, secure screensaver.
- **Logon hours:** Sales limited to Sun–Thu 07:00–20:00 (UAE time).

## Quick tests worth doing manually

- Wrong password 5× on WS-001 → `Search-ADAccount -LockedOut` on DC01 shows the user; `Unlock-ADAccount` clears it.
- Log on as a Sales user on Friday or after 20:00 → refused.
- HR user → `cmd` blocked, Control Panel blocked; IT user → both allowed.
- Plug a USB stick into WS-001 → no access.

## Lab vs production caveats

- RRAS/NAT and DHCP on the DC is a lab shortcut; in production these go on a member server or edge firewall, and you'd run 2+ DCs.
- Delete `initial-passwords.csv` once you're done.
- Next hardening steps if you want to extend: LAPS (Windows LAPS is built into current Win10/11 builds), tiered admin accounts, Protected Users group, and the Microsoft Security Baseline GPOs via the Security Compliance Toolkit.
