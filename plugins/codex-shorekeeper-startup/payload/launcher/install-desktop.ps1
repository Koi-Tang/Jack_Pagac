#Requires -Version 5.1
param([string]$DesktopPath, [string]$StateDirectory, [switch]$ReplaceOfficial, [switch]$Diagnose)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shortcut-common.ps1')
try { Install-ProjectShortcuts -DesktopPath $DesktopPath -StateDirectory $StateDirectory -ReplaceOfficial:$ReplaceOfficial -Diagnose:$Diagnose | ConvertTo-Json -Depth 6 }
catch { Write-Error $_.Exception.Message; exit 1 }
