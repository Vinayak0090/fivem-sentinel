<#
=====================================================================
 Install-Monitor.ps1 — install FiveM-Monitor as a boot-time background task
=====================================================================
 Run from an ELEVATED PowerShell (Run as Administrator):
   powershell -ExecutionPolicy Bypass -File .\Install-Monitor.ps1

 What it does:
  - Registers Scheduled Task "FiveM-Monitor" that starts at system boot
    (before anyone logs in via RDP), runs hidden as SYSTEM at
    below-normal priority, and restarts itself if it ever dies.
  - Starts it immediately.

 Uninstall:
   powershell -ExecutionPolicy Bypass -File .\Install-Monitor.ps1 -Uninstall
=====================================================================
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    # Extra arguments to pass to FiveM-Monitor.ps1, e.g. '-ServerPort 30120 -ConsoleLogPath "C:\txData\core\logs\fxserver.log"'
    [string]$MonitorArgs = ""
)

$taskName = 'FiveM-Monitor'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Please run this from an elevated (Administrator) PowerShell."
    exit 1
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Task '$taskName' removed."
    exit 0
}

$scriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$monitorPath = Join-Path $scriptRoot 'FiveM-Monitor.ps1'
if (-not (Test-Path $monitorPath)) { Write-Error "FiveM-Monitor.ps1 not found next to this installer."; exit 1 }

$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`" $MonitorArgs"

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs -WorkingDirectory $scriptRoot
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit (New-TimeSpan -Days 3650) `
                -MultipleInstances IgnoreNew `
                -Priority 7    # 7 = below normal

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description 'FiveM timeout diagnostics monitor (CSV logs + cause classification)' | Out-Null

Start-ScheduledTask -TaskName $taskName
Write-Host "Installed and started task '$taskName'."
Write-Host "Logs will appear under: $(Join-Path $scriptRoot 'logs')"
Write-Host "Build a report any time with: .\New-MonitorReport.ps1 -Open"
