[CmdletBinding()]
param([string]$WorkspaceRoot)

# These tests never use the real desktop, installed Codex, or an account profile.
# All manage.ps1 calls receive both sandbox paths and -SkipAppCheck.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manageScript = Join-Path $pluginRoot 'scripts\manage.ps1'
$manifestPath = Join-Path $pluginRoot 'payload-manifest.json'
if (-not $WorkspaceRoot) {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $pluginRoot '..\..'))
    $repositoryParent = Split-Path $repositoryRoot -Parent
    if ((Split-Path $repositoryParent -Leaf) -eq 'outputs') {
        $WorkspaceRoot = Split-Path $repositoryParent -Parent
    } else {
        $WorkspaceRoot = $repositoryRoot
    }
}
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
$workRoot = Join-Path $WorkspaceRoot 'work'
$testRoot = Join-Path $workRoot ('qa-plugin-install-' + [guid]::NewGuid().ToString('N'))
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$explorerExe = Join-Path $env:WINDIR 'explorer.exe'
$notepadExe = Join-Path $env:WINDIR 'System32\notepad.exe'
$officialArguments = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
$shortcutName = '守岸人 Codex.lnk'
$script:scenarioResults = New-Object 'System.Collections.Generic.List[object]'
$script:invocations = New-Object 'System.Collections.Generic.List[object]'
$script:callNumber = 0
$script:ws = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-SandboxPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $testRoot.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing a test operation outside its dedicated directory: ' + $full)
    }
    return $full
}

function Native-Argument([string]$Value) {
    # Windows paths cannot contain quotes. Test paths are full paths without a
    # trailing separator, so this is sufficient without a shell or expression.
    if ($Value.IndexOf('"') -ge 0 -or $Value.EndsWith('\')) { throw 'Unsupported test argument.' }
    return '"' + $Value + '"'
}

function New-ScenarioPaths([string]$Name) {
    $root = Assert-SandboxPath (Join-Path $testRoot $Name)
    $desktop = Join-Path $root 'desktop'
    $destination = Join-Path $root 'installation'
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    return [pscustomobject]@{ root = $root; desktop = $desktop; destination = $destination }
}

function New-TestShortcut([string]$Path, [string]$Target, [string]$Arguments = '') {
    $Path = Assert-SandboxPath $Path
    $link = $script:ws.CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.Arguments = $Arguments
    $link.Description = 'Isolated Shorekeeper installation lifecycle test'
    $link.WorkingDirectory = Split-Path $Target -Parent
    $link.Save()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
}

function Get-TestShortcut([string]$Path) {
    $Path = Assert-SandboxPath $Path
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) ('Missing shortcut: ' + $Path)
    $link = $script:ws.CreateShortcut($Path)
    try {
        return [pscustomobject]@{ target = $link.TargetPath; arguments = $link.Arguments }
    } finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    }
}

function File-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-LauncherShortcut([string]$Path, [string]$Destination) {
    $shortcut = Get-TestShortcut $Path
    $expected = [IO.Path]::GetFullPath((Join-Path $Destination 'Shorekeeper-Codex.exe'))
    Assert-True ([string]::Equals([IO.Path]::GetFullPath($shortcut.target), $expected, [StringComparison]::OrdinalIgnoreCase)) ('Shortcut does not use the installed launcher: ' + $Path)
    Assert-True (Test-Path -LiteralPath $expected -PathType Leaf) 'The shortcut target was not installed.'
}

