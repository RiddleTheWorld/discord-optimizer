#Requires -Version 5.1
<#
.SYNOPSIS
    Shrinks Discord's disk, RAM, CPU and GPU footprint. Every change is reversible with -Restore.

.EXAMPLE
    .\Optimize-Discord.ps1 -All -WhatIf       # preview everything
    .\Optimize-Discord.ps1 -All -Benchmark    # measure, apply everything, measure again, open a report
    .\Optimize-Discord.ps1 -Benchmark         # just measure, compared with the last measurement
    .\Optimize-Discord.ps1 -Benchmark -CompareWith "$env:LOCALAPPDATA\DiscordOptimizer\reports\snapshot-<time>.json"
    .\Optimize-Discord.ps1 -ClearCache        # clear the safe cache areas (closes and reopens Discord)
    .\Optimize-Discord.ps1 -ClearCache -Areas Media, Logs, Code
    .\Optimize-Discord.ps1 -Restore           # undo
    .\DiscordOptimizerUI.ps1                  # the same, with a window
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Disk,                    # optional modules, extra language packs, old versions, logs (not caches: see -ClearCache)
    [switch]$NoGpu,                   # hardware acceleration off: biggest RAM/VRAM cut; video, screen share and scrolling use CPU instead
    [switch]$NoStartup,               # don't launch with Windows
    [switch]$Governor,                # background throttler (DiscordGovernor.exe)
    [int]$RestartAboveMB = 0,         # governor: restart Discord to the tray when you're away 30+ min and it's above this
    [int]$ClearCacheAboveMB = 0,      # governor: clear the cache at sign-in (before Discord runs) when it's above this
    [switch]$Maintain,                # governor: while Discord is closed, re-remove what Discord updates bring back
    [switch]$RemoveInstallerPackage,  # delete the installer .nupkg (~140 MB); opt-in, see README
    [switch]$ClearCache,              # clear cache areas (closes and reopens Discord)
    [string[]]$Areas,                 # with -ClearCache: Media, Gpu, Logs, Browser, Updater, Code, Installer, Downloads (default: the safe set)
    [switch]$All,                     # Disk + NoGpu + NoStartup + Governor
    [switch]$Restore,
    [switch]$Benchmark,               # measure before and after, then open an HTML report
    [switch]$NoOpen,                  # benchmark: don't open the report (the window shows its own summary)
    [int]$SettleSeconds = 90,         # benchmark: how long Discord runs before it is measured
    [int]$MeasureSeconds = 20,        # benchmark: how long CPU/GPU are averaged
    [string]$CompareWith              # benchmark without changes: snapshot .json to compare against (default: the latest)
)
if ($All) { $Disk = $NoGpu = $NoStartup = $Governor = $true }
. (Join-Path $PSScriptRoot 'DiscordCommon.ps1')

