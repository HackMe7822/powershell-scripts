# PowerShell Scripts

A collection of PowerShell utility scripts for Windows administration.

## Scripts

### Remove-Defensx.ps1
Detects and fully removes the Defensx security agent from a Windows machine.
Cleans registry entries, services, scheduled tasks, and leftover files.
Run as Administrator.

### Remove-Defensx-Driver.ps1
Force-removes the Defensx kernel driver when it is stuck in a locked state.
Uses the Windows MoveFileEx API to schedule locked .sys files for deletion on reboot.
Run as Administrator, then reboot.

## Usage
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
& ".\Remove-Defensx.ps1"
```
