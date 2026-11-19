#Requires -Version 5.1
param([switch]$Diagnose, [switch]$Original, [string]$QaProfile, [switch]$NoDialog)
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$port = 19341
$officialPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$windowsApps = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'WindowsApps'))
$aumid = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$gateSignal = $null
$runPrefix = $null
$runLog = $null
$startupMutex = $null
$mutexHeld = $false
$officialRootCache = @{}

function Test-OfficialRoot([string]$Root) {
    if (-not $Root) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($officialRootCache.ContainsKey($full)) { return $officialRootCache[$full] }
        if (-not $full.StartsWith($windowsApps + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ((Split-Path $full -Leaf) -notmatch '^OpenAI\.Codex_[0-9.]+_(x64|arm64)__2p2nqsd0c76g0$') { return $false }
        [xml]$manifest = Get-Content -LiteralPath (Join-Path $full 'AppxManifest.xml') -Raw
        $verified = ($manifest.Package.Identity.Name -eq 'OpenAI.Codex' -and $manifest.Package.Identity.Publisher -eq $officialPublisher -and (Test-Path -LiteralPath (Join-Path $full 'app\ChatGPT.exe')))
        $officialRootCache[$full] = $verified
        return $verified
    } catch { return $false }
}

function Find-OfficialRoot {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue)) {
        if ($package.InstallLocation) { $candidates.Add([string]$package.InstallLocation) }
    }
    foreach ($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path) { $candidates.Add((Split-Path (Split-Path $process.Path -Parent) -Parent)) }
        } catch {}
    }
    if ($candidates.Count -eq 0) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'OpenAI.Codex_*__2p2nqsd0c76g0' -ErrorAction SilentlyContinue)) { $candidates.Add($folder.FullName) }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique | Sort-Object { try { [version]((Split-Path $_ -Leaf) -split '_')[1] } catch { [version]'0.0' } } -Descending)) {
        if (Test-OfficialRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw '未找到已安装的 Microsoft Store 版 Codex。请先安装并打开一次官方 Codex。'
}

function Get-VerifiedListener([string]$ExpectedExe, [int]$ExpectedProcessId = 0) {
    $statusPath = $runPrefix + '.owner.json'
    $arguments = '--verify-port ' + $port + ' ' + (Native-Argument $ExpectedExe) + ' ' + (Native-Argument $statusPath) + ' ' + $ExpectedProcessId
    $query = Start-Process -FilePath (Join-Path $PSScriptRoot 'StartupGate.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    if (-not (Test-Path -LiteralPath $statusPath)) { throw 'native-owner-result-missing' }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if ($query.ExitCode -eq 3 -and $status.code -eq 'no-listener') { return @() }
    if ($query.ExitCode -ne 0 -or -not $status.ok) { throw ('端口身份校验失败：' + $status.code) }
    return [pscustomobject]@{ OwningProcess = [int]$status.pid; LocalAddress = '127.0.0.1'; LocalPort = $port }
}
function Native-Argument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Write-LaunchEvent([string]$Event, [hashtable]$Fields = @{}) {
    $record = @{ event=$Event; time=(Get-Date).ToUniversalTime().ToString('o') }
    foreach ($key in $Fields.Keys) { $record[$key]=$Fields[$key] }
    [IO.File]::AppendAllText($runLog, (($record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine))
}
function Complete-Coalesced([int]$ExistingProcessId, [string]$Reason) {
    Write-LaunchEvent 'startup-coalesced' @{ pid=$ExistingProcessId; reason=$Reason; animationStarted=$false }
    [pscustomobject]@{ ok=$true; code='startup-coalesced'; pid=$ExistingProcessId; reason=$Reason; animationStarted=$false } | ConvertTo-Json | Set-Content -LiteralPath ($runPrefix + '.result.json') -Encoding UTF8
}
function Complete-ResumedExisting($Existing, $Status, [string]$Transport) {
    [pscustomobject]@{ ok=$true; code='resumed-existing'; pid=$Existing.Id; transport=$Transport; foreground=$Status; animationStarted=$false } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ($runPrefix + '.result.json') -Encoding UTF8
    Write-LaunchEvent 'resumed-existing' @{ pid=$Existing.Id; transport=$Transport; animationStarted=$false }
}
function Get-WindowsArguments([string]$CommandLine) {
    if (-not ('Shorekeeper.CommandLine' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Shorekeeper {
    public static class CommandLine {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr CommandLineToArgvW(string text, out int count);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Split(string text) {
            int count; IntPtr memory=CommandLineToArgvW(text,out count);
            if(memory==IntPtr.Zero)throw new InvalidOperationException("command-line-parse-failed");
            try { var result=new string[count];for(int i=0;i<count;i++)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));return result; }
            finally { LocalFree(memory); }
        }
    }
}
'@
    }
    return [Shorekeeper.CommandLine]::Split($CommandLine)
}
function Test-ProfileArguments([string[]]$Arguments) {
    $profiles = @()
    for ($index=1; $index -lt $Arguments.Count; $index++) {
        $argument=$Arguments[$index]
        if ($argument -ieq '--type' -or $argument.StartsWith('--type=', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($argument -ieq '--user-data-dir') {
            $index++
            if ($index -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace($Arguments[$index])) { throw 'running-process-profile-ambiguous' }
            $profiles += $Arguments[$index]
        } elseif ($argument.StartsWith('--user-data-dir=', [StringComparison]::OrdinalIgnoreCase)) { $profiles += $argument.Substring(16) }
    }
    if ($profiles.Count -gt 1 -or ($profiles.Count -eq 1 -and [string]::IsNullOrWhiteSpace($profiles[0]))) { throw 'running-process-profile-ambiguous' }
    if ($QaProfile) { return $profiles.Count -eq 1 -and [string]::Equals([IO.Path]::GetFullPath($profiles[0]).TrimEnd('\'), $QaProfile.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
    # The production entry uses the official default profile without overrides.
    # Explicit profile roots belong to QA/other isolated instances, not this entry.
    return $profiles.Count -eq 0
}
function Get-RunningOfficialProcesses {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $candidates = @()
    foreach ($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $session -or -not $process.Path) { continue }
            if (Test-OfficialRoot (Split-Path (Split-Path $process.Path -Parent) -Parent)) {
                $candidates += [pscustomobject]@{ Id=$process.Id; Exe=$process.Path; Started=$process.StartTime.ToUniversalTime().Ticks }
            }
        } catch {}
    }
    if (-not $candidates.Count) { return }
    # Query metadata once; never log or read account files from a profile.
    $metadata = @(Get-CimInstance -ClassName Win32_Process -Filter ("Name='ChatGPT.exe' AND SessionId=" + $session) -ErrorAction Stop)
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($candidate in $candidates) {
        $item = @($metadata | Where-Object { $_.ProcessId -eq $candidate.Id }) | Select-Object -First 1
        if (-not $item) { continue } # It exited during the snapshot.
        if ([string]::IsNullOrWhiteSpace($item.CommandLine)) { throw 'running-process-command-line-unavailable' }
        if (-not (Test-ProfileArguments (Get-WindowsArguments $item.CommandLine))) { continue }
        $owner = Invoke-CimMethod -InputObject $item -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) { throw 'running-process-owner-unavailable' }
        if ($owner.Sid -ne $currentSid) { continue }
        $candidate
    }
}
function Test-ExistingIdentity($Existing) {
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Existing.Id)
        return -not $process.HasExited -and $process.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId -and $process.StartTime.ToUniversalTime().Ticks -eq $Existing.Started -and [string]::Equals($process.MainModule.FileName, $Existing.Exe, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Find-Node([string]$Executable) {
    $appRoot = Split-Path (Split-Path $Executable -Parent) -Parent
    foreach ($path in @((Join-Path $appRoot 'app\resources\cua_node\bin\node.exe'),(Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
}
function Invoke-NativeWindow([string]$Mode, $Existing) {
    $statusPath = $runPrefix + '.foreground-check.json'
    $arguments = @($Mode, [string]$Existing.Id, $Existing.Exe, $statusPath, [string]$Existing.Started)
    $query = Start-Process -FilePath (Join-Path $PSScriptRoot 'StartupGate.exe') -ArgumentList (($arguments | ForEach-Object { Native-Argument $_ }) -join ' ') -WindowStyle Hidden -PassThru -Wait
    if (-not (Test-Path -LiteralPath $statusPath)) { throw 'native-window-result-missing' }
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $status | Add-Member -NotePropertyName exitCode -NotePropertyValue $query.ExitCode -Force
    return $status
}
function Invoke-Injector([string]$Node, [string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Node
    $info.Arguments = (($Arguments | ForEach-Object { Native-Argument ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [IO.File]::AppendAllText($runLog, $stdout.Result + $stderr.Result)
    $resultPath = $runPrefix + '.result.json'
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    Copy-Item -LiteralPath $runLog -Destination (Join-Path $PSScriptRoot 'last-launch.log') -Force
    return [pscustomobject]@{ exitCode=$process.ExitCode; result=$result }
}
function Resume-Existing($Existing, $KnownStatus) {
    if (-not (Test-ExistingIdentity $Existing)) { return $false }
    Write-LaunchEvent 'existing-instance-detected' @{ pid=$Existing.Id; started=[string]$Existing.Started }
    $status = if ($KnownStatus) { $KnownStatus } else { Invoke-NativeWindow '--status' $Existing }
    if (-not $status.ok) {
        if (-not (Test-ExistingIdentity $Existing)) { return $false }
        throw ('现有窗口身份确认失败：' + $status.code)
    }
    if ($status.hwnd -ne '0' -and $status.alpha -eq 0) {
        # A surviving gate/watchdog owns opacity. Do not force it visible.
        Complete-Coalesced $Existing.Id 'cold-gate-still-preparing'
        return $true
    }
    if ($status.hwnd -ne '0' -and $status.visible -and -not $status.iconic -and $status.alpha -gt 0) {
        # A healthy visible main window needs no browser-state synchronization.
        # In particular, a second click during playback preserves its timeline.
        if (-not $status.foreground) { $status = Invoke-NativeWindow '--activate' $Existing }
        if ($status.ok -and $status.visible -and -not $status.iconic -and $status.foreground -and $status.alpha -gt 0) {
            Complete-ResumedExisting $Existing $status 'native-visible'
            return $true
        }
    }
    $node = Find-Node $Existing.Exe
    if ($node -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'inject.mjs'))) {
        try {
            $listeners = @(Get-VerifiedListener $Existing.Exe $Existing.Id)
            if ($listeners.Count -gt 0) {
                $arguments = @((Join-Path $PSScriptRoot 'inject.mjs'),'--activate-only','--port',[string]$port,'--expected-exe',$Existing.Exe,'--expected-pid',[string]$Existing.Id,'--expected-start-ticks',[string]$Existing.Started,'--run-prefix',$runPrefix)
                $response = Invoke-Injector $node $arguments
                if ($response.result -and $response.result.ok -and $response.result.code -eq 'resumed-existing') {
                    Write-LaunchEvent 'resumed-existing' @{ pid=$Existing.Id; transport='verified-cdp'; animationStarted=$false }
                    return $true
                }
                Write-LaunchEvent 'activation-cdp-unavailable' @{ code=$(if ($response.result) { $response.result.code } else { 'activation-no-result' }) }
            }
        } catch { Write-LaunchEvent 'activation-cdp-unavailable' @{ code=$_.Exception.Message } }
    }
    if (-not (Test-ExistingIdentity $Existing)) { return $false }
    $status = Invoke-NativeWindow '--activate' $Existing
    if ($status.code -eq 'startup-in-progress') {
        Complete-Coalesced $Existing.Id 'cold-gate-still-preparing'
        return $true
    }
    if (-not ($status.ok -and $status.visible -and -not $status.iconic -and $status.foreground -and $status.alpha -gt 0) -and -not $QaProfile -and (Test-ExistingIdentity $Existing)) {
        # Only ask the official application to recreate/restore its tray window
        # if native recovery did not succeed. Never invoke default-profile
        # activation from isolated QA, or enable debugging on an existing app.
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $aumid) | Out-Null
        $status = Invoke-NativeWindow '--activate' $Existing
    }
    if ($status.ok -and $status.visible -and -not $status.iconic -and $status.foreground -and $status.alpha -gt 0) {
        Complete-ResumedExisting $Existing $status 'official-native'
        return $true
    }
    if (-not (Test-ExistingIdentity $Existing)) { return $false }
    throw ('现有 Codex 窗口恢复未确认（' + $status.code + '）。会话已保留；未重新播放动画。')
}
function Resume-RunningInstance {
    $instances = @(Get-RunningOfficialProcesses)
    if (-not $instances.Count) { return $false }
    # Prefer an actual main HWND rather than the first Chromium process.
    $ranked = foreach ($instance in $instances) {
        $status = Invoke-NativeWindow '--status' $instance
        [pscustomobject]@{ instance=$instance; status=$status; hasWindow=($status.ok -and $status.hwnd -ne '0'); foreground=$status.foreground }
    }
    foreach ($choice in @($ranked | Sort-Object hasWindow,foreground -Descending)) {
        if (Resume-Existing $choice.instance $choice.status) { return $true }
    }
    return $false
}

function Show-LauncherError([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, '守岸人 · Codex', 'OK', 'Information')
}

try {
    $root = Find-OfficialRoot
    $exe = Join-Path $root 'app\ChatGPT.exe'
    if ($Original -and $QaProfile) { throw 'QA may not invoke the official default-profile activation entry.' }
    if ($Original -and -not $Diagnose) {
        # A clean official launch after exiting the current session restores
        # the original appearance. This never closes a running session.
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $aumid) | Out-Null
        exit 0
    }
    if ($Diagnose) {
        [pscustomobject]@{
            officialRoot = $root
            executable = $exe
            node = (Find-Node $exe)
            profile = 'official default (no user-data-dir override)'
            overlayPresent = (Test-Path -LiteralPath (Join-Path $base 'overlay.js'))
            videoPresent = (Test-Path -LiteralPath (Join-Path $base 'assets\startup.mp4'))
            startupGatePresent = (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'StartupGate.exe'))
            port = $port
            mode = 'read-only; no application started or changed'
        } | ConvertTo-Json
        exit 0
    }
    $runtime = Join-Path $PSScriptRoot 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $runPrefix = Join-Path $runtime ([guid]::NewGuid().ToString('N'))
    $runLog = $runPrefix + '.log'
    [IO.File]::WriteAllText($runLog, ('{"event":"launcher-start","time":"' + (Get-Date).ToUniversalTime().ToString('o') + '"}' + [Environment]::NewLine))
    if ($QaProfile) {
        $qaRoot = [IO.Path]::GetFullPath((Join-Path $base '..\..\work')).TrimEnd('\') + '\'
        $QaProfile = [IO.Path]::GetFullPath($QaProfile)
        if (-not $QaProfile.StartsWith($qaRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $QaProfile -Leaf) -notlike 'qa-*') { throw 'QA profile must be a dedicated qa-* directory under this workspace work directory.' }
        $port = 19342
    }
    $mutexName = 'Local\ShorekeeperCodexStartup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '-' + $port
    $startupMutex = New-Object Threading.Mutex($false, $mutexName)
    try { $mutexHeld = $startupMutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if (-not $mutexHeld) { Complete-Coalesced 0 'startup-lock-busy'; exit 0 }
    # The same lock protects process discovery and cold process creation. A
    # second click may only restore a prepared window, never bypass its gate.
    if (Resume-RunningInstance) { exit 0 }
    $node = Find-Node $exe
    if (-not $node) { throw '未找到 Codex 自带的 Node.js 运行时，请更新官方客户端后重试。' }
    foreach ($required in @('overlay.js', 'assets\startup.mp4', 'launcher\inject.mjs', 'launcher\StartupGate.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $base $required))) { throw ('缺少项目文件：' + $required + '。请完整解压全部文件。') }
    }
    $listeners = @(Get-VerifiedListener $exe)
    if ($listeners.Count -gt 0) {
        if (Resume-RunningInstance) { exit 0 }
        throw '现有动画端口未属于可确认的当前用户主窗口，已保留会话，未重新注入动画。'
    }
    if (Resume-RunningInstance) { exit 0 }
    # Owl's native profile layout differs from older Electron versions.
    # Let the official runtime select its existing profile; never redirect,
    # migrate or read account data to support a cosmetic startup layer.
    $arguments = '--remote-debugging-address=127.0.0.1 --remote-debugging-port=' + $port
    if ($QaProfile) { $arguments += ' --user-data-dir="' + $QaProfile + '"' }
    $gateSignal = $runPrefix
    $gateArguments = (Native-Argument $exe) + ' ' + (Native-Argument $arguments) + ' ' + (Native-Argument $gateSignal)
    # The gate creates the actual interactive app. It only controls that
    # new PID's initial opacity, and has an independent fail-open watchdog.
    Start-Process -FilePath (Join-Path $PSScriptRoot 'StartupGate.exe') -ArgumentList $gateArguments -WindowStyle Hidden | Out-Null
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-VerifiedListener $exe).Count -gt 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 80
    }
    if (-not $ready) { throw 'Codex 尚未开放动画接口。客户端会继续运行；请从托盘完全退出后重试，或使用原版入口。' }
    # The helper verifies the listening process again before loading the layer.
    $injectArguments = @((Join-Path $PSScriptRoot 'inject.mjs'), '--port', [string]$port, '--expected-exe', $exe, '--run-prefix', $runPrefix)
    if ($gateSignal) {
        $pidFile = $gateSignal + '.pid'
        if (-not (Test-Path -LiteralPath $pidFile)) { throw '启动窗口控制器未能创建就绪信号；官方窗口将正常显示。' }
        $launchedPid = [int]([IO.File]::ReadAllText($pidFile).Trim())
        if (@(Get-VerifiedListener $exe | Where-Object { $_.OwningProcess -ne $launchedPid }).Count -gt 0) { throw '启动端口未属于本次新建实例，已保留现有会话。' }
        $injectArguments += @('--ready-file', $gateSignal, '--expected-pid', [string]$launchedPid)
    }
    $response = Invoke-Injector $node $injectArguments
    $exitCode = $response.exitCode
    $result = $response.result
    if ($result -and ($result.ok -or $result.code -eq 'startup-cancelled')) {
        if ($exitCode -ne 0) { [IO.File]::AppendAllText($runLog, ('{"event":"nonfatal-exit-after-acknowledged-start","exitCode":' + $exitCode + '}' + [Environment]::NewLine)) }
        exit 0
    }
    $code = if ($result) { $result.code } else { 'injector-no-result-' + $exitCode }
    $reason = if ($result) { $result.message } else { '注入助手未返回启动确认。' }
    throw ('启动衔接未完成（' + $code + '）：' + $reason + '。客户端已保留。日志：' + $runLog)

} catch {
    if ($gateSignal) {
        # A failure always releases the independently guarded window. It never
        # terminates an application or modifies the user's current session.
        try { [IO.File]::WriteAllText($gateSignal + '.abort', 'launcher-failed') } catch {}
    }
    if ($runLog) { try { [IO.File]::AppendAllText($runLog, ('ERROR ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message + [Environment]::NewLine)); Copy-Item -LiteralPath $runLog -Destination (Join-Path $PSScriptRoot 'last-launch.log') -Force } catch {} }
    if ($Diagnose -or $NoDialog) { Write-Error $_.Exception.Message; exit 1 }
    Show-LauncherError $_.Exception.Message
    exit 1
}

finally {
    if ($runLog -and (Test-Path -LiteralPath $runLog)) { try { Copy-Item -LiteralPath $runLog -Destination (Join-Path $PSScriptRoot 'last-launch.log') -Force } catch {} }
    if ($mutexHeld -and $startupMutex) { try { $startupMutex.ReleaseMutex() } catch {} }
    if ($startupMutex) { $startupMutex.Dispose() }
}