# Which cache areas this run clears
$clearAreas = New-Object System.Collections.Generic.List[string]
if ($ClearCache) {
    # powershell -File passes "Media,Gpu" as one string, so split it here
    $Areas = @($Areas | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $chosen = if ($Areas) { $Areas } else { $DiscordCleanAreas.Keys | Where-Object { $DiscordCleanAreas[$_].Default } }
    foreach ($a in $chosen) {
        if (-not $DiscordCleanAreas.Contains($a)) { throw "Unknown area '$a'. Use: $($DiscordCleanAreas.Keys -join ', ')" }
        $clearAreas.Add($a)
    }
}
# -Disk only removes leftovers. Caches are -ClearCache's job: wiping them here would make Discord's next start
# slower and force a warm-up launch before any benchmark.
if ($Disk) { foreach ($a in 'Updater', 'Logs') { if (-not $clearAreas.Contains($a)) { $clearAreas.Add($a) } } }
if ($RemoveInstallerPackage -and -not $clearAreas.Contains('Installer')) { $clearAreas.Add('Installer') }

$InstallDir = Join-Path $env:LOCALAPPDATA 'DiscordOptimizer'
$BackupDir  = Join-Path $InstallDir 'backup'
$ReportsDir = Join-Path $InstallDir 'reports'
$GovExe     = Join-Path $InstallDir 'DiscordGovernor.exe'
$StateFile  = Join-Path $InstallDir 'applied.json'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'


# settings.json keys this tool changes. -Restore puts back only these, so settings Discord saved since are kept.
$ManagedSettings = @('enableHardwareAcceleration')

function Read-SettingsJson([string]$File) {
    if (-not (Test-Path $File)) { return [pscustomobject]@{} }   # Discord hasn't run yet; it reads ours on first start
    $text = Get-Content $File -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { $text | ConvertFrom-Json -ErrorAction Stop } catch { $null }   # $null = unreadable; never overwrite it
}

function Write-SettingsJson([string]$File, $Json) {
    New-Item (Split-Path $File) -ItemType Directory -Force | Out-Null
    # Set-Content/Out-File in PS 5.1 write a BOM, which Discord's JSON.parse rejects
    [IO.File]::WriteAllText($File, ($Json | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}

function Set-DiscordSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Roaming, [hashtable]$Values)
    $file = Join-Path $Roaming 'settings.json'
    $json = Read-SettingsJson $file
    if ($null -eq $json) { Write-Warning "$file isn't valid JSON, so it was left alone."; return }
    # The first backup is the original, and doubles as the marker that this tool changed this flavor.
    # No settings.json yet means nothing was set: record that as {} so -Restore knows to remove our key.
    $backup = Join-Path $BackupDir "settings.$(Split-Path $Roaming -Leaf).json"
    if (-not (Test-Path $backup) -and -not $WhatIfPreference) {
        New-Item $BackupDir -ItemType Directory -Force | Out-Null
        if (Test-Path $file) { Copy-Item $file $backup } else { [IO.File]::WriteAllText($backup, '{}') }
    }
    foreach ($k in $Values.Keys) { $json | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] -Force }
    if ($PSCmdlet.ShouldProcess($file, "Set $($Values.Keys -join ', ')")) { Write-SettingsJson $file $json }
}

# Puts the managed keys back to what the first backup had (or removes them if it didn't have them)
function Restore-DiscordSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Roaming)
    $file = Join-Path $Roaming 'settings.json'
    $backup = Join-Path $BackupDir "settings.$(Split-Path $Roaming -Leaf).json"
    # No backup means this tool never changed this flavor's settings (e.g. a PTB install it didn't touch);
    # leave the user's own choices there alone
    if (-not (Test-Path $backup)) { return }
    $json = Read-SettingsJson $file
    if ($null -eq $json -or -not (Test-Path $file)) { return }
    $original = Read-SettingsJson $backup
    if ($null -eq $original) { return }
    foreach ($k in $ManagedSettings) {
        if ($original.PSObject.Properties[$k]) { $json | Add-Member -NotePropertyName $k -NotePropertyValue $original.$k -Force }
        else { $json.PSObject.Properties.Remove($k) }
    }
    if ($PSCmdlet.ShouldProcess($file, "Restore $($ManagedSettings -join ', ')")) { Write-SettingsJson $file $json }
}

function Stop-Governor {
    $running = Get-Process DiscordGovernor -ErrorAction SilentlyContinue
    $running | Stop-Process -Force
    # A killed governor can't clean up after itself, so un-throttle Discord explicitly
    if ($running -and (Test-Path $GovExe) -and -not $WhatIfPreference) { Start-Process $GovExe -ArgumentList '--restore' -Wait }
    Remove-ItemProperty $RunKey -Name DiscordGovernor -ErrorAction SilentlyContinue
}

