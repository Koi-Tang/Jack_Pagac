#Requires -Version 5.1
[CmdletBinding()]
param([string]$Version = '1.0.0', [switch]$ManifestOnly)
$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$payload = Join-Path $pluginRoot 'payload'
try {
    if ($Version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.-]+)?$') { throw 'invalid-version' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'manage.ps1') -Destination (Join-Path $payload 'launcher\manage.ps1') -Force
    if (-not $ManifestOnly) {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is not installed.' }
        $icon = Join-Path $payload 'assets\icon.ico'
        $entryArgs = @('/nologo','/target:winexe','/platform:anycpu','/r:System.Windows.Forms.dll',('/out:' + (Join-Path $payload 'Shorekeeper-Codex.exe')))
        if (Test-Path -LiteralPath $icon) { $entryArgs += '/win32icon:' + $icon }
        $entryArgs += Join-Path $payload 'launcher\Launch.cs'
        & $compiler @entryArgs
        if ($LASTEXITCODE -ne 0) { throw 'Launch.cs compilation failed.' }
        & $compiler '/nologo' '/target:winexe' '/platform:anycpu' '/r:System.Windows.Forms.dll' '/r:System.Xml.dll' ('/out:' + (Join-Path $payload 'launcher\StartupGate.exe')) (Join-Path $payload 'launcher\StartupGate.cs')
        if ($LASTEXITCODE -ne 0) { throw 'StartupGate.cs compilation failed.' }
    }
    $approvedPaths = @('LICENSE','THIRD_PARTY_NOTICES.md','Shorekeeper-Codex.exe','overlay.js','preview.html','preview-overlay.js','launch.cmd','preview.cmd','restore.cmd','install-desktop.cmd','uninstall.cmd','launcher/Launch.cs','launcher/StartupGate.cs','launcher/StartupGate.exe','launcher/inject.mjs','launcher/launch.ps1','launcher/manage.ps1','launcher/shortcut-common.ps1','launcher/install-desktop.ps1','launcher/restore-desktop.ps1','assets/startup.mp4','assets/poster.jpg','assets/media-quality.json','assets/icon.ico')
    $files = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($payload.TrimEnd('\').Length + 1).Replace('\','/')
        if ($relative -notin $approvedPaths) { throw ('File is not in the public payload allowlist: ' + $relative) }
        $files += [pscustomobject]@{ path=$relative; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); size=$file.Length }
    }
    foreach ($required in $approvedPaths) { if ($required -notin @($files.path)) { throw ('Required public payload file is missing: ' + $required) } }
    [pscustomobject]@{ schemaVersion=1; productId='codex-shorekeeper-startup'; version=$Version; files=$files } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $pluginRoot 'payload-manifest.json') -Encoding UTF8
    Write-Output ('Built ' + $files.Count + ' verified payload files for version ' + $Version + '.')
} catch { Write-Error $_.Exception.Message; exit 1 }
