#Requires -Version 5.1
param([string]$DesktopPath, [string]$StateDirectory, [switch]$Diagnose)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shortcut-common.ps1')
try { Restore-ProjectShortcuts -DesktopPath $DesktopPath -StateDirectory $StateDirectory -Diagnose:$Diagnose | ConvertTo-Json -Depth 6 }
catch { Write-Error $_.Exception.Message; exit 1 }