function Invoke-Measurement([string]$Stage) {
    Write-Host "Measuring ${Stage}: restarting Discord, waiting until it has finished loading (30-${SettleSeconds}s), then sampling ${MeasureSeconds}s. Leave Discord alone meanwhile." -ForegroundColor Cyan
    Start-DiscordFresh (Get-DiscordInstall).Exe -SettleSeconds $SettleSeconds
    $m = Measure-Discord $MeasureSeconds
    $m.Remove('RendererCmd')
    $m.Disk_MB = Get-DiscordDiskMB
    New-Item $ReportsDir -ItemType Directory -Force | Out-Null
    $m | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ReportsDir "snapshot-$(Get-Date -Format yyyyMMdd-HHmmss).json") -Encoding UTF8
    $m
}

$installs = @(Get-DiscordInstalls)
if (-not $installs) { Write-Warning 'No Discord install found.'; return }
# Autostart and the governor can change while Discord runs; files and settings.json can't
$needsStop = $Disk -or $NoGpu -or $RemoveInstallerPackage -or $Restore -or $ClearCache
$changing  = $needsStop -or $NoStartup -or $Governor
$Benchmark = $Benchmark -and -not $WhatIfPreference
# Closing Discord (a benchmark restarts it) mid-update could leave a half-written version it can't start from
if (($needsStop -or $Benchmark) -and -not $WhatIfPreference -and (Test-DiscordUpdating)) {
    Write-Warning 'Discord is installing an update right now. Try again in a minute.'
    exit 1
}
$applied   = New-Object System.Collections.Generic.List[string]   # for the report
$inEffect  = New-Object System.Collections.Generic.List[string]   # lasting changes, remembered in applied.json
$wasRunning = $false

