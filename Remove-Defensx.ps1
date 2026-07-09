#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

function Write-Status {
    param([string]$msg, [string]$color = 'Cyan')
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor $color
}

function Remove-RegKey {
    param([string]$path)
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Recurse -Force -Confirm:$false
            Write-Status "  Removed: $path" 'Green'
        } catch {
            Write-Status "  WARN: Could not remove $path" 'Yellow'
        }
    }
}

$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

Write-Status "=== Scanning for Defensx installation ===" 'White'

$defensxEntries = @()
foreach ($root in $uninstallRoots) {
    if (Test-Path $root) {
        $items = Get-ChildItem $root
        foreach ($item in $items) {
            $props = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match 'defensx' -or $props.Publisher -match 'defensx') {
                $defensxEntries += $props
            }
        }
    }
}

if ($defensxEntries.Count -gt 0) {
    foreach ($entry in $defensxEntries) {
        Write-Status "Found: $($entry.DisplayName)  v$($entry.DisplayVersion)" 'Green'
        $uStr = $entry.UninstallString
        if ($uStr) {
            Write-Status "Running official uninstaller..."
            if ($uStr -match 'MsiExec') {
                $guid = [regex]::Match($uStr, '\{[^}]+\}').Value
                if ($guid) {
                    Start-Process 'msiexec.exe' -ArgumentList "/x $guid /qn /norestart" -Wait
                }
            } else {
                $exe = ($uStr -split '"')[1]
                if ($exe -and (Test-Path $exe)) {
                    Start-Process $exe -ArgumentList '/S /SILENT /VERYSILENT /NORESTART' -Wait
                } else {
                    Start-Process 'cmd.exe' -ArgumentList "/c $uStr /S /SILENT" -Wait
                }
            }
            Write-Status "Uninstaller finished." 'Green'
        }
    }
} else {
    Write-Status "No Defensx entry found in Add/Remove Programs." 'Yellow'
}

Write-Status "=== Stopping processes ===" 'White'
$procs = Get-Process | Where-Object { $_.Name -match 'defensx' }
foreach ($p in $procs) {
    Write-Status "  Killing: $($p.Name) (PID $($p.Id))"
    Stop-Process -Id $p.Id -Force
}
if ($procs.Count -eq 0) { Write-Status "  No Defensx processes running." 'Yellow' }

Write-Status "=== Removing services ===" 'White'
$services = Get-Service | Where-Object { $_.DisplayName -match 'defensx' -or $_.Name -match 'defensx' }
foreach ($svc in $services) {
    Write-Status "  Stopping: $($svc.Name)"
    Stop-Service -Name $svc.Name -Force
    Start-Process 'sc.exe' -ArgumentList "delete `"$($svc.Name)`"" -Wait
    Write-Status "  Deleted service: $($svc.Name)" 'Green'
}
if ($services.Count -eq 0) { Write-Status "  No Defensx services found." 'Yellow' }

Write-Status "=== Removing scheduled tasks ===" 'White'
$tasks = Get-ScheduledTask | Where-Object { $_.TaskName -match 'defensx' -or $_.TaskPath -match 'defensx' }
foreach ($t in $tasks) {
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
    Write-Status "  Removed task: $($t.TaskPath)$($t.TaskName)" 'Green'
}
if ($tasks.Count -eq 0) { Write-Status "  No Defensx scheduled tasks found." 'Yellow' }

Write-Status "=== Cleaning registry ===" 'White'

$staticKeys = @(
    'HKLM:\SOFTWARE\Defensx',
    'HKLM:\SOFTWARE\WOW6432Node\Defensx',
    'HKCU:\SOFTWARE\Defensx',
    'HKLM:\SYSTEM\CurrentControlSet\Services\Defensx',
    'HKLM:\SYSTEM\CurrentControlSet\Services\DefensxAgent',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\defensx.exe'
)
foreach ($key in $staticKeys) {
    Remove-RegKey $key
}

Write-Status "  Running deep registry scan..."
$hives = @('HKLM:\SOFTWARE', 'HKCU:\SOFTWARE', 'HKLM:\SYSTEM\CurrentControlSet\Services')
foreach ($hive in $hives) {
    if (Test-Path $hive) {
        $allKeys = Get-ChildItem -Path $hive -Recurse -ErrorAction SilentlyContinue
        foreach ($k in $allKeys) {
            if ($k.Name -match 'defensx') {
                Remove-RegKey $k.PSPath
            }
        }
    }
}

foreach ($root in $uninstallRoots) {
    if (Test-Path $root) {
        $items = Get-ChildItem $root -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $props = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match 'defensx' -or $props.Publisher -match 'defensx') {
                Remove-RegKey $item.PSPath
            }
        }
    }
}

Write-Status "=== Removing leftover files ===" 'White'
$dirs = @(
    "$env:ProgramFiles\Defensx",
    "${env:ProgramFiles(x86)}\Defensx",
    "$env:ProgramData\Defensx",
    "$env:LOCALAPPDATA\Defensx",
    "$env:APPDATA\Defensx"
)
foreach ($d in $dirs) {
    if (Test-Path $d) {
        try {
            Remove-Item -Path $d -Recurse -Force -Confirm:$false
            Write-Status "  Removed: $d" 'Green'
        } catch {
            Write-Status "  WARN: Could not remove $d" 'Yellow'
        }
    }
}

Write-Status "=== Verification ===" 'White'
$remaining = @()
foreach ($root in $uninstallRoots) {
    if (Test-Path $root) {
        $items = Get-ChildItem $root -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $p = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'defensx') {
                $remaining += $p.DisplayName
            }
        }
    }
}

if ($remaining.Count -gt 0) {
    Write-Status "WARN: Still present - reboot and re-run may be needed:" 'Red'
    foreach ($r in $remaining) { Write-Status "  - $r" 'Red' }
} else {
    Write-Status "Defensx fully removed. Please reboot to complete cleanup." 'Green'
}
