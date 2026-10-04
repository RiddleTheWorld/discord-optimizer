# Shared Discord measurement and before/after reporting.
# Dot-source it:  . "$PSScriptRoot\DiscordCommon.ps1"

$DiscordRoots = 'Discord', 'DiscordPTB', 'DiscordCanary' | ForEach-Object { Join-Path $env:LOCALAPPDATA $_ }

# Optional native modules. Keep: desktop_core, modules, utils, voice, media, erlpack, zstd, notifications.
# clips, hook (game capture for Go Live, Clips and the overlay) and game_sdk are only installed on demand.
# Left alone because their purpose isn't clear: discord_aegis, discord_sysimg, discord_wer.
# The background helper gets this list too (Optimize-Discord.ps1 builds it into DiscordGovernor.cs).
$DiscordOptionalModules = 'discord_krisp', 'discord_game_utils', 'discord_overlay2', 'discord_desktop_overlay',
                          'discord_rpc', 'discord_spellcheck', 'discord_cloudsync', 'discord_dispatch',
                          'discord_clips', 'discord_hook', 'discord_game_sdk_x86', 'discord_game_sdk_x64'

# Discord's app-<version> folders, oldest first. Anything that isn't a version (a stray "app-old") is ignored
# instead of breaking the sort.
function Get-AppFolders([string]$Root) {
    Get-ChildItem $Root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^app-\d+(\.\d+){1,3}$' } | Sort-Object { [version]($_.Name -replace '^app-') }
}

# Chromium language packs to keep: English plus the Windows display language
function Get-KeptLocales {
    $ui = Get-UICulture
    @('en-US', $ui.Name, $ui.TwoLetterISOLanguageName) | Select-Object -Unique
}

# What cache clearing can remove, grouped the way the window shows it. Discord rebuilds all of it.
# Cache = $true marks the areas the helper's automatic clearing manages (their $DiscordAreaPaths are built into it);
# the window's cache size and limit bar add up those areas, so "over limit" means auto-clear will act.
# Never touched: Local Storage, Session Storage, IndexedDB, WebStorage, Network, settings.json (your login and settings),
# and the GPU shader caches Windows and AMD share with every other app and game.
$DiscordCleanAreas = [ordered]@{
    Media     = @{ Label = 'Images and media';       Default = $true;  Cache = $true;  Hint = 'Pictures, GIFs, avatars and emoji Discord has shown you. The part that grows to gigabytes.' }
    Gpu       = @{ Label = 'GPU shader cache';       Default = $true;  Cache = $true;  Hint = "Discord's own copy, rebuilt automatically." }
    Logs      = @{ Label = 'Logs and crash reports'; Default = $true;  Cache = $true;  Hint = 'Discord logs, crash reports, voice debug recordings and Windows crash dumps.' }
    Browser   = @{ Label = 'Other browser data';     Default = $true;  Cache = $true;  Hint = 'Video playback stats and Chromium housekeeping databases.' }
    Updater   = @{ Label = 'Updater leftovers';      Default = $true;  Cache = $false; Hint = 'Old versions, partial update downloads and setup logs.' }
    Code      = @{ Label = 'Compiled scripts';       Default = $false; Cache = $false; Hint = 'Makes the next start slower. Only worth it if Discord misbehaves.' }
    Installer = @{ Label = 'Installer package';      Default = $false; Cache = $false; Hint = "Discord's updater doesn't appear to use it, but that's unverified." }
    Downloads = @{ Label = 'Downloaded installers';  Default = $false; Cache = $false; Hint = 'DiscordSetup.exe files in your Downloads folder. Not needed once Discord is installed.' }
}

# Folders and files under %APPDATA%\discord per area
$DiscordAreaPaths = @{
    Media   = 'Cache', 'Shared Dictionary', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'blob_storage'
    Gpu     = 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache'
    Logs    = 'logs', 'Crashpad', 'sentry', 'module_data\crashlogs'
    Browser = 'VideoDecodeStats', 'shared_proto_db', 'DIPS', 'DIPS-wal', 'SharedStorage', 'SharedStorage-wal'
    Code    = 'Code Cache'
}