$beforeM = $null
if ($Benchmark -and $changing) { $beforeM = Invoke-Measurement 'BEFORE' }
elseif ($Benchmark) {
    $last = if ($CompareWith) { Get-Item $CompareWith }
            else { Get-ChildItem $ReportsDir -Filter 'snapshot-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1 }
    if ($last) { $beforeM = Get-Content $last.FullName -Raw | ConvertFrom-Json; $applied.Add("Compared with the measurement from $($beforeM.Time)") }
    if (Test-Path $StateFile) {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($a in $state.Applied) { $applied.Add("In effect: $a") }
    }
}

if ($needsStop) {
    $wasRunning = Stop-DiscordAll
    $diskBefore = Get-DiscordDiskMB
}

if ($Restore) {
    Stop-Governor
    foreach ($i in $installs) {
        Restore-DiscordSettings $i.Roaming
        # backup\modules\<timestamp>\<flavor>\<module>, plus app-version.txt naming the Discord version they came from
        $backupDirs = Get-ChildItem (Join-Path $BackupDir 'modules') -Directory -ErrorAction SilentlyContinue |
                      ForEach-Object { Join-Path $_.FullName $i.Flavor } | Where-Object { Test-Path $_ }
        foreach ($dir in $backupDirs) {
            # Old native modules in a newer Discord can fail to load; Discord downloads matching ones on demand instead
            $marker = Join-Path $dir 'app-version.txt'
            if ((Test-Path $marker) -and (Get-Content $marker -Raw).Trim() -ne $i.App.Name) {
                Write-Host "Not restoring modules saved from $((Get-Content $marker -Raw).Trim()): Discord has updated since and downloads them again when a feature needs them."
                continue
            }
            foreach ($m in Get-ChildItem $dir -Directory) {
                $target = Join-Path $i.App.FullName "modules\$($m.Name)"
                if (-not (Test-Path $target)) { Move-Item $m.FullName $target }
            }
        }
    }
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    $applied.Add('Restored hardware acceleration and modules, removed DiscordGovernor')
    Write-Host 'Restored. Turn "Open Discord" back on in Settings > Windows Settings if you want autostart.' -ForegroundColor Green
}
elseif ($changing) {
    $stamp = Get-Date -Format yyyyMMdd-HHmmss
    foreach ($i in $installs) {
        Write-Host "== $($i.Flavor) ($($i.App.Name))" -ForegroundColor Cyan
        $current = $i.App.FullName

        if ($Disk) {
            # Moved, not deleted, so -Restore can put them back
            $dest = Join-Path $BackupDir "modules\$stamp\$($i.Flavor)"
            Get-ChildItem "$current\modules" -Directory |
                Where-Object { ($_.Name -replace '-\d+$') -in $DiscordOptionalModules } |
                ForEach-Object {
                    if (-not $WhatIfPreference) {
                        New-Item $dest -ItemType Directory -Force | Out-Null
                        # -Restore only puts modules back into the Discord version they came from
                        Set-Content (Join-Path $dest 'app-version.txt') $i.App.Name
                    }
                    Move-Item $_.FullName $dest
                }
            $keep = Get-KeptLocales
            Get-ChildItem "$current\locales" -Filter *.pak -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -notin $keep } | Remove-Item -Force
        }
        if ($NoGpu) {
            Set-DiscordSettings -Roaming $i.Roaming -Values @{ enableHardwareAcceleration = $false }
        }
        if ($NoStartup) {
            # Discord's "Open Discord" toggle just checks whether this value exists
            Remove-ItemProperty $RunKey -Name $i.Flavor -ErrorAction SilentlyContinue
        }
    }
    if ($clearAreas.Count) {
        $freed = Clear-DiscordTargets (Get-DiscordCleanTargets $clearAreas)
        $parts = foreach ($a in $freed.Keys) { '{0} {1:N1} MB' -f $DiscordCleanAreas[$a].Label, $freed[$a] }
        $total = ($freed.Values | Measure-Object -Sum).Sum
        if ($WhatIfPreference) { Write-Host "Would clear: $($parts -join ', ')" }
        else {
            Write-Host ('Cleared {0:N1} MB: {1}' -f $total, ($parts -join ', ')) -ForegroundColor Green
            $applied.Add(('Cleared {0:N1} MB ({1})' -f $total, ($parts -join ', ')))
        }
    }
    if ($Disk) {
        $inEffect.Add('Removed optional modules: Krisp, overlay, game detection, Rich Presence, Game SDK, Clips capture, spellcheck, old store leftovers')
        $inEffect.Add('Removed extra language packs, old versions and logs')
    }
    if ($RemoveInstallerPackage) { $inEffect.Add('Deleted the installer package') }
    if ($NoGpu)     { $inEffect.Add('Hardware acceleration off') }
    if ($NoStartup) { $inEffect.Add('Autostart off') }

    if ($Governor) {
        Stop-Governor
        if ($PSCmdlet.ShouldProcess($GovExe, 'Build and install governor')) {
            New-Item $InstallDir -ItemType Directory -Force | Out-Null
            Remove-Item $GovExe -Force -ErrorAction SilentlyContinue
            # The helper gets its module and cache lists from DiscordCommon.ps1, so each list is defined once
            $toCSharp = { param($list) ($list | ForEach-Object { '@"{0}"' -f $_.Replace('"', '""') }) -join ', ' }
            $cachePaths = $DiscordCleanAreas.Keys | Where-Object { $DiscordCleanAreas[$_].Cache } | ForEach-Object { $DiscordAreaPaths[$_] }
            $source = Get-Content (Join-Path $PSScriptRoot 'DiscordGovernor.cs') -Raw
            $source = $source.Replace('/*@CachePaths@*/', (& $toCSharp $cachePaths)).Replace('/*@OptionalModules@*/', (& $toCSharp $DiscordOptionalModules))
            try {
                Add-Type -TypeDefinition $source -Language CSharp `
                         -OutputAssembly $GovExe -OutputType WindowsApplication -ReferencedAssemblies System.Core -ErrorAction Stop
            }
            catch { Write-Warning "Couldn't build the background helper (antivirus can block this): $($_.Exception.Message)" }
            if (Test-Path $GovExe) {
                $govArgs = '--log' + $(if ($RestartAboveMB -gt 0) { " --restart-above-mb $RestartAboveMB" }) +
                                     $(if ($ClearCacheAboveMB -gt 0) { " --clear-cache-above-mb $ClearCacheAboveMB" }) +
                                     $(if ($Maintain) { ' --maintain' })
                Set-ItemProperty $RunKey -Name DiscordGovernor -Value "`"$GovExe`" $govArgs"
                Start-Process $GovExe -ArgumentList $govArgs
                Write-Host "Background helper running ($govArgs)"
                $inEffect.Add('DiscordGovernor running: throttles Discord while it is in the background and silent')
                if ($Maintain) { $inEffect.Add('Kept clean after updates: the helper re-removes optional modules, extra languages and old versions while Discord is closed') }
            }
        }
    }
    foreach ($a in $inEffect) { $applied.Add($a) }

    if (-not $WhatIfPreference) {
        if ($needsStop) { Write-Host ("Disk: {0} MB -> {1} MB" -f $diskBefore, (Get-DiscordDiskMB)) -ForegroundColor Green }
        if ($inEffect.Count) {
            # Remember what's in effect so later benchmarks can say so. Reinstalling the helper replaces its old
            # options, so its previous entries go first.
            $previous = @(@(if (Test-Path $StateFile) { try { (Get-Content $StateFile -Raw | ConvertFrom-Json).Applied } catch { } }) | Where-Object { $_ })
            if ($Governor) { $previous = @($previous | Where-Object { $_ -notmatch '^(DiscordGovernor running|Kept clean after updates)' }) }
            $merged = $previous + $inEffect | Select-Object -Unique
            New-Item $InstallDir -ItemType Directory -Force | Out-Null   # a first run of only -NoStartup creates nothing else
            [pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Applied = @($merged) } | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        }
    }
}