function Resolve-PayloadPath([string]$Base, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw ('Unsafe payload path in test input: ' + $Relative) }
    $full = [IO.Path]::GetFullPath((Join-Path $Base $Relative.Replace('/', '\')))
    if (-not $full.StartsWith([IO.Path]::GetFullPath($Base).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Payload path escaped its root.' }
    return $full
}

function Read-Manifest([string]$Root) {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'payload-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.schemaVersion -eq 1) 'Unexpected payload manifest schemaVersion.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$manifest.productId)) 'Missing payload productId.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$manifest.version)) 'Missing payload version.'
    Assert-True (@($manifest.files).Count -gt 0) 'The payload manifest has no files.'
    return $manifest
}

function Assert-PayloadInstalled([string]$SourceRoot, [string]$Destination) {
    $manifest = Read-Manifest $SourceRoot
    foreach ($entry in $manifest.files) {
        $file = Resolve-PayloadPath $Destination ([string]$entry.path)
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) ('Missing installed payload: ' + $entry.path)
        Assert-True ((Get-Item -LiteralPath $file).Length -eq [long]$entry.size) ('Installed size differs: ' + $entry.path)
        Assert-True ((File-Hash $file) -eq [string]$entry.sha256) ('Installed hash differs: ' + $entry.path)
    }
}

function Assert-PayloadRemoved([string]$SourceRoot, [string]$Destination) {
    $manifest = Read-Manifest $SourceRoot
    foreach ($entry in $manifest.files) {
        $file = Resolve-PayloadPath $Destination ([string]$entry.path)
        Assert-True (-not (Test-Path -LiteralPath $file -PathType Leaf)) ('Uninstall left managed payload: ' + $entry.path)
    }
}

function Invoke-Manage {
    param(
        [ValidateSet('Install', 'Diagnose', 'Uninstall')][string]$Action,
        [object]$Paths,
        [switch]$ReplaceOfficial,
        [switch]$ExpectFailure,
        [string]$SourceRoot = $pluginRoot,
        [string]$EntryScript
    )
    $destination = Assert-SandboxPath $Paths.destination
    $desktop = Assert-SandboxPath $Paths.desktop
    $entry = if ($EntryScript) { Assert-SandboxPath $EntryScript } else { Join-Path $SourceRoot 'scripts\manage.ps1' }
    Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) ('Missing management entry: ' + $entry)
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $entry, '-Action', $Action, '-Destination', $destination, '-DesktopPath', $desktop, '-SkipAppCheck')
    if ($ReplaceOfficial) { $arguments += '-ReplaceOfficial' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $powershellExe
    $start.Arguments = (($arguments | ForEach-Object { Native-Argument ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $Paths.root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            # This is only the PowerShell process created immediately above.
            $process.Kill()
            $process.WaitForExit()
            throw 'The isolated management subprocess timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $watch.Stop()
        $process.Dispose()
    }
    $script:callNumber++
    $trace = Join-Path $testRoot ('call-{0:d2}-{1}.json' -f $script:callNumber, $Action.ToLowerInvariant())
    $result = [pscustomobject]@{ action = $Action; entry = $entry; destination = $destination; desktop = $desktop; source = $SourceRoot; replaceOfficial = [bool]$ReplaceOfficial; exitCode = $exitCode; elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1); stdout = $stdout; stderr = $stderr }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $trace -Encoding UTF8
    $script:invocations.Add($result)
    if ($ExpectFailure) {
        Assert-True ($exitCode -ne 0) ('Expected a nonzero exit for protected ' + $Action + ', received success. Trace: ' + $trace)
    } else {
        Assert-True ($exitCode -eq 0) ($Action + ' failed with exit ' + $exitCode + '. Trace: ' + $trace)
    }
    return $result
}

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $result = [pscustomobject]@{ name = $Name; passed = $true; elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1); error = $null }
        Write-Host ('PASS ' + $Name)
    } catch {
        $result = [pscustomobject]@{ name = $Name; passed = $false; elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1); error = $_.Exception.Message }
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    } finally {
        $watch.Stop()
    }
    $script:scenarioResults.Add($result)
}

function Copy-TestPlugin([string]$Path) {
    $Path = Assert-SandboxPath $Path
    Copy-Item -LiteralPath $pluginRoot -Destination $Path -Recurse
    return $Path
}

