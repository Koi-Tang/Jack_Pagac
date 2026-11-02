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

function Test-OfficialRoot([string]$Root) {
    if (-not $Root) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if (-not $full.StartsWith($windowsApps + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ((Split-Path $full -Leaf) -notmatch '^OpenAI\.Codex_[0-9.]+_(x64|arm64)__2p2nqsd0c76g0$') { return $false }
        [xml]$manifest = Get-Content -LiteralPath (Join-Path $full 'AppxManifest.xml') -Raw
        return ($manifest.Package.Identity.Name -eq 'OpenAI.Codex' -and $manifest.Package.Identity.Publisher -eq $officialPublisher -and (Test-Path -LiteralPath (Join-Path $full 'app\ChatGPT.exe')))
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

function Get-VerifiedListener([string]$ExpectedExe) {
    $statusPath = $runPrefix + '.owner.json'
    $arguments = '--verify-port ' + $port + ' "' + $ExpectedExe + '" "' + $statusPath + '" 0'
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

function Get-RunningOfficialProcesses {
    foreach ($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and (Test-OfficialRoot (Split-Path (Split-Path $process.Path -Parent) -Parent))) { $process }
        } catch {}
    }
}

function Show-LauncherError([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, '守岸人 · Codex', 'OK', 'Information')
}

try {
    $root = Find-OfficialRoot
    $exe = Join-Path $root 'app\ChatGPT.exe'
    if ($Original -and -not $Diagnose) {
        # A clean official launch after exiting the current session restores
        # the original appearance. This never closes a running session.
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $aumid) | Out-Null
        exit 0
    }
    $nodeCandidates = @(
        (Join-Path $root 'app\resources\cua_node\bin\node.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
    )
    $node = $nodeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $node) { throw '未找到 Codex 自带的 Node.js 运行时，请更新官方客户端后重试。' }
    if ($Diagnose) {
        [pscustomobject]@{
            officialRoot = $root
            executable = $exe
            node = $node
            profile = 'official default (no user-data-dir override)'
            overlayPresent = (Test-Path -LiteralPath (Join-Path $base 'overlay.js'))
            videoPresent = (Test-Path -LiteralPath (Join-Path $base 'assets\startup.mp4'))
            startupGatePresent = (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'StartupGate.exe'))
            port = $port
            mode = 'read-only; no application started or changed'
        } | ConvertTo-Json
        exit 0
    }
    foreach ($required in @('overlay.js', 'assets\startup.mp4', 'launcher\inject.mjs', 'launcher\StartupGate.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $base $required))) { throw ('缺少项目文件：' + $required + '。请完整解压全部文件。') }
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
    if (-not $mutexHeld) { [IO.File]::AppendAllText($runLog, '{"event":"another-startup-in-progress"}'); exit 0 }
    $listeners = @(Get-VerifiedListener $exe)
    if ($listeners.Count -eq 0) {
        if (-not $QaProfile -and @(Get-RunningOfficialProcesses).Count -gt 0) {
            throw 'Codex 已在运行，但当前窗口没有动画接口。请先保存工作，从系统托盘完全退出 Codex，再双击「守岸人启动 Codex.exe」。本启动器不会关闭或终止你的会话。'
        }
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
    }
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-VerifiedListener $exe).Count -gt 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 80
    }
    if (-not $ready) { throw 'Codex 尚未开放动画接口。客户端会继续运行；请从托盘完全退出后重试，或使用原版入口。' }
    $log = Join-Path $base 'launcher\last-launch.log'
    # The helper verifies the listening process again before loading the layer.
    $injectArguments = @((Join-Path $PSScriptRoot 'inject.mjs'), '--port', [string]$port, '--expected-exe', $exe, '--run-prefix', $runPrefix)
    if ($gateSignal) {
        $pidFile = $gateSignal + '.pid'
        if (-not (Test-Path -LiteralPath $pidFile)) { throw '启动窗口控制器未能创建就绪信号；官方窗口将正常显示。' }
        $launchedPid = [int]([IO.File]::ReadAllText($pidFile).Trim())
        if (@(Get-VerifiedListener $exe | Where-Object { $_.OwningProcess -ne $launchedPid }).Count -gt 0) { throw '启动端口未属于本次新建实例，已保留现有会话。' }
        $injectArguments += @('--ready-file', $gateSignal, '--expected-pid', [string]$launchedPid)
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $node
    $info.Arguments = (($injectArguments | ForEach-Object { Native-Argument ([string]$_) }) -join ' ')
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
    $exitCode = $process.ExitCode
    $resultPath = $runPrefix + '.result.json'
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    Copy-Item -LiteralPath $runLog -Destination $log -Force
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
    if ($mutexHeld -and $startupMutex) { try { $startupMutex.ReleaseMutex() } catch {} }
    if ($startupMutex) { $startupMutex.Dispose() }
}