if ($Benchmark) {
    if (@($clearAreas | Where-Object { $_ -in 'Media', 'Gpu', 'Code' }).Count) {
        # The first launch after a cache wipe re-downloads assets and recompiles all JavaScript,
        # which inflates RAM and CPU once. Get that out of the way so AFTER shows normal use.
        Write-Host 'Warm-up launch so Discord can rebuild the caches that were cleared...' -ForegroundColor Cyan
        Start-DiscordFresh (Get-DiscordInstall).Exe -SettleSeconds $SettleSeconds
    }
    $afterM = Invoke-Measurement $(if ($changing) { 'AFTER' } else { 'NOW' })
    if ($beforeM) { Show-DiscordComparison $beforeM $afterM }
    $method = "Each measurement: fresh Discord start with the window open, measured once it finished loading (30-${SettleSeconds}s), CPU/GPU averaged over ${MeasureSeconds}s. Expect +/-15% run-to-run noise on RAM and a lot more on CPU."
    $report = New-DiscordReport -Before $beforeM -After $afterM -Changes $applied -Method $method `
              -Path (Join-Path $ReportsDir "report-$(Get-Date -Format yyyyMMdd-HHmmss).html")
    # The window reads this to show its results pop-up
    [ordered]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Before = $beforeM; After = $afterM; Changes = @($applied); Report = $report; Method = $method } |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ReportsDir 'last-benchmark.json') -Encoding UTF8
    Write-Host "Report: $report" -ForegroundColor Green
    if (-not $NoOpen) { Invoke-Item $report }
}
elseif ($wasRunning -and -not $WhatIfPreference) {
    # Reopen exactly the flavors that were running (Discord, PTB, Canary)
    foreach ($flavor in @($wasRunning)) {
        $update = Join-Path (Join-Path $env:LOCALAPPDATA $flavor) 'Update.exe'
        if (Test-Path $update) { Start-Process $update -ArgumentList '--processStart', "$flavor.exe" }
    }
    Write-Host "Reopened $(@($wasRunning) -join ', ')."
}