# Every existing path each area would delete, across Discord, PTB and Canary
function Get-DiscordCleanTargets([string[]]$Areas = @($DiscordCleanAreas.Keys)) {
    $result = [ordered]@{}
    foreach ($a in $Areas) { $result[$a] = New-Object System.Collections.Generic.List[string] }
    foreach ($flavor in 'Discord', 'DiscordPTB', 'DiscordCanary') {
        $roaming = Join-Path $env:APPDATA $flavor.ToLower()
        $local = Join-Path $env:LOCALAPPDATA $flavor
        foreach ($a in $Areas) {
            foreach ($rel in $DiscordAreaPaths[$a]) {
                $p = Join-Path $roaming $rel
                if (Test-Path -LiteralPath $p) { $result[$a].Add($p) }
            }
        }
        if ($result.Contains('Logs') -and (Test-Path "$roaming\module_data")) {
            # Voice debug logs and diagnostic audio recordings land here and can get big
            Get-ChildItem "$roaming\module_data" -Recurse -File -Force -Include *.log, *.dmp, *.wav, *.pcm, *.aecdump -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike '*\module_data\crashlogs\*' } | ForEach-Object { $result.Logs.Add($_.FullName) }
        }
        if (-not (Test-Path $local)) { continue }
        $apps = @(Get-AppFolders $local)
        $current = if ($apps) { $apps[-1].Name -replace '^app-' } else { '' }
        if ($result.Contains('Updater')) {
            $apps | Select-Object -SkipLast 1 | ForEach-Object { $result.Updater.Add($_.FullName) }
            # Each version also leaves a first-run marker folder in Roaming
            Get-ChildItem $roaming -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and $_.Name -ne $current } |
                ForEach-Object { $result.Updater.Add($_.FullName) }
            Get-ChildItem "$local\packages" -Filter *.nupkg -ErrorAction SilentlyContinue | Where-Object Name -notlike "*-$current-*" | ForEach-Object { $result.Updater.Add($_.FullName) }
            foreach ($p in "$local\packages\SquirrelTemp", "$local\SquirrelSetup.log") { if (Test-Path $p) { $result.Updater.Add($p) } }
            Get-ChildItem "$local\download" -Force -ErrorAction SilentlyContinue | ForEach-Object { $result.Updater.Add($_.FullName) }
        }
        if ($result.Contains('Installer')) {
            Get-ChildItem "$local\packages" -Filter *.nupkg -ErrorAction SilentlyContinue | Where-Object Name -like "*-$current-*" | ForEach-Object { $result.Installer.Add($_.FullName) }
        }
    }
    if ($result.Contains('Downloads')) {
        $downloads = try { (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { $null }
        # A null path would make Get-ChildItem list the current folder instead
        if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
        Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Discord(PTB|Canary)?Setup.*\.exe$' } |
            ForEach-Object { $result.Downloads.Add($_.FullName) }
    }
    if ($result.Contains('Logs')) {
        # Windows' own crash dumps and error reports for Discord
        Get-ChildItem "$env:LOCALAPPDATA\CrashDumps" -Filter 'Discord*.dmp' -ErrorAction SilentlyContinue | ForEach-Object { $result.Logs.Add($_.FullName) }
        foreach ($wer in "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
                         "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue") {
            Get-ChildItem $wer -Directory -Filter '*Discord*' -ErrorAction SilentlyContinue | ForEach-Object { $result.Logs.Add($_.FullName) }
        }
    }
    $result
}

function Get-PathBytes([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 0 }
    if (-not $item.PSIsContainer) { return $item.Length }
    [long](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# Deletes the targets (honours -WhatIf) and returns MB freed per area. Counts only what actually went:
# locked files and folders that need admin rights stay behind.
function Clear-DiscordTargets($Targets) {
    $freed = [ordered]@{}
    foreach ($a in $Targets.Keys) {
        $bytes = 0
        foreach ($p in $Targets[$a]) {
            $size = Get-PathBytes $p
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            $bytes += if ($WhatIfPreference) { $size } else { $size - (Get-PathBytes $p) }
        }
        $freed[$a] = [math]::Round($bytes / 1MB, 1)
    }
    $freed
}

# Exact install folders only - %LOCALAPPDATA%\DiscordOptimizer must not match. StartsWith rather than -like,
# because -like would treat [ ] in a user name as wildcards.
function Test-DiscordPath([string]$Path) {
    foreach ($root in $DiscordRoots) { if ($Path.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

function Get-DiscordProcs {
    Get-CimInstance Win32_Process -Filter "Name LIKE 'Discord%.exe'" | Where-Object { Test-DiscordPath $_.ExecutablePath }
}

# Closes every Discord flavor and returns the ones that were running (Discord, DiscordPTB, DiscordCanary),
# so callers can reopen exactly those. Returns nothing when none were.
function Stop-DiscordAll {
    $procs = @(Get-DiscordProcesses)
    if (-not $procs) { return }
    $flavors = $procs | ForEach-Object { $p = $_.Path; $DiscordRoots | Where-Object { $p.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) } } |
               ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not $WhatIfPreference) {
        for ($i = 0; $i -lt 30 -and (Get-DiscordProcs); $i++) { Start-Sleep -Milliseconds 500 }
        Start-Sleep -Seconds 2
    }
    $flavors
}

# Launch through WMI so Discord isn't a child of this shell
function Start-Detached([string]$CommandLine, [string]$WorkingDirectory) {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine; CurrentDirectory = $WorkingDirectory }
    if ($r.ReturnValue -ne 0) { throw "Launch failed ($($r.ReturnValue)): $CommandLine" }
}

# Every installed flavor (Discord, PTB, Canary) with its newest version folder
function Get-DiscordInstalls {
    foreach ($local in $DiscordRoots) {
        $app = Get-AppFolders $local | Select-Object -Last 1
        if ($app) {
            $flavor = Split-Path $local -Leaf
            [pscustomobject]@{
                Flavor  = $flavor                                     # Discord, DiscordPTB or DiscordCanary
                Local   = $local
                Roaming = Join-Path $env:APPDATA $flavor.ToLower()    # settings.json and caches
                App     = $app
                Version = $app.Name -replace '^app-'
                Exe     = Join-Path $app.FullName "$flavor.exe"
            }
        }
    }
}

# The install the window describes and a benchmark starts: the first flavor whose program is actually there
function Get-DiscordInstall { Get-DiscordInstalls | Where-Object { Test-Path $_.Exe } | Select-Object -First 1 }

# True while Discord is installing an update: files still landing in its download folder, or a version folder that
# appeared in the last minute. Closing Discord then could leave a half-written version it can't start from.
function Test-DiscordUpdating {
    $cutoff = (Get-Date).AddSeconds(-60)
    foreach ($root in $DiscordRoots) {
        $download = Join-Path $root 'download'
        if ((Test-Path $download) -and (Get-ChildItem $download -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $cutoff } | Select-Object -First 1)) { return $true }
        $newest = Get-AppFolders $root | Select-Object -Last 1
        if ($newest -and $newest.CreationTime -gt $cutoff) { return $true }
    }
    $false
}

# Vencord hooks in by renaming resources\app.asar to _app.asar (its settings live in %APPDATA%\Vencord; this tool
# touches neither). Discord updates install a fresh, unpatched app-<version> folder, so Vencord stops loading until
# its installer is run again (Repair). Returns 'none', 'active' or 'needs-repair'.
# Vencord's uninstaller leaves %APPDATA%\Vencord behind, so "not patched" alone could just mean uninstalled. The
# version Vencord was last seen in tells the two apart: only a newer version of that Discord means an update.
function Get-VencordState {
    if (-not (Test-Path (Join-Path $env:APPDATA 'Vencord'))) { return 'none' }
    $seenFile = Join-Path $env:LOCALAPPDATA 'DiscordOptimizer\vencord-seen.txt'
    $seen = if (Test-Path $seenFile) { ([string](Get-Content $seenFile -Raw)).Trim() } else { '' }
    $installed = @()
    foreach ($root in $DiscordRoots) {
        $app = Get-AppFolders $root | Select-Object -Last 1
        if (-not $app) { continue }
        $id = "$(Split-Path $root -Leaf)\$($app.Name)"   # e.g. Discord\app-1.0.9260
        if (Test-Path (Join-Path $app.FullName 'resources\_app.asar')) {
            if ($seen -ne $id) {
                New-Item (Split-Path $seenFile) -ItemType Directory -Force | Out-Null
                Set-Content $seenFile $id
            }
            return 'active'
        }
        $installed += $id
    }
    $seenFlavor = ($seen -split '\\')[0]
    if ($seen -and @($installed | Where-Object { $_ -like "$seenFlavor\*" -and $_ -ne $seen }).Count) { 'needs-repair' } else { 'none' }
}

# Restart Discord from scratch and wait until it has finished loading.
# Adaptive by default: measuring during startup (update check, loading servers, compiling scripts) would mostly
# capture startup noise. -Fixed waits the full time instead, so research runs are directly comparable.
function Start-DiscordFresh([string]$Exe, [string]$Arguments = '', [int]$SettleSeconds = 90, [switch]$Fixed) {
    Stop-DiscordAll | Out-Null
    Start-Detached "`"$Exe`" $Arguments".Trim() (Split-Path $Exe)
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Get-DiscordProcs | Where-Object { $_.CommandLine -match '--type=renderer' }) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if ($Fixed) { Start-Sleep -Seconds $SettleSeconds }
    else { Wait-DiscordSettled -MaxSeconds $SettleSeconds }
}

# Discord's own processes (all flavors, plus its Update.exe). Looking them up by name first matters: reading the
# path of every process on the PC made each check take seconds.
function Get-DiscordProcesses {
    Get-Process -Name Discord, DiscordPTB, DiscordCanary, Update -ErrorAction SilentlyContinue | Where-Object { $_.Path -and (Test-DiscordPath $_.Path) }
}

# Returns once Discord has calmed down: over the last 15 s its CPU averaged under 6% of a core and its memory moved
# less than 1%. Averaging means one brief spike (a plugin or background sync) doesn't restart the wait.
# Never sooner than MinSeconds, because startup work comes in bursts; never later than MaxSeconds.
function Wait-DiscordSettled([int]$MaxSeconds = 90, [int]$MinSeconds = 30) {
    $redirected = [Console]::IsOutputRedirected   # piped into the window's log: print lines, no progress bar
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cpus = @(); $mems = @(); $lastCpu = $null; $lastMem = $null; $settled = $false
    while (-not $settled -and $clock.Elapsed.TotalSeconds + 5 -le $MaxSeconds) {
        Start-Sleep -Seconds 5
        $procs = @(Get-DiscordProcesses)
        $cpu = ($procs | ForEach-Object { $_.TotalProcessorTime.TotalMilliseconds } | Measure-Object -Sum).Sum
        $mem = ($procs | Measure-Object PrivateMemorySize64 -Sum).Sum
        if ($null -ne $lastCpu) {
            $cpuPct = ($cpu - $lastCpu) / 50                       # ms of CPU over 5 s -> % of one core
            $cpus = @($cpus + $cpuPct)[-3..-1]
            $mems = @($mems + ([math]::Abs($mem - $lastMem) / [math]::Max($lastMem, 1)))[-3..-1]
            # A process exiting makes the CPU sum drop (negative), and no Discord at all isn't "settled" either
            $settled = $procs.Count -and $cpus.Count -eq 3 -and ($cpus | Measure-Object -Minimum).Minimum -ge 0 -and
                       ($cpus | Measure-Object -Average).Average -lt 6 -and ($mems | Measure-Object -Maximum).Maximum -lt 0.01 -and
                       $clock.Elapsed.TotalSeconds -ge $MinSeconds
            $status = 'waiting for Discord to finish loading: CPU {0:N0}% of a core, {1:N0} MB reserved' -f [math]::Max($cpuPct, 0), ($mem / 1MB)
            if ($redirected) { Write-Host "  $status" }
            else { Write-Progress -Activity 'Letting Discord settle' -Status $status -PercentComplete (100 * $clock.Elapsed.TotalSeconds / $MaxSeconds) }
        }
        $lastCpu = $cpu; $lastMem = $mem
    }
    if (-not $redirected) { Write-Progress -Activity 'Letting Discord settle' -Completed }
    if ($settled) { Write-Host ('  settled after {0:N0} s' -f $clock.Elapsed.TotalSeconds) }
    else { Write-Host "  still busy after $MaxSeconds s, measuring anyway" }
}

function Get-ProcType([string]$CommandLine) {
    $type = if ($CommandLine -match '--type=([\w-]+)') { $Matches[1] } else { 'main' }
    if ($CommandLine -match '--utility-sub-type=[\w]+\.mojom\.(\w+)') { $type = $Matches[1] }
    $type
}

function Get-DiscordDiskMB {
    $paths = @($DiscordRoots) + @('discord', 'discordptb', 'discordcanary' | ForEach-Object { Join-Path $env:APPDATA $_ }) | Where-Object { Test-Path $_ }
    [math]::Round(((Get-ChildItem -LiteralPath $paths -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB)
}

# Snapshot of everything Discord is using right now. CPU and GPU are averaged over $Seconds.
function Measure-Discord([int]$Seconds = 30) {
    $procs = @(Get-DiscordProcs)
    if (-not $procs) { throw 'Discord is not running.' }
    $pids  = $procs.ProcessId
    $cpu0  = (Get-Process -Id $pids -ErrorAction SilentlyContinue | ForEach-Object { $_.TotalProcessorTime.TotalMilliseconds } | Measure-Object -Sum).Sum
    $sw    = [Diagnostics.Stopwatch]::StartNew()
    # GPU counter names are translated on non-English Windows, so these can fail; the GPU and VRAM numbers are then
    # left empty rather than shown as 0
    $gpu   = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples $Seconds -ErrorAction SilentlyContinue
    # Keep the CPU window $Seconds long even when the GPU counter failed straight away
    $left = $Seconds * 1000 - $sw.ElapsedMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds $left }
    $sw.Stop()
    $cpu1  = (Get-Process -Id $pids -ErrorAction SilentlyContinue | ForEach-Object { $_.TotalProcessorTime.TotalMilliseconds } | Measure-Object -Sum).Sum

    $pidPattern = '^pid_(' + ($pids -join '|') + ')_'
    $gpu3d = if ($gpu) {
        ($gpu | ForEach-Object {
            ($_.CounterSamples | Where-Object { $_.InstanceName -match $pidPattern -and $_.InstanceName -like '*engtype_3d' } | Measure-Object CookedValue -Sum).Sum
        } | Measure-Object -Average).Average
    }

    $procs = @(Get-DiscordProcs)   # re-read: processes come and go
    $perf  = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "Name LIKE 'Discord%'"
    $vramSamples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue).CounterSamples
    $vram  = if ($vramSamples) {
        ($vramSamples | Where-Object { $_.InstanceName -match ('^pid_(' + ($procs.ProcessId -join '|') + ')_') } | Measure-Object CookedValue -Sum).Sum
    }

    $byType = [ordered]@{}
    $privWs = 0; $privBytes = 0
    foreach ($p in $procs) {
        $pf = $perf | Where-Object IDProcess -eq $p.ProcessId | Select-Object -First 1
        if (-not $pf) { continue }
        $type = Get-ProcType $p.CommandLine
        $byType[$type] = [int]$byType[$type] + [math]::Round($pf.WorkingSetPrivate / 1MB)
        $privWs += $pf.WorkingSetPrivate; $privBytes += $pf.PrivateBytes
    }
    $main = $procs | Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1

    [ordered]@{
        Time         = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Version      = Split-Path (Split-Path $main.ExecutablePath) -Leaf
        Procs        = $procs.Count
        PrivateWS_MB = [math]::Round($privWs / 1MB)
        Private_MB   = [math]::Round($privBytes / 1MB)
        VRAM_MB      = if ($vramSamples) { [math]::Round([double]$vram / 1MB) } else { $null }
        CPU_core_pct = [math]::Round(($cpu1 - $cpu0) / $sw.Elapsed.TotalMilliseconds * 100, 2)
        GPU3D_pct    = if ($gpu) { [math]::Round([double]$gpu3d, 2) } else { $null }
        ByType       = $byType
        RendererCmd  = ($procs | Where-Object { $_.CommandLine -match '--type=renderer' } | Select-Object -First 1).CommandLine
    }
}

$ReportMetrics = @(
    @{ Key = 'PrivateWS_MB'; Label = 'Memory (RAM)';      Unit = 'MB' }
    @{ Key = 'VRAM_MB';      Label = 'Graphics memory';   Unit = 'MB' }
    @{ Key = 'CPU_core_pct'; Label = 'CPU (% of 1 core)'; Unit = '%' }
    @{ Key = 'GPU3D_pct';    Label = 'GPU load';          Unit = '%' }
    @{ Key = 'Disk_MB';      Label = 'Disk';              Unit = 'MB' }
    @{ Key = 'Procs';        Label = 'Processes';         Unit = '' }
)

function Show-DiscordComparison($Before, $After) {
    $rows = foreach ($m in $ReportMetrics) {
        $b = $Before.($m.Key); $a = $After.($m.Key)
        $change = if ($null -ne $a -and $null -ne $b -and $b -ne 0) { '{0:+0;-0;0}%' -f (($a - $b) / $b * 100) } else { '' }
        $show = { param($v) if ($null -eq $v) { '-' } else { "$v $($m.Unit)".Trim() } }
        [pscustomobject]@{ Metric = $m.Label; Before = (& $show $b); After = (& $show $a); Change = $change }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function New-DiscordReport {
    param($Before, $After, [string]$Path, [string[]]$Changes = @(), [string]$Method = '')
    $fields = 'Time', 'Version', 'Procs', 'PrivateWS_MB', 'Private_MB', 'VRAM_MB', 'CPU_core_pct', 'GPU3D_pct', 'Disk_MB', 'ByType'
    $pick = { param($m) if ($null -eq $m) { return $null }; $o = [ordered]@{}; foreach ($f in $fields) { $o[$f] = $m.$f }; $o }
    $data = [ordered]@{ before = (& $pick $Before); after = (& $pick $After); changes = $Changes; method = $Method; generated = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    # PS 5.1's ConvertTo-Json escapes < and >, so this can't close the <script> tag
    $json = $data | ConvertTo-Json -Depth 6 -Compress
    New-Item (Split-Path $Path) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($Path, $ReportTemplate.Replace('__DATA__', $json), [Text.UTF8Encoding]::new($false))
    $Path
}

$ReportTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Discord Benchmark</title>
<style>
  :root {
    color-scheme: light;
    --page: #f9f9f7; --surface: #fcfcfb; --border: rgba(11,11,11,0.10);
    --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #898781;
    --grid: #e1e0d9; --baseline: #c3c2b7; --hover: rgba(11,11,11,0.04);
    --before: #86b6ef; --after: #1c5cab;
    --good: #006300; --bad: #d03b3b;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19; --border: rgba(255,255,255,0.10);
      --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
      --grid: #2c2c2a; --baseline: #383835; --hover: rgba(255,255,255,0.05);
      --before: #1c5cab; --after: #6da7ec;
      --good: #0ca30c; --bad: #d03b3b;
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --border: rgba(255,255,255,0.10);
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
    --grid: #2c2c2a; --baseline: #383835; --hover: rgba(255,255,255,0.05);
    --before: #1c5cab; --after: #6da7ec;
    --good: #0ca30c; --bad: #d03b3b;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--page); color: var(--text-primary);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 880px; margin: 0 auto; padding: 32px 16px 48px; }
  h1 { font-size: 24px; font-weight: 600; margin: 0 0 4px; }
  h2 { font-size: 16px; font-weight: 600; margin: 0 0 4px; }
  .sub { color: var(--text-secondary); margin: 0; }
  .muted { color: var(--text-muted); font-size: 13px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-top: 16px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(128px, 1fr)); gap: 12px; margin-top: 24px; }
  .tile { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px; }
  .tile .label { color: var(--text-secondary); font-size: 13px; }
  .tile .value { font-size: 28px; font-weight: 600; margin: 4px 0 2px; }
  .tile .value small { font-size: 14px; font-weight: 400; color: var(--text-secondary); }
  .tile .was { color: var(--text-muted); font-size: 13px; }
  .delta { font-size: 13px; font-weight: 600; margin-top: 6px; }
  .delta.good { color: var(--good); } .delta.bad { color: var(--bad); } .delta.same { color: var(--text-muted); font-weight: 400; }
  .legend { display: flex; gap: 16px; margin: 8px 0 4px; color: var(--text-secondary); font-size: 13px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .chart { position: relative; }
  .chart svg { display: block; width: 100%; height: auto; overflow: visible; }
  .chart text { font: 12px system-ui, -apple-system, "Segoe UI", sans-serif; }
  .row-hit { fill: transparent; outline: none; cursor: default; }
  .row-hit:hover, .row-hit:focus-visible { fill: var(--hover); }
  .tooltip { position: absolute; pointer-events: none; background: var(--surface); border: 1px solid var(--border);
             border-radius: 8px; padding: 8px 10px; font-size: 13px; box-shadow: 0 4px 16px rgba(0,0,0,0.12);
             white-space: nowrap; display: none; z-index: 2; }
  .tooltip .title { color: var(--text-secondary); margin-bottom: 4px; }
  .tooltip .line { display: flex; align-items: center; gap: 8px; }
  .tooltip .line b { min-width: 64px; }
  .tooltip .key { width: 12px; height: 2px; border-radius: 1px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; font-variant-numeric: tabular-nums; }
  th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--grid); }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--text-secondary); font-weight: 600; }
  ul { margin: 8px 0 0; padding-left: 20px; color: var(--text-secondary); }
</style>
</head>
<body>
<main>
  <h1>Discord before / after</h1>
  <p class="sub" id="subtitle"></p>
  <div class="tiles" id="tiles"></div>

  <section class="card" id="byproc">
    <h2>Memory by Discord process</h2>
    <p class="muted">Private working set in MB (what Task Manager shows as Memory). Labels show the latest value.</p>
    <div class="legend" id="legend"></div>
    <div class="chart" id="chart"><div class="tooltip" id="tooltip"></div></div>
  </section>

  <section class="card">
    <h2>All numbers</h2>
    <table id="table"><thead></thead><tbody></tbody></table>
  </section>

  <section class="card" id="notes">
    <h2>What changed</h2>
    <ul id="changes"></ul>
    <p class="muted" id="method"></p>
  </section>
</main>
<script type="application/json" id="data">__DATA__</script>
<script>
(function () {
  var data = JSON.parse(document.getElementById('data').textContent);
  var before = data.before, after = data.after;
  var metrics = [
    { key: 'PrivateWS_MB', tile: 'RAM', label: 'Memory (RAM)', unit: 'MB', digits: 0 },
    { key: 'VRAM_MB', tile: 'VRAM', label: 'Graphics memory (VRAM)', unit: 'MB', digits: 0 },
    { key: 'CPU_core_pct', tile: 'CPU', label: 'CPU (1 core = 100%)', unit: '%', digits: 1 },
    { key: 'GPU3D_pct', tile: 'GPU', label: 'GPU load', unit: '%', digits: 1 },
    { key: 'Disk_MB', tile: 'Disk', label: 'Disk', unit: 'MB', digits: 0 },
    { key: 'Procs', tile: 'Processes', label: 'Processes', unit: '', digits: 0 }
  ];
  var SVGNS = 'http://www.w3.org/2000/svg';
  function fmt(v, d) { return v == null ? '\u2014' : Number(v).toLocaleString('en-US', { maximumFractionDigits: d, minimumFractionDigits: 0 }); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function svg(tag, attrs) { var e = document.createElementNS(SVGNS, tag); for (var k in attrs) e.setAttribute(k, attrs[k]); return e; }
  function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

  // Lower is better for every metric here
  // short: percentage only (tiles); otherwise percentage + absolute amount (table, tooltip)
  function delta(b, a, digits, unit, short) {
    if (b == null || a == null) return null;
    var diff = a - b, pct = b !== 0 ? diff / b * 100 : null;
    var tiny = Math.abs(diff) < Math.pow(10, -digits) || (pct !== null && Math.abs(pct) < 1);
    if (tiny) return { cls: 'same', text: 'No change' };
    var word = diff < 0 ? 'less' : 'more';
    var arrow = diff < 0 ? '\u25BC ' : '\u25B2 ';
    var amount = fmt(Math.abs(diff), digits) + (unit === '%' ? ' pts' : (unit ? ' ' + unit : ''));
    var text = pct === null ? amount + ' ' + word
             : short ? Math.abs(Math.round(pct)) + '% ' + word
             : Math.abs(Math.round(pct)) + '% ' + word + ' (' + amount + ')';
    return { cls: diff < 0 ? 'good' : 'bad', text: arrow + text };
  }

  var sub = [];
  if (after && after.Version) sub.push('Discord ' + after.Version.replace(/^app-/, ''));
  if (before && before.Time) sub.push('before ' + before.Time);
  if (after && after.Time) sub.push((before ? 'after ' : 'measured ') + after.Time);
  document.getElementById('subtitle').textContent = sub.join(' \u00B7 ');

  // Stat tiles
  var tiles = document.getElementById('tiles');
  metrics.forEach(function (m) {
    var a = after ? after[m.key] : null, b = before ? before[m.key] : null;
    var t = el('div', 'tile');
    t.appendChild(el('div', 'label', m.tile));
    var v = el('div', 'value', fmt(a, m.digits));
    if (m.unit) { v.appendChild(document.createTextNode(' ')); v.appendChild(el('small', null, m.unit)); }
    t.appendChild(v);
    if (before) {
      t.appendChild(el('div', 'was', 'was ' + fmt(b, m.digits) + (m.unit ? ' ' + m.unit : '')));
      var d = delta(b, a, m.digits, m.unit, true);
      if (d) t.appendChild(el('div', 'delta ' + d.cls, d.text));
    }
    tiles.appendChild(t);
  });

  // Dumbbell: memory per process type, before (ring) -> after (dot)
  var types = {};
  [before, after].forEach(function (s) { if (s && s.ByType) for (var k in s.ByType) types[k] = true; });
  var rows = Object.keys(types).map(function (k) {
    // A process type missing from one run gets no marker rather than a fake 0
    function val(s) { return s && s.ByType && s.ByType[k] != null ? s.ByType[k] : null; }
    return { name: k, b: val(before), a: val(after) };
  }).sort(function (x, y) { return Math.max(y.b || 0, y.a || 0) - Math.max(x.b || 0, x.a || 0); });

  var legend = document.getElementById('legend');
  function legendItem(label, ring) {
    var s = el('span');
    var icon = svg('svg', { width: 14, height: 14, viewBox: '0 0 14 14', 'aria-hidden': 'true' });
    icon.appendChild(svg('circle', ring
      ? { cx: 7, cy: 7, r: 5, fill: 'var(--surface)', stroke: 'var(--before)', 'stroke-width': 2 }
      : { cx: 7, cy: 7, r: 5, fill: 'var(--after)' }));
    s.appendChild(icon); s.appendChild(document.createTextNode(label));
    return s;
  }
  if (before) legend.appendChild(legendItem('Before', true));
  legend.appendChild(legendItem(before ? 'After' : 'Now', false));

  var W = 640, labelW = 130, rightPad = 56, rowH = 36, top = 8, axisH = 24;
  var H = top + rows.length * rowH + axisH;
  var max = 0; rows.forEach(function (r) { max = Math.max(max, r.b || 0, r.a || 0); });
  var step = Math.pow(10, Math.floor(Math.log10(Math.max(max, 1))));
  [1, 2, 5, 10].some(function (m) { if (max / (step * m) <= 5) { step *= m; return true; } return false; });
  var niceMax = Math.max(step, Math.ceil(max / step) * step);
  function x(v) { return labelW + (W - labelW - rightPad) * v / niceMax; }

  var chart = document.getElementById('chart'), tip = document.getElementById('tooltip');
  var s = svg('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': 'Memory by Discord process, before and after' });
  for (var g = 0; g <= niceMax + 1e-9; g += step) {
    s.appendChild(svg('line', { x1: x(g), x2: x(g), y1: top, y2: top + rows.length * rowH, stroke: g === 0 ? 'var(--baseline)' : 'var(--grid)', 'stroke-width': 1 }));
    var tick = svg('text', { x: x(g), y: H - 6, 'text-anchor': 'middle', fill: 'var(--text-muted)' });
    tick.textContent = fmt(g, 0); s.appendChild(tick);
  }
  rows.forEach(function (r, i) {
    var cy = top + i * rowH + rowH / 2;
    var hit = svg('rect', { x: 0, y: top + i * rowH, width: W, height: rowH, rx: 6, class: 'row-hit', tabindex: 0 });
    s.appendChild(hit);
    var name = svg('text', { x: 0, y: cy + 4, fill: 'var(--text-secondary)' }); name.textContent = r.name; s.appendChild(name);
    if (r.b != null && r.a != null) s.appendChild(svg('line', { x1: x(r.b), x2: x(r.a), y1: cy, y2: cy, stroke: 'var(--baseline)', 'stroke-width': 2, 'stroke-linecap': 'round' }));
    if (r.b != null) s.appendChild(svg('circle', { cx: x(r.b), cy: cy, r: 5, fill: 'var(--surface)', stroke: 'var(--before)', 'stroke-width': 2 }));
    if (r.a != null) s.appendChild(svg('circle', { cx: x(r.a), cy: cy, r: 6, fill: 'var(--after)', stroke: 'var(--surface)', 'stroke-width': 2 }));
    var end = Math.max(r.b || 0, r.a || 0);
    var lbl = svg('text', { x: x(end) + 12, y: cy + 4, fill: 'var(--text-primary)' }); lbl.textContent = fmt(r.a != null ? r.a : r.b, 0); s.appendChild(lbl);

    function show(evt) {
      tip.textContent = '';
      tip.appendChild(el('div', 'title', r.name));
      function line(label, value, color) {
        var l = el('div', 'line'); var k = el('span', 'key'); k.style.background = color;
        l.appendChild(k); l.appendChild(el('b', null, fmt(value, 0) + ' MB')); l.appendChild(el('span', null, label)); tip.appendChild(l);
      }
      if (r.b != null) line('Before', r.b, css('--before'));
      if (r.a != null) line(before ? 'After' : 'Now', r.a, css('--after'));
      if (r.b != null && r.a != null) { var d = delta(r.b, r.a, 0, 'MB'); if (d) tip.appendChild(el('div', 'delta ' + d.cls, d.text)); }
      tip.style.display = 'block';
      var box = chart.getBoundingClientRect(), scale = box.width / W;
      var px = evt && evt.clientX != null ? evt.clientX - box.left : x(end) * scale;
      var py = (top + i * rowH) * scale;
      tip.style.left = Math.min(px + 12, box.width - tip.offsetWidth) + 'px';
      tip.style.top = Math.max(0, py - tip.offsetHeight - 4) + 'px';
    }
    function hide() { tip.style.display = 'none'; }
    hit.addEventListener('pointermove', show); hit.addEventListener('pointerleave', hide);
    hit.addEventListener('focus', function () { show(null); }); hit.addEventListener('blur', hide);
  });
  chart.insertBefore(s, tip);

  // Table view
  var thead = document.querySelector('#table thead'), tbody = document.querySelector('#table tbody');
  var hr = el('tr'); ['', before ? 'Before' : null, before ? 'After' : 'Now', before ? 'Change' : null].forEach(function (h) { if (h !== null) hr.appendChild(el('th', null, h)); });
  thead.appendChild(hr);
  function addRow(label, b, a, digits, unit) {
    var tr = el('tr'); tr.appendChild(el('td', null, label));
    var u = unit ? ' ' + unit : '';
    if (before) tr.appendChild(el('td', null, fmt(b, digits) + u));
    tr.appendChild(el('td', null, fmt(a, digits) + u));
    if (before) { var d = delta(b, a, digits, unit); var td = el('td', d ? 'delta ' + d.cls : '', d ? d.text : '\u2014'); tr.appendChild(td); }
    tbody.appendChild(tr);
  }
  metrics.forEach(function (m) { addRow(m.label, before ? before[m.key] : null, after ? after[m.key] : null, m.digits, m.unit); });
  rows.forEach(function (r) { addRow('\u2003' + r.name, r.b, r.a, 0, 'MB'); });

  var changes = document.getElementById('changes');
  (data.changes || []).forEach(function (c) { changes.appendChild(el('li', null, c)); });
  if (!(data.changes || []).length) document.getElementById('notes').querySelector('h2').textContent = 'Notes';
  document.getElementById('method').textContent = data.method || '';
})();
</script>
</body>
</html>
'@
