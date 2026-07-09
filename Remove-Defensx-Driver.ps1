#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

function Write-Status {
    param([string]$msg, [string]$color = 'Cyan')
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor $color
}

# MoveFileEx lets us schedule locked files for deletion on next reboot
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FileUtil {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);
    public const uint MOVEFILE_DELAY_UNTIL_REBOOT = 0x00000004;
}
"@

function Schedule-DeleteOnReboot {
    param([string]$path)
    if (Test-Path $path) {
        $result = [FileUtil]::MoveFileEx($path, $null, [FileUtil]::MOVEFILE_DELAY_UNTIL_REBOOT)
        if ($result) {
            Write-Status "  Scheduled for reboot deletion: $path" 'Green'
        } else {
            Write-Status "  WARN: Could not schedule $path" 'Yellow'
        }
    }
}

function Remove-RegKey {
    param([string]$path)
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Recurse -Force -Confirm:$false
            Write-Status "  Removed registry key: $path" 'Green'
        } catch {
            Write-Status "  WARN: Could not remove $path" 'Yellow'
        }
    }
}

Write-Status "=== Step 1: Find Defensx driver services ===" 'White'

# Get all services pointing to a defensx driver or named defensx*
$svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$defensxSvcs = Get-ChildItem $svcRoot -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'defensx' -or
    ((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ImagePath -match 'defensx')
}

foreach ($svc in $defensxSvcs) {
    $name = $svc.PSChildName
    $props = Get-ItemProperty $svc.PSPath -ErrorAction SilentlyContinue
    $imgPath = $props.ImagePath
    Write-Status "Found service: $name  ->  $imgPath"

    # Resolve the actual .sys file path
    if ($imgPath) {
        $sysFile = $imgPath -replace '\\SystemRoot\\', "$env:SystemRoot\" `
                             -replace '\\\?\?\\', '' `
                             -replace '"', ''
        $sysFile = $sysFile.Trim()

        # Try immediate stop (will fail if in use, that's expected)
        Write-Status "  Attempting to stop service: $name"
        Start-Process 'sc.exe' -ArgumentList "stop `"$name`"" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 2

        # Try immediate delete
        Start-Process 'sc.exe' -ArgumentList "delete `"$name`"" -Wait -WindowStyle Hidden

        # Remove registry key (handles cases where sc.exe delete fails)
        Remove-RegKey "$svcRoot\$name"

        # Schedule the .sys file for deletion on reboot
        if ($sysFile -and (Test-Path $sysFile)) {
            Schedule-DeleteOnReboot $sysFile
        }
    } else {
        Remove-RegKey "$svcRoot\$name"
    }
}

if ($defensxSvcs.Count -eq 0) {
    Write-Status "  No driver services found by registry scan." 'Yellow'
}

Write-Status "=== Step 2: Scan for Defensx .sys files ===" 'White'

$driverDirs = @(
    "$env:SystemRoot\System32\drivers",
    "$env:SystemRoot\SysWOW64\drivers"
)

foreach ($dir in $driverDirs) {
    if (Test-Path $dir) {
        $sysFiles = Get-ChildItem -Path $dir -Filter '*.sys' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'defensx' }
        foreach ($f in $sysFiles) {
            Write-Status "  Found driver file: $($f.FullName)"
            # Try direct delete first
            try {
                Remove-Item $f.FullName -Force -Confirm:$false
                Write-Status "  Deleted immediately: $($f.FullName)" 'Green'
            } catch {
                # File locked - schedule for reboot
                Schedule-DeleteOnReboot $f.FullName
            }
        }
    }
}

Write-Status "=== Step 3: Remove WFP / minifilter registrations ===" 'White'

$filterKeys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e967-e325-11ce-bfc1-08002be10318}',
    'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order',
    'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
)

# Scan filter manager entries
$filterMgr = 'HKLM:\SYSTEM\CurrentControlSet\Services\FltMgr\Instances'
if (Test-Path $filterMgr) {
    Get-ChildItem $filterMgr -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match 'defensx') {
            Remove-RegKey $_.PSPath
        }
    }
}

# Remove from UpperFilters / LowerFilters in device classes
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class'
Get-ChildItem $classRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    foreach ($filterProp in @('UpperFilters', 'LowerFilters')) {
        $val = $p.$filterProp
        if ($val -and $val -match 'defensx') {
            $cleaned = ($val | Where-Object { $_ -notmatch 'defensx' })
            Set-ItemProperty -Path $_.PSPath -Name $filterProp -Value $cleaned -ErrorAction SilentlyContinue
            Write-Status "  Cleaned $filterProp in $($_.PSPath)" 'Green'
        }
    }
}

Write-Status "=== Step 4: Clear PnP device entries ===" 'White'

$pnpRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum'
Get-ChildItem $pnpRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.Service -match 'defensx' -or $_.Name -match 'defensx') {
        Write-Status "  Found PnP entry: $($_.PSPath)"
        Remove-RegKey $_.PSPath
    }
}

Write-Status "=== Done ===" 'White'
Write-Host ""
Write-Host "Driver registry entries removed." -ForegroundColor Green
Write-Host "Locked .sys files (if any) are scheduled for deletion on reboot." -ForegroundColor Green
Write-Host ""
Write-Host "*** REBOOT NOW to complete driver removal, then retry your installation. ***" -ForegroundColor Yellow
