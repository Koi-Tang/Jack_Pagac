#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','Diagnose','Preview','Uninstall')][string]$Action = 'Diagnose',
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'CodexShorekeeper'),
    [string]$DesktopPath,
    [switch]$ReplaceOfficial,
    [switch]$SkipAppCheck
)
$ErrorActionPreference = 'Stop'
$productId = 'codex-shorekeeper-startup'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$sourceRoot = Join-Path $pluginRoot 'payload'
$manifestPath = Join-Path $pluginRoot 'payload-manifest.json'
$destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$stateRoot = Join-Path $destinationRoot '.shorekeeper'
$statePath = Join-Path $stateRoot 'installation.json'
$shortcutState = Join-Path $stateRoot 'shortcuts'
$installationMutex = $null
$mutexHeld = $false

function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw ('reparse-path-refused: ' + $current) }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Assert-Destination {
    if ($destinationRoot -notmatch '^[A-Za-z]:\\.+' -or $destinationRoot.IndexOfAny([char[]]'*?') -ge 0) { throw 'destination-must-be-a-local-subdirectory' }
    $protected = @($env:USERPROFILE,$env:LOCALAPPDATA,$env:APPDATA,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:WINDIR,[Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('MyDocuments'))
    foreach ($folder in $protected) {
        if ($folder -and $destinationRoot -ieq ([IO.Path]::GetFullPath($folder).TrimEnd('\'))) { throw 'destination-cannot-be-a-user-or-system-root' }
    }
    foreach ($system in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)})) {
        if ($system -and $destinationRoot.StartsWith(([IO.Path]::GetFullPath($system).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'destination-cannot-be-inside-system-programs' }
    }
    if ((Test-Path -LiteralPath $sourceRoot -PathType Container) -and ($destinationRoot -ieq $pluginRoot -or $destinationRoot.StartsWith($pluginRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $pluginRoot.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'destination-cannot-overlap-plugin-source' }
    Assert-NoReparse $destinationRoot
}
function Get-OwnedPath([string]$Root, [string]$RelativePath) {
    if (-not $RelativePath -or $RelativePath -match '[<>:"|?*]' -or $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)' -or [IO.Path]::IsPathRooted($RelativePath)) { throw 'manifest-relative-path-invalid' }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'manifest-path-outside-root' }
    Assert-NoReparse $path
    return $path
}
function Assert-FileEntries($Files) {
    $seen = @{}
    if (@($Files).Count -eq 0) { throw 'empty-file-manifest' }
    foreach ($file in @($Files)) {
        $null = Get-OwnedPath $destinationRoot ([string]$file.path)
        if ($file.path -match '^\.shorekeeper([\\/]|$)' -or $file.path -match '^launcher[\\/]runtime([\\/]|$)' -or $file.path -match '(^|[\\/])(last-launch\.log|shortcut-backup)([\\/]|$)') { throw 'manifest-cannot-own-user-state' }
        if ($file.sha256 -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($file.path)) { throw 'manifest-hash-or-duplicate-invalid' }
        $seen[$file.path] = $true
    }
}
function Read-BundleManifest {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'payload-manifest-missing: run scripts/build.ps1 in the source checkout' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.productId -ne $productId -or -not $manifest.version) { throw 'payload-manifest-identity-invalid' }
    Assert-FileEntries $manifest.files
    foreach ($file in @($manifest.files)) {
        $source = Get-OwnedPath $sourceRoot $file.path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne $file.size -or (Get-Hash $source) -ne $file.sha256) { throw ('payload-integrity-check-failed: ' + $file.path) }
    }
    foreach ($required in @('Shorekeeper-Codex.exe','launcher/StartupGate.exe','launcher/launch.ps1','launcher/inject.mjs','launcher/manage.ps1','launcher/shortcut-common.ps1','overlay.js','assets/startup.mp4','assets/poster.jpg','preview.html','preview-overlay.js','uninstall.cmd')) {
        if (-not @($manifest.files | Where-Object { $_.path -eq $required }).Count) { throw ('payload-required-file-missing: ' + $required) }
    }
    return $manifest
}
function Read-Installation {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.schemaVersion -ne 1 -or $state.productId -ne $productId -or $state.destination -ine $destinationRoot -or $state.installationId -notmatch '^[a-f0-9]{32}$') { throw 'installation-record-identity-invalid' }
    Assert-FileEntries $state.files
    if ($state.retiredFiles) { Assert-FileEntries $state.retiredFiles }
    return $state
}
function Save-Installation($State) {
    $temporary = Join-Path $stateRoot ('installation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}
function Assert-OwnedFileUnchanged($File) {
    $path = Get-OwnedPath $destinationRoot $File.path
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('owned-file-replaced-by-directory: ' + $File.path) }
    $hash = Get-Hash $path
    if ($hash -ne $File.sha256 -and (-not $File.previousSha256 -or $hash -ne $File.previousSha256)) { throw ('installed-file-modified-preserved: ' + $File.path) }
}
function Get-AppStatus {
    if ($SkipAppCheck) { return [pscustomobject]@{ checked=$false; ok=$null; code='explicitly-skipped'; noApplicationStarted=$true } }
    $publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
    try {
        $windowsApps = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'WindowsApps')).TrimEnd('\')
        foreach ($package in @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Sort-Object Version -Descending)) {
            if (-not $package.InstallLocation) { continue }
            $root = [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\')
            if (-not $root.StartsWith($windowsApps + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            [xml]$xml = Get-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Raw
            if ($xml.Package.Identity.Name -ne 'OpenAI.Codex' -or $xml.Package.Identity.Publisher -ne $publisher -or -not (Test-Path -LiteralPath (Join-Path $root 'app\ChatGPT.exe'))) { continue }
            $nodes = @((Join-Path $root 'app\resources\cua_node\bin\node.exe'),(Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'))
            $node = $nodes | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if (-not $node) { return [pscustomobject]@{ checked=$true; ok=$false; code='codex-node-runtime-not-found'; message='Update and open Microsoft Store Codex once, then retry.'; noApplicationStarted=$true } }
            return [pscustomobject]@{ checked=$true; ok=$true; code='official-store-codex-found'; version=[string]$package.Version; noApplicationStarted=$true }
        }
        return [pscustomobject]@{ checked=$true; ok=$false; code='official-store-codex-not-found'; message='Install Microsoft Store Codex and open it once before installing this startup animation.'; noApplicationStarted=$true }
    } catch { return [pscustomobject]@{ checked=$true; ok=$false; code='official-store-codex-check-failed'; message=$_.Exception.Message; noApplicationStarted=$true } }
}
function Load-ShortcutHelpers([string]$Root) {
    $helper = Join-Path $Root 'launcher\shortcut-common.ps1'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'shortcut-helper-missing' }
    # Dot sourcing is performed by the caller so the helper stays in script scope.
    return $helper
}
function Get-RecordedDesktop {
    if ($DesktopPath) { return $DesktopPath }
    $recordPath = Join-Path $shortcutState 'shortcuts.json'
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.productId -ne $productId) { throw 'shortcut-record-identity-mismatch' }
        return [string]$record.desktop
    }
    return [Environment]::GetFolderPath('Desktop')
}

try {
    Assert-Destination
    # One user cannot upgrade and uninstall the same destination concurrently.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($destinationRoot.ToLowerInvariant())))).Replace('-','') } finally { $sha.Dispose() }
    $installationMutex = New-Object Threading.Mutex($false, ('Local\CodexShorekeeperManage-' + $key))
    try { $mutexHeld = $installationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld=$true }
    if (-not $mutexHeld) { throw 'another-installation-operation-is-running' }
    $state = Read-Installation

    if ($Action -eq 'Uninstall') {
        if (-not $state) { [pscustomobject]@{ action=$Action; installed=$false; noChanges=$true } | ConvertTo-Json; exit 0 }
        $ownedFiles = @($state.files) + @($state.retiredFiles)
        $ownedFiles = @($ownedFiles | Where-Object { $_ })
        # Preflight everything before restoring links or removing files.
        foreach ($file in $ownedFiles) { Assert-OwnedFileUnchanged $file }
        $helperFile = @($state.files | Where-Object { $_.path -eq 'launcher/shortcut-common.ps1' }) | Select-Object -First 1
        if (-not $helperFile) { throw 'shortcut-helper-not-owned' }
        . (Load-ShortcutHelpers $destinationRoot)
        $desktop = Get-RecordedDesktop
        $null = Restore-ProjectShortcuts -DesktopPath $desktop -StateDirectory $shortcutState -Diagnose
        $restored = Restore-ProjectShortcuts -DesktopPath $desktop -StateDirectory $shortcutState
        foreach ($file in $ownedFiles) {
            $path = Get-OwnedPath $destinationRoot $file.path
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
        # Remove only known generated diagnostics, never arbitrary directory contents.
        $runtime = Join-Path $destinationRoot 'launcher\runtime'
        if (Test-Path -LiteralPath $runtime -PathType Container) {
            Assert-NoReparse $runtime
            foreach ($file in @(Get-ChildItem -LiteralPath $runtime -File -Force)) {
                if ($file.Name -match '^[a-f0-9]{32}\.(windows|timing|shown|ready|pid|identity|done|abort|result\.json|owner\.json|log|foreground\.json|foreground-check\.json)$') { Remove-Item -LiteralPath $file.FullName -Force }
            }
        }
        $lastLog = Join-Path $destinationRoot 'launcher\last-launch.log'
        if (Test-Path -LiteralPath $lastLog -PathType Leaf) { Assert-NoReparse $lastLog; Remove-Item -LiteralPath $lastLog -Force }
        $shortcutRecord = Join-Path $shortcutState 'shortcuts.json'
        if (Test-Path -LiteralPath $shortcutRecord) {
            $links = Get-Content -LiteralPath $shortcutRecord -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @($links.entries)) {
                if ($entry.originalPresent) { Remove-Item -LiteralPath (Join-Path $shortcutState $entry.backup) -Force }
            }
            Remove-Item -LiteralPath $shortcutRecord -Force
        }
        Remove-Item -LiteralPath $statePath -Force
        # Consider only directories that held managed files or managed state.
        # Never walk unrelated user directories or follow a junction during cleanup.
        $ownedDirectories = @($runtime, $shortcutState, $stateRoot)
        foreach ($file in $ownedFiles) {
            $parent = Split-Path (Get-OwnedPath $destinationRoot $file.path) -Parent
            while ($parent -and $parent -ine $destinationRoot) {
                $ownedDirectories += $parent
                $parent = Split-Path $parent -Parent
            }
        }
        foreach ($directory in @($ownedDirectories | Select-Object -Unique | Sort-Object Length -Descending)) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Assert-NoReparse $directory
                if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
            }
        }
        $retained = @()
        if (@(Get-ChildItem -LiteralPath $destinationRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $destinationRoot -Force }
        else { $retained = @(Get-ChildItem -LiteralPath $destinationRoot -Force | ForEach-Object { $_.Name }) }
        [pscustomobject]@{ action=$Action; removed=$true; restoredShortcuts=$restored.restored; retainedUnownedItems=$retained; currentApplicationPreserved=$true } | ConvertTo-Json -Depth 5
        exit 0
    }

    $manifest = Read-BundleManifest
    if ($Action -eq 'Preview') {
        # Standalone test page, never the Codex window or a debugging endpoint.
        Start-Process -FilePath (Join-Path $sourceRoot 'preview.html') | Out-Null
        [pscustomobject]@{ action=$Action; standalonePreview=$true; currentApplicationPreserved=$true } | ConvertTo-Json
        exit 0
    }
    $app = Get-AppStatus
    if ($Action -eq 'Diagnose') {
        $integrity = @()
        if ($state) {
            foreach ($file in @($state.files)) {
                $path = Get-OwnedPath $destinationRoot $file.path
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $integrity += ('missing: ' + $file.path) }
                elseif ((Get-Hash $path) -ne $file.sha256) { $integrity += ('modified: ' + $file.path) }
            }
        }
        [pscustomobject]@{ action=$Action; productId=$productId; destination=$destinationRoot; desktop=(Get-RecordedDesktop); bundleVersion=$manifest.version; bundleIntegrity='verified'; installed=[bool]$state; installedVersion=$(if ($state) { $state.version } else { $null }); installationIntegrityErrors=$integrity; app=$app; noApplicationStarted=$true; noDesktopChanges=$true } | ConvertTo-Json -Depth 6
        if (($app.checked -and -not $app.ok) -or $integrity.Count) { exit 2 }
        exit 0
    }
    if ($app.checked -and -not $app.ok) { throw ($app.code + ': ' + $app.message) }
    if (-not $state -and (Test-Path -LiteralPath $destinationRoot)) {
        if (@(Get-ChildItem -LiteralPath $destinationRoot -Force).Count) { throw 'destination-not-empty-and-not-owned' }
    }
    $previous = @{}
    if ($state) {
        foreach ($file in (@($state.files) + @($state.retiredFiles) | Where-Object { $_ })) { Assert-OwnedFileUnchanged $file; $previous[$file.path]=$file }
    }
    foreach ($file in @($manifest.files)) {
        $path = Get-OwnedPath $destinationRoot $file.path
        if ((Test-Path -LiteralPath $path) -and -not $previous.ContainsKey($file.path)) { throw ('unowned-file-collision: ' + $file.path) }
    }
    # Shortcut conflicts are detected before installation files are changed.
    . (Load-ShortcutHelpers $sourceRoot)
    $null = Install-ProjectShortcuts -DesktopPath (Get-RecordedDesktop) -StateDirectory $shortcutState -ReplaceOfficial:$ReplaceOfficial -Diagnose -BaseDirectory $destinationRoot -AllowMissingLauncher
    $newFiles = @()
    $incoming = @{}
    foreach ($file in @($manifest.files)) {
        $oldHash = $(if ($previous.ContainsKey($file.path)) { $previous[$file.path].sha256 } else { '' })
        $newFiles += [pscustomobject]@{ path=$file.path; sha256=$file.sha256; size=$file.size; previousSha256=$oldHash }
        $incoming[$file.path]=$true
    }
    $retired = @($previous.Values | Where-Object { -not $incoming.ContainsKey($_.path) })
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $state = [pscustomobject]@{ schemaVersion=1; productId=$productId; installationId=$(if ($state) { $state.installationId } else { [guid]::NewGuid().ToString('N') }); destination=$destinationRoot; version=$manifest.version; status='installing'; files=$newFiles; retiredFiles=$retired }
    Save-Installation $state
    foreach ($file in $newFiles) {
        $source = Get-OwnedPath $sourceRoot $file.path
        $target = Get-OwnedPath $destinationRoot $file.path
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        $temp = $target + '.shorekeeper-' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            Copy-Item -LiteralPath $source -Destination $temp
            if ((Get-Hash $temp) -ne $file.sha256) { throw ('installed-copy-check-failed: ' + $file.path) }
            Move-Item -LiteralPath $temp -Destination $target -Force
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
    foreach ($file in $retired) {
        $path = Get-OwnedPath $destinationRoot $file.path
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    . (Load-ShortcutHelpers $destinationRoot)
    $shortcuts = Install-ProjectShortcuts -DesktopPath (Get-RecordedDesktop) -StateDirectory $shortcutState -ReplaceOfficial:$ReplaceOfficial
    foreach ($file in $state.files) { $file.previousSha256='' }
    $state.retiredFiles=@()
    $state.status='installed'
    Save-Installation $state
    [pscustomobject]@{ action=$Action; installed=$true; version=$state.version; destination=$destinationRoot; shortcuts=$shortcuts.installed; currentApplicationPreserved=$true; automaticAppLaunch=$false } | ConvertTo-Json -Depth 6
    exit 0
} catch {
    [Console]::Error.WriteLine(('Shorekeeper ' + $Action + ' failed: ' + $_.Exception.Message))
    exit 1
} finally {
    if ($mutexHeld -and $installationMutex) { try { $installationMutex.ReleaseMutex() } catch {} }
    if ($installationMutex) { $installationMutex.Dispose() }
}
