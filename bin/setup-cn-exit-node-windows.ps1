# setup-cn-exit-node-windows.ps1 - autostart helper for a WSL2-based exit node on Windows.
# ASCII-only on purpose: Windows PowerShell 5.1 on a Chinese-locale system reads .ps1 as GBK,
# so any non-ASCII character would become mojibake and break the parser.
# Run from a normal PowerShell; it self-elevates via UAC if not already admin.
param([string]$Distro = "Ubuntu")   # WSL distro name; some installs are e.g. "Ubuntu-22.04" (check: wsl -l -q)
$ErrorActionPreference = "Continue"   # don't stop on a single failure; land the critical task first

# Self-elevate: if not admin, relaunch elevated via UAC, then exit.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Need admin rights. Relaunching via UAC (click Yes)..." -ForegroundColor Yellow
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Distro `"$Distro`""
  exit
}
Write-Host "== Running as admin, configuring ==" -ForegroundColor Green

Write-Host "== [1/3] Scheduled task: start WSL at logon (enable auto-logon for unattended reboot) ==" -ForegroundColor Cyan
# WSL needs an interactive user session to start, so trigger AT LOGON (boot/S4U without a session does NOT work).
# For unattended reboot recovery, ALSO enable auto-logon (netplwiz): auto-logon creates a session at boot,
# then this task starts WSL, then systemd brings up tailscaled.
# Keepalive 'sleep infinity' holds the WSL VM up. ExecutionTimeLimit=0 => never auto-killed.
try {
  $act  = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Distro -u root sleep infinity"
  $trg  = New-ScheduledTaskTrigger -AtLogOn
  $prin = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
  $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName "CN-Exit-WSL-Tailnet" -Action $act -Trigger $trg -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
  Write-Host "Scheduled task created (logon-triggered; ENABLE AUTO-LOGON for unattended reboots)." -ForegroundColor Green
} catch {
  Write-Warning "Failed to create scheduled task: $_"
}

Write-Host "== [2/3] .wslconfig: keep WSL VM from idle-shutdown (written without BOM) ==" -ForegroundColor Cyan
$wslcfg = Join-Path $env:USERPROFILE ".wslconfig"
[System.IO.File]::WriteAllText($wslcfg, "[wsl2]`nvmIdleTimeout=-1`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $wslcfg"

Write-Host "== [3/3] Power: never sleep/hibernate on AC, disable fast startup, lid=do nothing (best-effort) ==" -ForegroundColor Cyan
try { powercfg /change standby-timeout-ac 0 } catch { Write-Warning "standby setting failed, ignore" }
try { powercfg /change hibernate-timeout-ac 0 } catch {}
try { powercfg /h off } catch { Write-Warning "disable hibernate/fast-startup failed, ignore" }
try {
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
  powercfg /setactive SCHEME_CURRENT
} catch { Write-Warning "lid setting failed (alias unknown on some models); set 'do nothing on lid close' in GUI, ignore" }

Write-Host "`n== Verify scheduled task ==" -ForegroundColor Cyan
$t = Get-ScheduledTask -TaskName "CN-Exit-WSL-Tailnet" -ErrorAction SilentlyContinue
if ($t) { Write-Host ("Verify OK: task '{0}' state={1}" -f $t.TaskName, $t.State) -ForegroundColor Green }
else { Write-Warning "Verify FAILED: scheduled task not found" }

Write-Host "`nDone. Manual items: 1) install WSL  2) *** enable auto-logon (netplwiz) -- REQUIRED for WSL to return after an unattended reboot ***" -ForegroundColor Yellow
Write-Host "Next: inside WSL, run setup-cn-exit-node.sh (ask for a one-hour preauth key)." -ForegroundColor Yellow