try {
    Assert-True (Test-Path -LiteralPath $manageScript -PathType Leaf) 'scripts/manage.ps1 is not ready; no test action was run.'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'payload-manifest.json is not ready; no test action was run.'
    Assert-True (Test-Path -LiteralPath $powershellExe -PathType Leaf) 'Windows PowerShell 5.1 is required.'
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $script:ws = New-Object -ComObject WScript.Shell
    Write-Host ('Isolated test directory: ' + $testRoot)

    Invoke-Scenario 'manifest-integrity' {
        $manifest = Read-Manifest $pluginRoot
        $seen = @{}
        foreach ($entry in $manifest.files) {
            $name = ([string]$entry.path).Replace('\', '/').ToLowerInvariant()
            Assert-True (-not $seen.ContainsKey($name)) ('Duplicate manifest file: ' + $entry.path)
            $seen[$name] = $true
            Assert-True ([string]$entry.sha256 -match '^[a-fA-F0-9]{64}$') ('Invalid SHA256: ' + $entry.path)
            $file = Resolve-PayloadPath (Join-Path $pluginRoot 'payload') ([string]$entry.path)
            Assert-True (Test-Path -LiteralPath $file -PathType Leaf) ('Source payload is missing: ' + $entry.path)
            Assert-True ((Get-Item -LiteralPath $file).Length -eq [long]$entry.size) ('Source payload size differs: ' + $entry.path)
            Assert-True ((File-Hash $file) -eq [string]$entry.sha256) ('Source payload hash differs: ' + $entry.path)
            Assert-True ($name -notmatch '(^|/)(runtime|shortcut-backup)(/|$)|last-launch\.log$|\.lnk$') ('Private state was included in the payload: ' + $entry.path)
        }
    }

    Invoke-Scenario 'default-install-is-idempotent-and-keeps-unrelated-files' {
        $paths = New-ScenarioPaths 'default install with spaces'
        $chatgpt = Join-Path $paths.desktop 'ChatGPT.lnk'
        $codex = Join-Path $paths.desktop 'Codex.lnk'
        New-TestShortcut $chatgpt $explorerExe $officialArguments
        New-TestShortcut $codex $notepadExe
        $chatgptHash = File-Hash $chatgpt
        $codexHash = File-Hash $codex
        $null = Invoke-Manage -Action Install -Paths $paths
        Assert-PayloadInstalled $pluginRoot $paths.destination
        # Unknown files and even empty user directories created after ownership
        # was established must survive repeat installation and removal.
        $unrelated = Join-Path $paths.destination 'keep-my-note.txt'
        $unrelatedEmpty = Join-Path $paths.destination 'keep-my-empty-directory'
        New-Item -ItemType Directory -Path $unrelatedEmpty -Force | Out-Null
        [IO.File]::WriteAllText($unrelated, 'An unknown destination file must survive installation and removal.')
        $unrelatedHash = File-Hash $unrelated
        Assert-LauncherShortcut (Join-Path $paths.desktop $shortcutName) $paths.destination
        Assert-True ((File-Hash $chatgpt) -eq $chatgptHash) 'Default installation changed an official shortcut.'
        Assert-True ((File-Hash $codex) -eq $codexHash) 'Default installation changed an unrelated same-name shortcut.'
        $null = Invoke-Manage -Action Install -Paths $paths
        Assert-PayloadInstalled $pluginRoot $paths.destination
        $null = Invoke-Manage -Action Diagnose -Paths $paths
        Assert-PayloadInstalled $pluginRoot $paths.destination
        Assert-True ((File-Hash $unrelated) -eq $unrelatedHash) 'An install or diagnosis changed an unrelated file.'
        $null = Invoke-Manage -Action Uninstall -Paths $paths
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'Uninstall did not remove its added shortcut.'
        Assert-True ((File-Hash $chatgpt) -eq $chatgptHash) 'Uninstall changed the original official shortcut.'
        Assert-True ((File-Hash $codex) -eq $codexHash) 'Uninstall changed the unrelated shortcut.'
        Assert-True ((File-Hash $unrelated) -eq $unrelatedHash) 'Uninstall removed or changed an unknown destination file.'
        Assert-True (Test-Path -LiteralPath $unrelatedEmpty -PathType Container) 'Uninstall removed a user-created empty directory.'
        Assert-PayloadRemoved $pluginRoot $paths.destination
    }

    Invoke-Scenario 'unowned-nonempty-destination-is-protected' {
        $paths = New-ScenarioPaths 'unowned destination'
        New-Item -ItemType Directory -Path $paths.destination -Force | Out-Null
        $file = Join-Path $paths.destination 'preexisting-note.txt'
        [IO.File]::WriteAllText($file, 'This directory is not owned by this product.')
        $originalHash = File-Hash $file
        $null = Invoke-Manage -Action Install -Paths $paths -ExpectFailure
        Assert-True ((File-Hash $file) -eq $originalHash) 'A rejected install changed an unowned destination file.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'A rejected install created a shortcut.'
    }

    Invoke-Scenario 'explicit-replacement-upgrade-restores-original-shortcuts' {
        $paths = New-ScenarioPaths 'replacement and upgrade'
        $stage = Copy-TestPlugin (Join-Path $paths.root 'staged plugin')
        $originals = @{}
        foreach ($name in @('ChatGPT.lnk', 'Codex.lnk')) {
            $file = Join-Path $paths.desktop $name
            New-TestShortcut $file $explorerExe $officialArguments
            $originals[$name] = File-Hash $file
        }
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial -SourceRoot $stage
        foreach ($name in $originals.Keys) { Assert-LauncherShortcut (Join-Path $paths.desktop $name) $paths.destination }
        Assert-PayloadInstalled $stage $paths.destination

        # Build a real, self-consistent synthetic upgrade only inside the QA copy.
        $manifest = Read-Manifest $stage
        $entry = @($manifest.files | Where-Object { ([string]$_.path).Replace('\', '/') -eq 'overlay.js' })
        Assert-True ($entry.Count -eq 1) 'The upgrade test requires the overlay.js manifest entry.'
        $file = Resolve-PayloadPath (Join-Path $stage 'payload') ([string]$entry[0].path)
        $oldHash = File-Hash $file
        [IO.File]::AppendAllText($file, [Environment]::NewLine + '/* isolated installation upgrade test */' + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $entry[0].sha256 = File-Hash $file
        $entry[0].size = (Get-Item -LiteralPath $file).Length
        $manifest.version = '999.0.0'
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $stage 'payload-manifest.json') -Encoding UTF8
        Assert-True ((File-Hash $file) -ne $oldHash) 'The synthetic upgrade did not change its payload.'
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial -SourceRoot $stage
        Assert-PayloadInstalled $stage $paths.destination
        foreach ($name in $originals.Keys) { Assert-LauncherShortcut (Join-Path $paths.desktop $name) $paths.destination }
        $null = Invoke-Manage -Action Uninstall -Paths $paths -SourceRoot $stage
        foreach ($name in $originals.Keys) {
            Assert-True ((File-Hash (Join-Path $paths.desktop $name)) -eq $originals[$name]) ('Upgrade lost the original shortcut backup: ' + $name)
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'Uninstall left its added shortcut after upgrade.'
        Assert-PayloadRemoved $stage $paths.destination
    }

    Invoke-Scenario 'modified-added-shortcut-blocks-uninstall' {
        $paths = New-ScenarioPaths 'modified added shortcut'
        $null = Invoke-Manage -Action Install -Paths $paths
        $file = Join-Path $paths.desktop $shortcutName
        New-TestShortcut $file $notepadExe
        $modifiedHash = File-Hash $file
        $null = Invoke-Manage -Action Uninstall -Paths $paths -ExpectFailure
        Assert-True ((File-Hash $file) -eq $modifiedHash) 'Uninstall overwrote a user-modified shortcut.'
        Assert-PayloadInstalled $pluginRoot $paths.destination
    }

    Invoke-Scenario 'modified-replaced-shortcut-blocks-uninstall' {
        $paths = New-ScenarioPaths 'modified replaced shortcut'
        $file = Join-Path $paths.desktop 'ChatGPT.lnk'
        New-TestShortcut $file $explorerExe $officialArguments
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial
        New-TestShortcut $file $notepadExe
        $modifiedHash = File-Hash $file
        $added = Join-Path $paths.desktop $shortcutName
        $addedHash = File-Hash $added
        $null = Invoke-Manage -Action Uninstall -Paths $paths -ExpectFailure
        Assert-True ((File-Hash $file) -eq $modifiedHash) 'Uninstall replaced a user-modified official-name shortcut.'
        Assert-True ((File-Hash $added) -eq $addedHash) 'A blocked uninstall partially removed its other shortcut.'
        Assert-PayloadInstalled $pluginRoot $paths.destination
    }

    Invoke-Scenario 'same-name-unofficial-shortcut-is-protected' {
        $paths = New-ScenarioPaths 'unofficial same name'
        $file = Join-Path $paths.desktop 'ChatGPT.lnk'
        New-TestShortcut $file $notepadExe
        $originalHash = File-Hash $file
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial -ExpectFailure
        Assert-True ((File-Hash $file) -eq $originalHash) 'An unverified same-name shortcut was replaced.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'A rejected install partially added its shortcut.'
    }

    Invoke-Scenario 'corrupt-payload-is-rejected-before-shortcut-changes' {
        $paths = New-ScenarioPaths 'corrupt payload'
        $stage = Copy-TestPlugin (Join-Path $paths.root 'staged plugin')
        $file = Join-Path $paths.desktop 'ChatGPT.lnk'
        New-TestShortcut $file $explorerExe $officialArguments
        $originalHash = File-Hash $file
        $manifest = Read-Manifest $stage
        $entry = @($manifest.files)[0]
        $corrupt = Resolve-PayloadPath (Join-Path $stage 'payload') ([string]$entry.path)
        [IO.File]::AppendAllText($corrupt, 'invalid-test-bytes')
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial -ExpectFailure -SourceRoot $stage
        Assert-True ((File-Hash $file) -eq $originalHash) 'A corrupt-payload install changed an original shortcut.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'A corrupt-payload install partially added a shortcut.'
    }

    Invoke-Scenario 'installed-management-entry-uninstalls-without-plugin-source' {
        $paths = New-ScenarioPaths 'standalone uninstall'
        $stage = Copy-TestPlugin (Join-Path $paths.root 'staged plugin')
        $file = Join-Path $paths.desktop 'ChatGPT.lnk'
        New-TestShortcut $file $explorerExe $officialArguments
        $originalHash = File-Hash $file
        $null = Invoke-Manage -Action Install -Paths $paths -ReplaceOfficial -SourceRoot $stage
        $standalone = Join-Path $paths.destination 'launcher\manage.ps1'
        Assert-True (Test-Path -LiteralPath $standalone -PathType Leaf) 'The installed management entry is missing.'
        $offline = Assert-SandboxPath (Join-Path $paths.root 'plugin source offline')
        $stage = Assert-SandboxPath $stage
        Move-Item -LiteralPath $stage -Destination $offline
        $null = Invoke-Manage -Action Uninstall -Paths $paths -EntryScript $standalone
        Assert-True ((File-Hash $file) -eq $originalHash) 'Standalone uninstall did not restore the original shortcut.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.desktop $shortcutName))) 'Standalone uninstall left its added shortcut.'
        Assert-PayloadRemoved $offline $paths.destination
    }

    $failures = @($script:scenarioResults | Where-Object { -not $_.passed })
    $report = [pscustomobject]@{
        schemaVersion = 1
        test = 'isolated-installation-lifecycle'
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        testRoot = $testRoot
        actualDesktopUsed = $false
        actualApplicationStarted = $false
        appChecksSkipped = $true
        passed = ($failures.Count -eq 0)
        scenarios = @($script:scenarioResults.ToArray())
        invocationCount = $script:invocations.Count
        note = 'QA directories and per-call output are retained for inspection. No Preview action was invoked.'
    }
    $reportPath = Join-Path $testRoot 'installation-lifecycle-report.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host ('Report: ' + $reportPath)
    if ($failures.Count -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    if ($null -ne $script:ws) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:ws) }
}
