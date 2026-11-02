#Requires -Version 5.1
# Desktop links are the only external files managed by these helpers.
$script:ShortcutProduct = 'codex-shorekeeper-startup'
$script:ShortcutNames = @('守岸人 Codex.lnk', 'ChatGPT.lnk', 'Codex.lnk')
$script:OfficialAumid = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$script:ShortcutBase = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')

function Get-ShortcutContext([string]$DesktopPath, [string]$StateDirectory, [string]$BaseDirectory) {
    $base = $script:ShortcutBase
    if ($BaseDirectory) { $base = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\') }
    if (-not $DesktopPath) { $DesktopPath = [Environment]::GetFolderPath('Desktop') }
    if (-not $DesktopPath) { throw 'desktop-path-unavailable' }
    $desktop = [IO.Path]::GetFullPath($DesktopPath).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'desktop-directory-not-found' }
    if (-not $StateDirectory) { $StateDirectory = Join-Path $base '.shorekeeper\shortcuts' }
    $state = [IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
    if (-not $state.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'shortcut-state-must-be-inside-installation' }
    foreach ($directory in @($base, $state)) {
        if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'shortcut-state-reparse-point' }
    }
    return [pscustomobject]@{ base=$base; desktop=$desktop; state=$state; launcher=(Join-Path $base 'Shorekeeper-Codex.exe'); record=(Join-Path $state 'shortcuts.json'); ws=(New-Object -ComObject WScript.Shell) }
}
function Get-LinkPath($Context, [string]$Name) {
    if ($Name -notin $script:ShortcutNames) { throw 'shortcut-name-not-owned' }
    return Join-Path $Context.desktop $Name
}
function Get-LinkHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-OwnLink($Context, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $link = $Context.ws.CreateShortcut($Path)
    return [string]::Equals($link.TargetPath, $Context.launcher, [StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($link.Arguments)
}
function Test-OfficialLink($Context, [string]$Path) {
    $link = $Context.ws.CreateShortcut($Path)
    if ((Split-Path $link.TargetPath -Leaf) -ieq 'explorer.exe' -and $link.Arguments.Trim('"') -ieq ('shell:AppsFolder\' + $script:OfficialAumid)) { return $true }
    if ($link.TargetPath -match '\\WindowsApps\\OpenAI\.Codex_[0-9.]+_(x64|arm64)__2p2nqsd0c76g0\\app\\ChatGPT\.exe$') {
        try {
            $root = Split-Path (Split-Path $link.TargetPath -Parent) -Parent
            [xml]$manifest = Get-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Raw
            if ($manifest.Package.Identity.Name -eq 'OpenAI.Codex' -and $manifest.Package.Identity.Publisher -eq 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') { return $true }
        } catch {}
    }
    try {
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.NameSpace($Context.desktop).ParseName((Split-Path $Path -Leaf))
        return $item -and ($item.ExtendedProperty('System.Link.TargetParsingPath') -eq $script:OfficialAumid -or $item.ExtendedProperty('System.AppUserModel.ID') -eq $script:OfficialAumid)
    } catch { return $false }
}
function Read-ShortcutRecord($Context) {
    if (-not (Test-Path -LiteralPath $Context.record)) { return $null }
    $record = Get-Content -LiteralPath $Context.record -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.schemaVersion -ne 2 -or $record.productId -ne $script:ShortcutProduct -or $record.desktop -ine $Context.desktop -or $record.launcher -ine $Context.launcher) { throw 'shortcut-record-identity-mismatch' }
    $seen = @{}
    foreach ($entry in @($record.entries)) {
        if ($entry.name -notin $script:ShortcutNames -or $entry.backup -cne $entry.name -or $seen.ContainsKey($entry.name)) { throw 'shortcut-record-path-invalid' }
        $seen[$entry.name] = $true
        if ($entry.originalPresent -and $entry.originalSha256 -notmatch '^[a-f0-9]{64}$') { throw 'shortcut-backup-hash-invalid' }
        if ($entry.installedSha256 -and $entry.installedSha256 -notmatch '^[a-f0-9]{64}$') { throw 'shortcut-installed-hash-invalid' }
        if ($entry.originalPresent) {
            $backup = Join-Path $Context.state $entry.backup
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-LinkHash $backup) -ne $entry.originalSha256) { throw ('shortcut-backup-check-failed: ' + $entry.name) }
        }
    }
    return $record
}
function Save-ShortcutRecord($Context, $Record) {
    $temporary = Join-Path $Context.state ('record-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Context.record -Force
}
function Assert-LinkUnchanged($Context, $Entry) {
    $path = Get-LinkPath $Context $Entry.name
    if (-not (Test-Path -LiteralPath $path)) { return }
    $hash = Get-LinkHash $path
    if ($Entry.originalPresent -and $hash -eq $Entry.originalSha256) { return }
    if ($Entry.installedSha256 -and $hash -eq $Entry.installedSha256 -and (Test-OwnLink $Context $path)) { return }
    throw ('shortcut-modified-preserved: ' + $Entry.name)
}
function Install-ProjectShortcuts([string]$DesktopPath, [string]$StateDirectory, [switch]$ReplaceOfficial, [switch]$Diagnose, [string]$BaseDirectory, [switch]$AllowMissingLauncher) {
    $context = Get-ShortcutContext $DesktopPath $StateDirectory $BaseDirectory
    if (-not (Test-Path -LiteralPath $context.launcher -PathType Leaf) -and -not ($Diagnose -and $AllowMissingLauncher)) { throw 'launcher-not-found' }
    $record = Read-ShortcutRecord $context
    $all = @()
    if ($record) { $all = @($record.entries) }
    $requested = @('守岸人 Codex.lnk')
    if ($ReplaceOfficial) {
        foreach ($name in @('ChatGPT.lnk', 'Codex.lnk')) {
            if (Test-Path -LiteralPath (Get-LinkPath $context $name)) { $requested += $name }
        }
    }
    # A subsequent version keeps the user's explicitly selected replacement mode.
    $requested += @($all | Where-Object { $_.active } | ForEach-Object { $_.name })
    $requested = @($requested | Select-Object -Unique)
    foreach ($name in $requested) {
        $path = Get-LinkPath $context $name
        $entry = @($all | Where-Object { $_.name -eq $name }) | Select-Object -First 1
        if ($entry) { Assert-LinkUnchanged $context $entry; continue }
        $present = Test-Path -LiteralPath $path
        if ($present -and ($name -eq '守岸人 Codex.lnk' -or -not (Test-OfficialLink $context $path))) { throw ('shortcut-conflict-preserved: ' + $name) }
        $all += [pscustomobject]@{ name=$name; originalPresent=[bool]$present; originalSha256=$(if ($present) { Get-LinkHash $path } else { '' }); backup=$name; installedSha256=''; active=$false }
    }
    if ($Diagnose) { return [pscustomobject]@{ desktop=$context.desktop; planned=@($requested); replacesOfficial=[bool](@($requested | Where-Object { $_ -ne '守岸人 Codex.lnk' }).Count); noChanges=$true } }
    New-Item -ItemType Directory -Path $context.state -Force | Out-Null
    $temporaryLinks = @()
    try {
        foreach ($name in $requested) {
            $entry = @($all | Where-Object { $_.name -eq $name }) | Select-Object -First 1
            $path = Get-LinkPath $context $name
            $backup = Join-Path $context.state $entry.backup
            if ($entry.originalPresent -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $path -Destination $backup }
            if ($entry.originalPresent -and (Get-LinkHash $backup) -ne $entry.originalSha256) { throw ('shortcut-backup-check-failed: ' + $name) }
            $temp = Join-Path $context.desktop ('.shorekeeper-' + [guid]::NewGuid().ToString('N') + '.lnk')
            $temporaryLinks += [pscustomobject]@{ path=$temp; destination=$path }
            $link = $context.ws.CreateShortcut($temp)
            $link.TargetPath = $context.launcher
            $link.WorkingDirectory = $context.base
            $link.Description = 'Shorekeeper startup for Codex (codex-shorekeeper-startup)'
            $icon = Join-Path $context.base 'assets\icon.ico'
            $link.IconLocation = $(if (Test-Path -LiteralPath $icon) { $icon + ',0' } else { $context.launcher + ',0' })
            $link.Save()
            $entry.installedSha256 = Get-LinkHash $temp
            $entry.active = $true
        }
        $record = [pscustomobject]@{ schemaVersion=2; productId=$script:ShortcutProduct; desktop=$context.desktop; launcher=$context.launcher; entries=@($all) }
        # Record recovery hashes before replacing even the first shortcut.
        Save-ShortcutRecord $context $record
        foreach ($temp in $temporaryLinks) { Move-Item -LiteralPath $temp.path -Destination $temp.destination -Force }
        return [pscustomobject]@{ desktop=$context.desktop; installed=@($requested); backupRecord=$context.record }
    } finally {
        foreach ($temp in $temporaryLinks) { if (Test-Path -LiteralPath $temp.path) { Remove-Item -LiteralPath $temp.path -Force } }
    }
}
function Restore-ProjectShortcuts([string]$DesktopPath, [string]$StateDirectory, [switch]$Diagnose) {
    $context = Get-ShortcutContext $DesktopPath $StateDirectory
    $record = Read-ShortcutRecord $context
    if (-not $record) { return [pscustomobject]@{ restored=@(); noInstallation=$true; noChanges=$true } }
    $entries = @($record.entries | Where-Object { $_.active })
    foreach ($entry in $entries) { Assert-LinkUnchanged $context $entry }
    if ($Diagnose) { return [pscustomobject]@{ desktop=$context.desktop; planned=@($entries.name); noChanges=$true } }
    foreach ($entry in $entries) {
        $path = Get-LinkPath $context $entry.name
        if ($entry.originalPresent) { Copy-Item -LiteralPath (Join-Path $context.state $entry.backup) -Destination $path -Force }
        elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        $entry.active = $false
    }
    Save-ShortcutRecord $context $record
    return [pscustomobject]@{ desktop=$context.desktop; restored=@($entries.name); currentApplicationPreserved=$true }
}
