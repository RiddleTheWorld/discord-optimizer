#Requires -Version 5.1
<#
.SYNOPSIS
    Window for Optimize-Discord.ps1: live memory and cache stats, cache clearing by area, one-click optimizing,
    and a results pop-up after each benchmark.

.PARAMETER Theme
    Auto follows the Windows app theme; Light or Dark forces one.

.PARAMETER Screenshot
    Developer option: render the window to this PNG file and exit, without showing it or changing anything.
    -SelfTest, -ExpandAreas and -PreviewResults only work together with it.

.PARAMETER SelfTest
    Developer option: before the screenshot, run a harmless -WhatIf task through the same path as the Run button.

.PARAMETER ExpandAreas
    Developer option: show the cache area list open in the screenshot.

.PARAMETER PreviewResults
    Developer option: render the results pop-up for this last-benchmark.json instead of the main window.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\DiscordOptimizerUI.ps1

.EXAMPLE
    .\DiscordOptimizerUI.ps1 -Theme Dark -Screenshot window.png -ExpandAreas
#>
param(
    [ValidateSet('Auto', 'Light', 'Dark')] [string]$Theme = 'Auto',
    # Developer options, for testing and screenshots (see the help above)
    [string]$Screenshot,
    [switch]$SelfTest,
    [switch]$ExpandAreas,
    [string]$PreviewResults
)

# WPF needs a single-threaded apartment (Windows PowerShell's default, but not guaranteed)
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $relay = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"", '-Theme', $Theme)
    if ($Screenshot) { $relay += @('-Screenshot', "`"$Screenshot`"") }
    if ($SelfTest) { $relay += '-SelfTest' }
    if ($ExpandAreas) { $relay += '-ExpandAreas' }
    if ($PreviewResults) { $relay += @('-PreviewResults', "`"$PreviewResults`"") }
    Start-Process powershell.exe -ArgumentList $relay -Wait:([bool]$Screenshot)
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# The launcher hides the console, so a startup error would otherwise vanish without a trace
trap { [void][Windows.MessageBox]::Show("Discord Optimizer ran into a problem and has to close:`n`n$_", 'Discord Optimizer', 'OK', 'Error'); exit 1 }
. (Join-Path $PSScriptRoot 'DiscordCommon.ps1')

# One window at a time, so two can't run tasks against Discord at once (test renders are exempt)
if (-not $Screenshot) {
    $firstInstance = $false
    $instanceLock = New-Object Threading.Mutex($true, 'Local\DiscordOptimizerUI', [ref]$firstInstance)
    if (-not $firstInstance) { [void][Windows.MessageBox]::Show('Discord Optimizer is already open.', 'Discord Optimizer'); return }
}

$InstallDir = Join-Path $env:LOCALAPPDATA 'DiscordOptimizer'
$Optimizer  = Join-Path $PSScriptRoot 'Optimize-Discord.ps1'
$ConfigPath = Join-Path $InstallDir 'ui.json'
$LastBench  = Join-Path $InstallDir 'reports\last-benchmark.json'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Dot        = [string][char]0x00B7
$Arrow      = [string][char]0x2192

# --- Native helpers: background stats sampling, task runner, dark title bar -------------------------

$helperSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace DiscordUi
{
    // Runs Optimize-Discord.ps1 in a hidden PowerShell and queues its output for the UI thread.
    public class Runner
    {
        readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
        Process proc;
        volatile bool outDone, errDone;
        DateTime exitSeen;

        public void Start(string script, string arguments)
        {
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            proc = new Process();
            proc.StartInfo = psi;
            outDone = errDone = false;
            exitSeen = DateTime.MinValue;
            // A null line marks the end of each stream
            proc.OutputDataReceived += (s, e) => { if (e.Data == null) outDone = true; else lines.Enqueue(e.Data); };
            proc.ErrorDataReceived += (s, e) => { if (e.Data == null) errDone = true; else lines.Enqueue("! " + e.Data); };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
        }

        public bool Busy { get { return proc != null && !proc.HasExited; } }

        // True once the process has exited and all of its output has been read. Never blocks: if something the
        // task started keeps the output pipe open, give up on the rest of the output after 3 s instead of freezing.
        public bool Finished
        {
            get
            {
                if (proc == null || !proc.HasExited) return false;
                if (outDone && errDone) return true;
                if (exitSeen == DateTime.MinValue) exitSeen = DateTime.UtcNow;
                return (DateTime.UtcNow - exitSeen).TotalSeconds > 3;
            }
        }

        public int ExitCode { get { return proc == null ? 0 : proc.ExitCode; } }

        public string[] Drain()
        {
            var list = new List<string>();
            string line;
            while (lines.TryDequeue(out line)) list.Add(line);
            return list.ToArray();
        }

        public void Reset()
        {
            if (proc != null) proc.Dispose();
            proc = null;
        }
    }

    // Samples Discord's memory and disk use on a background thread so the window never stutters.
    public static class Stats
    {
        class AreaSet { public string[] Names = new string[0]; public string[][] Paths = new string[0][]; }

        static readonly string[] Names = { "Discord", "DiscordPTB", "DiscordCanary" };
        static readonly string[] Flavors = { "discord", "discordptb", "discordcanary" };
        static volatile AreaSet areas = new AreaSet();
        static volatile Dictionary<string, long> areaBytes = new Dictionary<string, long>();
        static long memoryMB = -1, diskMB = -1;
        static volatile int processes;
        static volatile bool helperRunning, refreshDisk = true;

        public static long MemoryMB { get { return Interlocked.Read(ref memoryMB); } }
        public static long DiskMB { get { return Interlocked.Read(ref diskMB); } }
        public static int Processes { get { return processes; } }
        public static bool HelperRunning { get { return helperRunning; } }
        public static void RefreshDisk() { refreshDisk = true; }

        // -1 until the first measurement
        public static long AreaBytes(string name)
        {
            long v;
            return areaBytes.TryGetValue(name, out v) ? v : -1;
        }

        public static void SetAreas(string[] names, string[][] paths)
        {
            areas = new AreaSet { Names = names, Paths = paths };
            refreshDisk = true;
        }

        public static void Start()
        {
            try { SampleProcesses(); } catch { }   // first sample before the window draws, so it never shows stale state
            var t = new Thread(Loop);
            t.IsBackground = true;
            t.Start();
        }

        static void Loop()
        {
            DateTime lastDisk = DateTime.MinValue;
            while (true)
            {
                try { SampleProcesses(); } catch { }
                if (refreshDisk || (DateTime.UtcNow - lastDisk).TotalSeconds > 30)
                {
                    refreshDisk = false;
                    lastDisk = DateTime.UtcNow;
                    try { SampleDisk(); } catch { }
                }
                Thread.Sleep(2000);
            }
        }

        static void SampleProcesses()
        {
            var pids = new HashSet<int>();
            bool helper = false;
            foreach (var p in Process.GetProcesses())
            {
                using (p)
                {
                    if (Names.Contains(p.ProcessName)) pids.Add(p.Id);
                    else if (p.ProcessName == "DiscordGovernor") helper = true;
                }
            }
            helperRunning = helper;
            processes = pids.Count;
            long sum = 0;
            if (pids.Count > 0)
            {
                // The number Task Manager shows as Memory: private working set
                var data = new PerformanceCounterCategory("Process").ReadCategory();
                var ids = data["ID Process"];
                var ws = data["Working Set - Private"];
                foreach (InstanceData d in ids.Values)
                    if (pids.Contains((int)d.RawValue) && ws.Contains(d.InstanceName)) sum += ws[d.InstanceName].RawValue;
            }
            Interlocked.Exchange(ref memoryMB, pids.Count > 0 ? sum >> 20 : -1);
        }

        static void SampleDisk()
        {
            var set = areas;
            var sizes = new Dictionary<string, long>();
            for (int i = 0; i < set.Names.Length; i++)
            {
                long bytes = 0;
                foreach (var p in set.Paths[i]) bytes += PathBytes(p);
                sizes[set.Names[i]] = bytes;
            }
            areaBytes = sizes;

            string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            long total = 0;
            foreach (var f in Flavors) total += Bytes(Path.Combine(roaming, f));
            foreach (var n in Names) total += Bytes(Path.Combine(local, n));
            Interlocked.Exchange(ref diskMB, total >> 20);
        }

        static long PathBytes(string path)
        {
            if (File.Exists(path)) { try { return new FileInfo(path).Length; } catch { return 0; } }
            return Bytes(path);
        }

        static long Bytes(string dir)
        {
            if (!Directory.Exists(dir)) return 0;
            long total = 0;
            try { foreach (var f in new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories)) total += f.Length; }
            catch { }
            return total;
        }
    }

    public static class Win
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        // Dark title bar to match a dark window (Windows 11 and late Windows 10)
        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref value, 4);
        }
    }
}
'@

# Compile once per version of the source, then just load it (saves ~1s per launch)
$sha  = New-Object Security.Cryptography.SHA1Managed
$hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($helperSource))).Replace('-', '').Substring(0, 10)
$helperDll = Join-Path $InstallDir "DiscordUi-$hash.dll"
if (-not (Test-Path $helperDll)) {
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    Get-ChildItem $InstallDir -Filter 'DiscordUi-*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition $helperSource -Language CSharp -OutputAssembly $helperDll -ReferencedAssemblies System.Core
}
Add-Type -Path $helperDll

# --- Theme ---------------------------------------------------------------------------------------

$dark = switch ($Theme) {
    'Dark'  { $true }
    'Light' { $false }
    default { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0 }
}
# Before/After are two shades of one hue (light shade = before); GoodText/BadText carry change direction next to an arrow
$C = if ($dark) {
    @{ Page = '#111111'; Surface = '#1A1A19'; Raised = '#242422'; Border = '#2C2C2A'; Text = '#FFFFFF'; Text2 = '#C3C2B7'; Muted = '#898781'
       Accent = '#3987E5'; AccentHover = '#5598E7'; OnAccent = '#FFFFFF'; Track = '#2C2C2A'; Good = '#0CA30C'; Warn = '#FAB219'; OnWarn = '#1A1A19'
       Before = '#1C5CAB'; After = '#6DA7EC'; GridLine = '#2C2C2A'; Baseline = '#383835'; GoodText = '#0CA30C'; BadText = '#E66767' }
} else {
    @{ Page = '#F3F3F1'; Surface = '#FCFCFB'; Raised = '#F0EFEC'; Border = '#E1E0D9'; Text = '#0B0B0B'; Text2 = '#52514E'; Muted = '#898781'
       Accent = '#2A78D6'; AccentHover = '#256ABF'; OnAccent = '#FFFFFF'; Track = '#E1E0D9'; Good = '#0CA30C'; Warn = '#FAB219'; OnWarn = '#1A1A19'
       Before = '#86B6EF'; After = '#1C5CAB'; GridLine = '#E1E0D9'; Baseline = '#C3C2B7'; GoodText = '#006300'; BadText = '#D03B3B' }
}

function Expand-Tokens([string]$Xaml) {
    foreach ($k in $C.Keys) { $Xaml = $Xaml.Replace("@@$k@@", $C[$k]) }
    $Xaml
}
function X([string]$Text) { [Security.SecurityElement]::Escape($Text) }

# --- Shared styles (both windows) ----------------------------------------------------------------

$styles = @'
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="@@Surface@@"/>
      <Setter Property="BorderBrush" Value="@@Border@@"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Heading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="@@Text2@@"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="@@Text2@@"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="@@OnAccent@@"/>
      <Setter Property="Background" Value="@@Accent@@"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="@@AccentHover@@"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="@@Text@@"/>
      <Setter Property="Background" Value="@@Raised@@"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="@@Border@@" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="@@Muted@@"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="@@Text2@@"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="t" Background="Transparent" Foreground="{TemplateBinding Foreground}"
                       Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="t" Property="TextDecorations" Value="Underline"/>
                <Setter TargetName="t" Property="Foreground" Value="@@Text@@"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="t" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="@@Raised@@"/>
      <Setter Property="Foreground" Value="@@Text@@"/>
      <Setter Property="BorderBrush" Value="@@Border@@"/>
      <Setter Property="Padding" Value="8,5"/>
    </Style>

    <!-- Slim scrollbars that match the theme (the stock ones are light grey even in dark mode) -->
    <ControlTemplate x:Key="ThumbTemplate" TargetType="Thumb">
      <Border CornerRadius="3" Background="@@Muted@@" Opacity="0.55" Margin="1"/>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Template="{StaticResource ThumbTemplate}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/>
          <Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track">
                  <Track.Thumb><Thumb Template="{StaticResource ThumbTemplate}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="@@Text@@"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="@@Muted@@"
                      Background="Transparent" VerticalAlignment="Top" Margin="0,1,0,0">
                <Path x:Name="tick" Data="M 3.2 7.6 L 6.4 10.8 L 12 4.6" Stroke="@@OnAccent@@" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="@@Accent@@"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="@@Accent@@"/>
                <Setter TargetName="box" Property="BorderBrush" Value="@@Accent@@"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

# --- Main window ----------------------------------------------------------------------------------

# One row per cache area, generated from $DiscordCleanAreas
$areaRows = foreach ($key in $DiscordCleanAreas.Keys) {
    $a = $DiscordCleanAreas[$key]
@"
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="Area_$key">
              <StackPanel>
                <TextBlock Text="$(X $a.Label)"/>
                <TextBlock Style="{StaticResource Hint}" Text="$(X $a.Hint)"/>
              </StackPanel>
            </CheckBox>
            <TextBlock x:Name="AreaSize_$key" Grid.Column="1" Margin="14,1,0,0" FontSize="12" Foreground="@@Text2@@" Text="-"/>
          </Grid>
"@
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Discord Optimizer" Width="620" SizeToContent="Height"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="@@Page@@" Foreground="@@Text@@" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$styles
  </Window.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto">
    <StackPanel Margin="20,16,20,8">

      <!-- Header -->
      <Grid Margin="2,0,2,14">
        <StackPanel>
          <TextBlock Text="Discord Optimizer" FontSize="22" FontWeight="SemiBold"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
            <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="@@Muted@@" VerticalAlignment="Center" Margin="0,1,7,0"/>
            <TextBlock x:Name="StatusText" Foreground="@@Text2@@" Text="Checking..."/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,0,0">
          <Button x:Name="ResultsBtn" Style="{StaticResource Link}" Content="Last results"/>
          <Button x:Name="ReportsBtn" Style="{StaticResource Link}" Content="Reports" Margin="16,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- Stat tiles -->
      <Grid Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/>
        </Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Margin="0" Padding="16,14">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="Discord memory"/>
            <TextBlock Margin="0,4,0,0"><Run x:Name="MemNum" Text="-" FontSize="26" FontWeight="SemiBold"/><Run x:Name="MemUnit" Text="" Foreground="@@Text2@@"/></TextBlock>
            <TextBlock x:Name="MemSub" Style="{StaticResource Label}" Foreground="@@Muted@@" Text=" "/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0" Padding="16,14">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="Cache"/>
            <TextBlock Margin="0,4,0,0"><Run x:Name="CacheNum" Text="-" FontSize="26" FontWeight="SemiBold"/><Run x:Name="CacheUnit" Text="" Foreground="@@Text2@@"/></TextBlock>
            <TextBlock x:Name="CacheSub" Style="{StaticResource Label}" Foreground="@@Muted@@" Text=" "/>
          </StackPanel>
        </Border>
        <Border Grid.Column="4" Style="{StaticResource Card}" Margin="0" Padding="16,14">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="Total on disk"/>
            <TextBlock Margin="0,4,0,0"><Run x:Name="DiskNum" Text="-" FontSize="26" FontWeight="SemiBold"/><Run x:Name="DiskUnit" Text="" Foreground="@@Text2@@"/></TextBlock>
            <TextBlock Style="{StaticResource Label}" Foreground="@@Muted@@" Text="app + data"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- Cache -->
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <Grid>
            <TextBlock Style="{StaticResource Heading}" Text="Cache"/>
            <Border x:Name="Chip" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="10" Padding="9,2" Background="@@Raised@@">
              <TextBlock x:Name="ChipText" FontSize="12" Foreground="@@Text2@@" Text="Checking"/>
            </Border>
          </Grid>
          <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,12"
                     Text="Images, scripts and GPU data Discord saves to disk. Clearing it is safe: you stay logged in."/>
          <Grid Height="8" Margin="0,0,0,6">
            <Grid.ColumnDefinitions>
              <ColumnDefinition x:Name="FillCol" Width="0*"/>
              <ColumnDefinition x:Name="RestCol" Width="100*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.ColumnSpan="2" CornerRadius="4" Background="@@Track@@"/>
            <Border x:Name="Fill" CornerRadius="4" Background="@@Accent@@"/>
          </Grid>
          <Grid>
            <TextBlock x:Name="BarText" Style="{StaticResource Label}" Foreground="@@Muted@@" Text=" "/>
            <Button x:Name="AreasToggle" Style="{StaticResource Link}" Content="Choose what to clear" HorizontalAlignment="Right"/>
          </Grid>
          <StackPanel x:Name="AreasPanel" Visibility="Collapsed" Margin="0,14,0,0">
$($areaRows -join "`n")
          </StackPanel>
          <Grid Margin="0,14,0,0">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <CheckBox x:Name="AutoClear" VerticalAlignment="Center"><TextBlock Text="Clear automatically when over"/></CheckBox>
              <TextBox x:Name="Limit" Width="58" Margin="10,0,6,0" Padding="5,3" Text="300" MaxLength="6"
                       HorizontalContentAlignment="Right" VerticalContentAlignment="Center"
                       Background="@@Raised@@" Foreground="@@Text@@" BorderBrush="@@Border@@" CaretBrush="@@Text@@"/>
              <TextBlock Text="MB" VerticalAlignment="Center" Foreground="@@Text2@@"/>
            </StackPanel>
            <Button x:Name="ClearBtn" Style="{StaticResource Secondary}" HorizontalAlignment="Right" Content="Clear now"/>
          </Grid>
          <TextBlock Style="{StaticResource Hint}" Foreground="@@Muted@@" Margin="28,4,0,0"
                     Text="The background helper checks while Discord is closed, e.g. at sign-in."/>
        </StackPanel>
      </Border>

      <!-- Optimize -->
      <Border Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Style="{StaticResource Heading}" Text="Optimize" Margin="0,0,0,12"/>

          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="OptDisk">
              <StackPanel>
                <TextBlock Text="Remove optional features" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Hint}" Text="Krisp, overlay, game detection, Rich Presence, Game SDK, Clips capture, spellcheck, extra languages. Keep those off in Discord or it downloads them again."/>
              </StackPanel>
            </CheckBox>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="14,3,0,0">
              <Ellipse x:Name="DotDisk" Width="7" Height="7" VerticalAlignment="Center" Fill="@@Muted@@"/>
              <TextBlock x:Name="StateDisk" Margin="6,0,0,0" FontSize="12" Foreground="@@Text2@@"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="OptGpu">
              <StackPanel>
                <TextBlock Text="Turn off hardware acceleration" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Hint}" Text="The biggest memory and VRAM saving. Video calls and screen sharing use more CPU."/>
              </StackPanel>
            </CheckBox>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="14,3,0,0">
              <Ellipse x:Name="DotGpu" Width="7" Height="7" VerticalAlignment="Center" Fill="@@Muted@@"/>
              <TextBlock x:Name="StateGpu" Margin="6,0,0,0" FontSize="12" Foreground="@@Text2@@"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="OptStartup">
              <StackPanel>
                <TextBlock Text="Don't start with Windows" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Hint}" Text="Discord only runs when you open it."/>
              </StackPanel>
            </CheckBox>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="14,3,0,0">
              <Ellipse x:Name="DotStartup" Width="7" Height="7" VerticalAlignment="Center" Fill="@@Muted@@"/>
              <TextBlock x:Name="StateStartup" Margin="6,0,0,0" FontSize="12" Foreground="@@Text2@@"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="OptHelper">
              <StackPanel>
                <TextBlock Text="Background helper" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Hint}" Text="Eases Discord off while it's in the background and silent, so games come first. About 0.03% CPU."/>
              </StackPanel>
            </CheckBox>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="14,3,0,0">
              <Ellipse x:Name="DotHelper" Width="7" Height="7" VerticalAlignment="Center" Fill="@@Muted@@"/>
              <TextBlock x:Name="StateHelper" Margin="6,0,0,0" FontSize="12" Foreground="@@Text2@@"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="OptMaintain">
              <StackPanel>
                <TextBlock Text="Keep it clean after updates" FontWeight="SemiBold"/>
                <TextBlock Style="{StaticResource Hint}" Text="Updates bring back removed features, every language and the old version. The helper removes them again while Discord is closed."/>
              </StackPanel>
            </CheckBox>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="14,3,0,0">
              <Ellipse x:Name="DotMaintain" Width="7" Height="7" VerticalAlignment="Center" Fill="@@Muted@@"/>
              <TextBlock x:Name="StateMaintain" Margin="6,0,0,0" FontSize="12" Foreground="@@Text2@@"/>
            </StackPanel>
          </Grid>

          <Border Height="1" Background="@@Border@@" Margin="0,0,0,14"/>

          <CheckBox x:Name="OptBench" Margin="0,0,0,16">
            <StackPanel>
              <TextBlock Text="Benchmark before and after" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Hint}" Text="Shows the results when done. Adds about 3 to 5 minutes; Discord restarts twice. Tick only this to just measure."/>
            </StackPanel>
          </CheckBox>

          <Grid>
            <Button x:Name="UndoBtn" Style="{StaticResource Link}" Content="Undo everything" HorizontalAlignment="Left" VerticalAlignment="Center"/>
            <Button x:Name="RunBtn" Style="{StaticResource Primary}" Content="Run" HorizontalAlignment="Right" MinWidth="128"/>
          </Grid>
        </StackPanel>
      </Border>

      <!-- Activity -->
      <Border Style="{StaticResource Card}" Padding="18,14">
        <StackPanel>
          <Grid>
            <TextBlock x:Name="Activity" Foreground="@@Text2@@" Text="Ready" TextTrimming="CharacterEllipsis" Margin="0,0,110,0"/>
            <Button x:Name="LogToggle" Style="{StaticResource Link}" Content="Show details" HorizontalAlignment="Right"/>
          </Grid>
          <ProgressBar x:Name="Busy" Height="3" Margin="0,10,0,0" Visibility="Collapsed" BorderThickness="0"
                       Foreground="@@Accent@@" Background="@@Track@@"/>
          <TextBox x:Name="Log" Visibility="Collapsed" Height="130" Margin="0,12,0,0" Padding="8" IsReadOnly="True"
                   FontFamily="Cascadia Mono, Consolas" FontSize="11.5" BorderThickness="0" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   Background="@@Page@@" Foreground="@@Text2@@"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </ScrollViewer>
</Window>
"@
$window = [Windows.Markup.XamlReader]::Parse((Expand-Tokens $xaml))
$window.MaxHeight = [Windows.SystemParameters]::WorkArea.Height   # scroll instead of running off small screens

$ui = @{}
foreach ($name in 'StatusDot', 'StatusText', 'MemNum', 'MemUnit', 'MemSub', 'CacheNum', 'CacheUnit', 'CacheSub', 'DiskNum', 'DiskUnit',
                  'Chip', 'ChipText', 'FillCol', 'RestCol', 'Fill', 'BarText', 'AreasToggle', 'AreasPanel', 'AutoClear', 'Limit', 'ClearBtn',
                  'OptDisk', 'DotDisk', 'StateDisk', 'OptGpu', 'DotGpu', 'StateGpu', 'OptStartup', 'DotStartup', 'StateStartup',
                  'OptHelper', 'DotHelper', 'StateHelper', 'OptMaintain', 'DotMaintain', 'StateMaintain',
                  'OptBench', 'UndoBtn', 'RunBtn', 'Activity', 'LogToggle', 'Busy', 'Log',
                  'ResultsBtn', 'ReportsBtn') {
    $ui[$name] = $window.FindName($name)
}
foreach ($key in $DiscordCleanAreas.Keys) {
    $ui["Area_$key"] = $window.FindName("Area_$key")
    $ui["AreaSize_$key"] = $window.FindName("AreaSize_$key")
}
$brush = @{}
foreach ($k in $C.Keys) { $brush[$k] = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($C[$k])) }

# --- Results pop-up --------------------------------------------------------------------------------

# Lower is better for every metric here
function Get-Delta($Before, $After, [int]$Digits, [string]$Unit) {
    if ($null -eq $Before -or $null -eq $After) { return $null }
    $diff = [double]$After - [double]$Before
    $pct = if ([double]$Before -ne 0) { $diff / [double]$Before * 100 } else { $null }
    if ([math]::Abs($diff) -lt [math]::Pow(10, -$Digits) -or ($null -ne $pct -and [math]::Abs($pct) -lt 1)) {
        return @{ Color = '@@Muted@@'; Text = 'No change' }
    }
    $arrow = if ($diff -lt 0) { [char]0x25BC } else { [char]0x25B2 }
    $word = if ($diff -lt 0) { 'less' } else { 'more' }
    $text = if ($null -ne $pct) { "$arrow $([math]::Abs([math]::Round($pct)))% $word" } else { "$arrow $word" }
    @{ Color = $(if ($diff -lt 0) { '@@GoodText@@' } else { '@@BadText@@' }); Text = $text }
}

function Format-Value($Value, [int]$Digits) {
    if ($null -eq $Value) { return [string][char]0x2014 }   # unavailable, e.g. GPU counters on non-English Windows
    ([double]$Value).ToString("N$Digits")
}

function New-ResultsWindow($Data) {
    $before = $Data.Before; $after = $Data.After
    $metrics = @(
        @{ Key = 'PrivateWS_MB'; Label = 'RAM';       Unit = 'MB'; Digits = 0 }
        @{ Key = 'VRAM_MB';      Label = 'VRAM';      Unit = 'MB'; Digits = 0 }
        @{ Key = 'CPU_core_pct'; Label = 'CPU';       Unit = '%';  Digits = 1 }
        @{ Key = 'GPU3D_pct';    Label = 'GPU';       Unit = '%';  Digits = 1 }
        @{ Key = 'Disk_MB';      Label = 'Disk';      Unit = 'MB'; Digits = 0 }
        @{ Key = 'Procs';        Label = 'Processes'; Unit = '';   Digits = 0 }
    )
    $tiles = foreach ($m in $metrics) {
        $a = $after.($m.Key); $b = if ($before) { $before.($m.Key) } else { $null }
        $d = Get-Delta $b $a $m.Digits $m.Unit
        $was = if ($before) { "was $(Format-Value $b $m.Digits) $($m.Unit)".Trim() } else { ' ' }
        $deltaXaml = if ($d) { "<TextBlock FontSize=`"12`" FontWeight=`"SemiBold`" Margin=`"0,4,0,0`" Foreground=`"$($d.Color)`" Text=`"$(X $d.Text)`"/>" } else { '' }
@"
        <Border Style="{StaticResource Card}" Padding="14,12" Margin="0,0,10,10">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="$($m.Label)"/>
            <TextBlock Margin="0,2,0,0"><Run Text="$(Format-Value $a $m.Digits)" FontSize="24" FontWeight="SemiBold"/><Run Text=" $($m.Unit)" Foreground="@@Text2@@"/></TextBlock>
            <TextBlock Style="{StaticResource Label}" Foreground="@@Muted@@" Text="$(X $was)"/>
            $deltaXaml
          </StackPanel>
        </Border>
"@
    }

    # Dumbbell: memory per process type, before (ring) -> after (dot), one axis in MB
    $types = @()
    foreach ($s in @($before, $after)) { if ($s -and $s.ByType) { $types += $s.ByType.PSObject.Properties.Name } }
    $rows = @($types | Select-Object -Unique | ForEach-Object {
        $type = $_
        # A process type missing from one run gets no marker rather than a fake 0
        $bv = if ($before -and $before.ByType -and $null -ne $before.ByType.$type) { [double]$before.ByType.$type } else { $null }
        $av = if ($after.ByType -and $null -ne $after.ByType.$type) { [double]$after.ByType.$type } else { $null }
        [pscustomobject]@{ Name = $type; B = $bv; A = $av; Max = [math]::Max([double]$bv, [double]$av) }
    } | Sort-Object Max -Descending)
    $max = ($rows | Measure-Object Max -Maximum).Maximum
    if (-not $max) { $max = 1 }
    $step = [math]::Pow(10, [math]::Floor([math]::Log10([math]::Max($max, 1))))
    foreach ($mult in 1, 2, 5, 10) { if ($max / ($step * $mult) -le 5) { $step *= $mult; break } }
    $niceMax = [math]::Max($step, [math]::Ceiling($max / $step) * $step)
    $plotW = 360
    $xOf = { param($v) [int][math]::Round($plotW * [double]$v / $niceMax) }
    $ticks = @(); for ($g = 0; $g -le $niceMax + 0.001; $g += $step) { $ticks += $g }
    $gridLines = ($ticks | ForEach-Object { "<Line X1=`"$(& $xOf $_)`" Y1=`"0`" X2=`"$(& $xOf $_)`" Y2=`"30`" Stroke=`"$(if ($_ -eq 0) { '@@Baseline@@' } else { '@@GridLine@@' })`" StrokeThickness=`"1`"/>" }) -join ''

    $rowXaml = foreach ($r in $rows) {
        $parts = @()
        if ($null -ne $r.B -and $null -ne $r.A) { $parts += "<Line X1=`"$(& $xOf $r.B)`" Y1=`"15`" X2=`"$(& $xOf $r.A)`" Y2=`"15`" Stroke=`"@@Baseline@@`" StrokeThickness=`"2`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`"/>" }
        if ($null -ne $r.B) { $parts += "<Ellipse Canvas.Left=`"$((& $xOf $r.B) - 5)`" Canvas.Top=`"10`" Width=`"10`" Height=`"10`" Fill=`"@@Surface@@`" Stroke=`"@@Before@@`" StrokeThickness=`"2`"/>" }
        if ($null -ne $r.A) { $parts += "<Ellipse Canvas.Left=`"$((& $xOf $r.A) - 6)`" Canvas.Top=`"9`" Width=`"12`" Height=`"12`" Fill=`"@@After@@`" Stroke=`"@@Surface@@`" StrokeThickness=`"2`"/>" }
        $label = if ($null -ne $r.A) { $r.A } else { $r.B }
        $parts += "<TextBlock Canvas.Left=`"$((& $xOf $r.Max) + 12)`" Canvas.Top=`"7`" FontSize=`"12`" Foreground=`"@@Text@@`" Text=`"$(Format-Value $label 0)`"/>"
        $tip = if ($null -ne $r.B -and $null -ne $r.A) {
            $d = Get-Delta $r.B $r.A 0 'MB'
            "$($r.Name): $(Format-Value $r.B 0) MB $Arrow $(Format-Value $r.A 0) MB ($($d.Text))"
        } else { "$($r.Name): $(Format-Value $label 0) MB" }
@"
          <Grid Height="30" Background="Transparent" ToolTip="$(X $tip)">
            <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <TextBlock VerticalAlignment="Center" Foreground="@@Text2@@" Text="$(X $r.Name)"/>
            <Canvas Grid.Column="1">$gridLines$($parts -join '')</Canvas>
          </Grid>
"@
    }
    $tickLabels = ($ticks | ForEach-Object { "<TextBlock Canvas.Left=`"$((& $xOf $_) - 12)`" Width=`"24`" TextAlignment=`"Center`" FontSize=`"11`" Foreground=`"@@Muted@@`" Text=`"$(Format-Value $_ 0)`"/>" }) -join ''

    $changes = (@($Data.Changes) | Where-Object { $_ } | Select-Object -First 7 | ForEach-Object {
        "<TextBlock Style=`"{StaticResource Hint}`" Text=`"$([char]0x2022)  $(X $_)`"/>"
    }) -join "`n"
    $subtitle = @()
    if ($after.Version) { $subtitle += 'Discord ' + ($after.Version -replace '^app-') }
    if ($before) { $subtitle += "before $($before.Time)" }
    $subtitle += $(if ($before) { "after $($after.Time)" } else { "measured $($after.Time)" })
    $legend = if ($before) {
        "<StackPanel Orientation=`"Horizontal`" Margin=`"0,6,0,6`"><Ellipse Width=`"10`" Height=`"10`" Fill=`"@@Surface@@`" Stroke=`"@@Before@@`" StrokeThickness=`"2`" VerticalAlignment=`"Center`"/><TextBlock Text=`"Before`" Margin=`"6,0,16,0`" FontSize=`"12`" Foreground=`"@@Text2@@`"/><Ellipse Width=`"12`" Height=`"12`" Fill=`"@@After@@`" VerticalAlignment=`"Center`"/><TextBlock Text=`"After`" Margin=`"6,0,0,0`" FontSize=`"12`" Foreground=`"@@Text2@@`"/></StackPanel>"
    } else { '' }

    $resultsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Benchmark results" Width="600" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="@@Page@@" Foreground="@@Text@@" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$styles
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto">
    <StackPanel Margin="20,16,10,16">
      <TextBlock Text="Benchmark results" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock Foreground="@@Text2@@" Margin="0,4,0,14" Text="$(X ($subtitle -join "  $Dot  "))"/>
      <UniformGrid Columns="3">
$($tiles -join "`n")
      </UniformGrid>
      <Border Style="{StaticResource Card}" Margin="0,0,10,10">
        <StackPanel>
          <TextBlock Style="{StaticResource Heading}" Text="Memory by Discord process"/>
          <TextBlock Style="{StaticResource Hint}" Text="$(if ($before) { 'MB, as Task Manager counts it. Hover a row for the exact change.' } else { 'MB, as Task Manager counts it.' })"/>
          $legend
$($rowXaml -join "`n")
          <Grid Height="18">
            <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Canvas Grid.Column="1">$tickLabels</Canvas>
          </Grid>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource Card}" Margin="0,0,10,14">
        <StackPanel>
          <TextBlock Style="{StaticResource Heading}" Text="$(if ($changes) { 'What changed' } else { 'Notes' })" Margin="0,0,0,4"/>
$changes
          <TextBlock Style="{StaticResource Hint}" Foreground="@@Muted@@" Margin="0,8,0,0" Text="$(X $Data.Method)"/>
        </StackPanel>
      </Border>
      <Grid Margin="0,0,10,0">
        <Button x:Name="OpenReport" Style="{StaticResource Secondary}" Content="Open full report" HorizontalAlignment="Left"/>
        <Button x:Name="CloseResults" Style="{StaticResource Primary}" Content="Close" HorizontalAlignment="Right" MinWidth="110"/>
      </Grid>
    </StackPanel>
  </ScrollViewer>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Parse((Expand-Tokens $resultsXaml))
    $win.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
    $win.Tag = [string]$Data.Report
    $win.FindName('OpenReport').IsEnabled = $Data.Report -and (Test-Path ([string]$Data.Report))
    $win.FindName('OpenReport').Add_Click({ param($s) Invoke-Item ([Windows.Window]::GetWindow($s).Tag) })
    $win.FindName('CloseResults').Add_Click({ param($s) [Windows.Window]::GetWindow($s).Close() })
    $win.Add_SourceInitialized({ param($s) [DiscordUi.Win]::SetDarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $s).Handle, $dark) })
    $win
}

function Show-Results {
    if (-not (Test-Path $LastBench)) {
        [void][Windows.MessageBox]::Show($window, 'No benchmark yet. Tick "Benchmark before and after" and press Run.', 'Discord Optimizer')
        return
    }
    try {
        $win = New-ResultsWindow (Get-Content $LastBench -Raw | ConvertFrom-Json)
        $win.Owner = $window
        $win.WindowStartupLocation = 'CenterOwner'
        [void]$win.ShowDialog()
    }
    catch { [void][Windows.MessageBox]::Show($window, "Couldn't show the results: $($_.Exception.Message)", 'Discord Optimizer') }
}

# --- State ----------------------------------------------------------------------------------------

$runner = New-Object DiscordUi.Runner
$script:taskLabel = ''
$script:lastLine  = ''
$script:sawError  = $false
$script:taskClock = $null
$script:taskStart = Get-Date
$script:taskBench = $false
$script:taskDone  = $false
$script:firstState = $true
$script:appliedLimit = 0

function Get-Config {
    $config = [pscustomobject]@{ LimitMB = 300; Areas = @($DiscordCleanAreas.Keys | Where-Object { $DiscordCleanAreas[$_].Default }) }
    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($saved.LimitMB) { $config.LimitMB = $saved.LimitMB }
            if ($null -ne $saved.Areas) { $config.Areas = @($saved.Areas) }   # older ui.json files have no Areas
        } catch { }
    }
    $config
}

function Get-Limit {
    $v = 0
    if ([int]::TryParse($ui.Limit.Text.Trim(), [ref]$v) -and $v -ge 50) { return $v }
    $null
}

function Get-SelectedAreas { @($DiscordCleanAreas.Keys | Where-Object { $ui["Area_$_"].IsChecked }) }

function Save-Config {
    $limit = Get-Limit
    if (-not $limit) { $limit = (Get-Config).LimitMB }
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    [pscustomobject]@{ LimitMB = $limit; Areas = @(Get-SelectedAreas) } | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
}

function Get-HelperRunValue { [string](Get-ItemProperty $RunKey -ErrorAction SilentlyContinue).DiscordGovernor }

# Rebuilding the helper replaces all of its options, so carry over the ones this click isn't about
function Get-HelperArgs([bool]$AutoClear, [bool]$Maintain) {
    $a = '-Governor'
    if ((Get-HelperRunValue) -match '--restart-above-mb (\d+)') { $a += " -RestartAboveMB $($Matches[1])" }
    if ($AutoClear -and (Get-Limit)) { $a += " -ClearCacheAboveMB $(Get-Limit)" }
    if ($Maintain) { $a += ' -Maintain' }
    $a
}

function Add-Log([string]$Line) {
    if ($ui.Log.Text.Length -gt 200000) { $ui.Log.Text = $ui.Log.Text.Substring(100000) }
    $ui.Log.AppendText($Line + "`r`n")
    $ui.Log.ScrollToEnd()
}

function Set-Busy([bool]$On) {
    $names = @('RunBtn', 'ClearBtn', 'UndoBtn', 'AutoClear', 'Limit', 'OptDisk', 'OptGpu', 'OptStartup', 'OptHelper', 'OptMaintain', 'OptBench') +
             @($DiscordCleanAreas.Keys | ForEach-Object { "Area_$_" })
    foreach ($n in $names) { $ui[$n].IsEnabled = -not $On }
    $ui.Busy.IsIndeterminate = $On
    $ui.Busy.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
}

function Start-Task([string]$Label, [string]$Arguments) {
    # e.g. the limit box losing focus and a button click landing together; never run two at once
    if ($runner.Busy) { return }
    $script:taskLabel = $Label
    $script:lastLine  = 'starting'
    $script:sawError  = $false
    $script:taskDone  = $false
    $script:taskStart = Get-Date
    $script:taskBench = $Arguments -match '-Benchmark'
    $script:taskClock = [Diagnostics.Stopwatch]::StartNew()
    Add-Log ''
    Add-Log ("== {0}  {1:HH:mm:ss}  Optimize-Discord.ps1 {2}" -f $Label, (Get-Date), $Arguments)
    Set-Busy $true
    try { $runner.Start($Optimizer, $Arguments) }
    catch {
        Add-Log "! Couldn't start: $($_.Exception.Message)"
        $ui.Activity.Text = "$Label couldn't start. Show details for the log."
        $script:taskDone = $true
        Set-Busy $false
    }
}

function Confirm-Action([string]$Message) {
    [Windows.MessageBox]::Show($window, $Message, 'Discord Optimizer', 'OKCancel', 'None') -eq 'OK'
}

function Set-Row([string]$Name, [bool]$Active, [string]$OnText, [string]$OffText) {
    $ui["Dot$Name"].Fill = if ($Active) { $brush.Good } else { $brush.Muted }
    $ui["State$Name"].Text = if ($Active) { $OnText } else { $OffText }
}

function Format-Size([long]$Bytes) {
    if ($Bytes -lt 0) { return '-' }
    if ($Bytes -lt 1MB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    '{0:N2} GB' -f ($Bytes / 1GB)
}

# Tell the sampler which files each cache area covers (they change as Discord updates and logs)
function Update-Targets {
    $t = Get-DiscordCleanTargets
    $names = [string[]]@($t.Keys)
    $paths = New-Object 'string[][]' $names.Count
    for ($i = 0; $i -lt $names.Count; $i++) { $paths[$i] = [string[]]@($t[$names[$i]]) }
    [DiscordUi.Stats]::SetAreas($names, $paths)
}

function Update-State {
    $install = Get-DiscordInstall
    $run = Get-ItemProperty $RunKey -ErrorAction SilentlyContinue
    # Discord, DiscordPTB or DiscordCanary: each has its own settings folder and autostart entry
    $flavor = if ($install) { $install.Flavor } else { 'Discord' }
    $modulesLeft = if ($install) {
        @(Get-ChildItem (Join-Path $install.App.FullName 'modules') -Directory -ErrorAction SilentlyContinue |
          Where-Object { ($_.Name -replace '-\d+$') -in $DiscordOptionalModules }).Count
    } else { -1 }
    $gpuOff = $false
    $settingsFile = Join-Path $env:APPDATA "$($flavor.ToLower())\settings.json"
    if (Test-Path $settingsFile) { try { $gpuOff = (Get-Content $settingsFile -Raw | ConvertFrom-Json).enableHardwareAcceleration -eq $false } catch { } }
    $helperInstalled = [bool]$run.DiscordGovernor
    $helperRunning = [DiscordUi.Stats]::HelperRunning

    Set-Row 'Disk' ($modulesLeft -eq 0) 'Applied' $(if ($modulesLeft -gt 0) { 'Not applied' } else { 'Not installed' })
    Set-Row 'Gpu' $gpuOff 'Applied' 'Not applied'
    Set-Row 'Startup' (-not $run.$flavor) 'Applied' 'Not applied'
    Set-Row 'Helper' ($helperInstalled -and $helperRunning) 'Running' $(if ($helperInstalled) { 'Installed, not running' } else { 'Not installed' })
    $maintainOn = $helperInstalled -and ([string]$run.DiscordGovernor -match '--maintain')
    Set-Row 'Maintain' ($maintainOn -and $helperRunning) 'Running' $(if ($maintainOn) { 'Helper not running' } else { 'Not applied' })

    if ($script:firstState) {
        # Pre-tick whatever isn't in effect yet
        $script:firstState = $false
        $ui.OptDisk.IsChecked    = $modulesLeft -gt 0
        $ui.OptGpu.IsChecked     = -not $gpuOff
        $ui.OptStartup.IsChecked = [bool]$run.$flavor
        $ui.OptHelper.IsChecked  = -not $helperInstalled
        $ui.OptMaintain.IsChecked = -not $maintainOn
        $config = Get-Config
        foreach ($key in $DiscordCleanAreas.Keys) { $ui["Area_$key"].IsChecked = @($config.Areas) -contains $key }
        if ($run.DiscordGovernor -match '--clear-cache-above-mb (\d+)') {
            $ui.AutoClear.IsChecked = $true
            $ui.Limit.Text = $Matches[1]
            $script:appliedLimit = [int]$Matches[1]
        }
        else { $ui.Limit.Text = [string]$config.LimitMB }
        if (-not $install) {
            $ui.RunBtn.IsEnabled = $false
            $ui.ClearBtn.IsEnabled = $false
        }
    }
}

function Set-Big($Num, $Unit, [long]$MB) {
    if ($MB -lt 0) { $Num.Text = '-'; $Unit.Text = ''; return }
    if ($MB -ge 10240) { $Num.Text = '{0:N1}' -f ($MB / 1024); $Unit.Text = ' GB' }
    else { $Num.Text = '{0:N0}' -f $MB; $Unit.Text = ' MB' }
}

function Update-Stats {
    $mem = [DiscordUi.Stats]::MemoryMB
    $procs = [DiscordUi.Stats]::Processes
    $install = Get-DiscordInstall

    # Cache = the areas that are actually cache (not updater leftovers or the installer)
    $cacheBytes = -1
    foreach ($key in $DiscordCleanAreas.Keys) {
        $b = [DiscordUi.Stats]::AreaBytes($key)
        $ui["AreaSize_$key"].Text = Format-Size $b
        if ($b -ge 0 -and $DiscordCleanAreas[$key].Cache) { $cacheBytes = [math]::Max($cacheBytes, 0) + $b }
    }
    $cache = if ($cacheBytes -ge 0) { [long][math]::Round($cacheBytes / 1MB) } else { -1 }

    Set-Big $ui.MemNum $ui.MemUnit $mem
    $ui.MemSub.Text = if ($procs) { "$procs processes" } else { 'not running' }
    Set-Big $ui.CacheNum $ui.CacheUnit $cache
    Set-Big $ui.DiskNum $ui.DiskUnit ([DiscordUi.Stats]::DiskMB)

    $parts = @()
    if (-not $install) { $parts += "Discord isn't installed" }
    elseif ($procs) { $parts += 'Discord is running' } else { $parts += 'Discord is closed' }
    if ($install) { $parts += 'version ' + $install.Version }
    $parts += $(if ([DiscordUi.Stats]::HelperRunning) { 'helper active' } else { 'helper off' })
    $vencord = Get-VencordState
    if ($vencord -eq 'active') { $parts += 'Vencord active' }
    elseif ($vencord -eq 'needs-repair') { $parts += "$([char]0x26A0) Vencord needs repair" }
    $ui.StatusText.Text = $parts -join "  $Dot  "
    $ui.StatusText.ToolTip = if ($vencord -eq 'needs-repair') { "A Discord update replaced the files Vencord hooks into, so it isn't loading. Run the Vencord installer and choose Repair." } else { $null }
    $ui.StatusDot.Fill = if ($vencord -eq 'needs-repair') { $brush.Warn } elseif ($procs) { $brush.Good } else { $brush.Muted }

    $limit = Get-Limit
    if ($cache -ge 0 -and $limit) {
        $pct = [math]::Min(100, [math]::Max($(if ($cacheBytes -gt 0) { 1 } else { 0 }), $cacheBytes / 1MB / $limit * 100))
        $ui.FillCol.Width = New-Object Windows.GridLength ($pct, 'Star')
        $ui.RestCol.Width = New-Object Windows.GridLength ((100 - $pct), 'Star')
        $over = $cache -gt $limit
        $ui.Fill.Background = if ($over) { $brush.Warn } else { $brush.Accent }
        $ui.Chip.Background = if ($over) { $brush.Warn } else { $brush.Raised }
        $ui.ChipText.Foreground = if ($over) { $brush.OnWarn } else { $brush.Text2 }
        $ui.ChipText.Text = if ($over) { "$([char]0x26A0) Over limit" } else { 'Healthy' }
        $ui.BarText.Text = '{0:N0} MB of your {1:N0} MB limit' -f $cache, $limit
        $ui.CacheSub.Text = 'limit {0:N0} MB' -f $limit
    }
}

# --- Events ---------------------------------------------------------------------------------------

$ui.RunBtn.Add_Click({
    $parts = @()
    if ($ui.OptDisk.IsChecked)    { $parts += '-Disk' }
    if ($ui.OptGpu.IsChecked)     { $parts += '-NoGpu' }
    if ($ui.OptStartup.IsChecked) { $parts += '-NoStartup' }
    if ($ui.OptHelper.IsChecked -or $ui.OptMaintain.IsChecked) {
        # "Keep it clean" runs inside the helper, so either box (re)installs it
        $maintain = [bool]$ui.OptMaintain.IsChecked -or ((Get-HelperRunValue) -match '--maintain')
        $parts += Get-HelperArgs ([bool]$ui.AutoClear.IsChecked) $maintain
    }
    $bench = [bool]$ui.OptBench.IsChecked
    if (-not $parts -and -not $bench) {
        [void][Windows.MessageBox]::Show($window, 'Tick at least one option first.', 'Discord Optimizer')
        return
    }
    $label = if (-not $parts) { 'Measuring' } else { 'Optimizing' }
    if ($bench) { $parts += '-Benchmark -NoOpen' }
    $restarts = $ui.OptDisk.IsChecked -or $ui.OptGpu.IsChecked -or $bench
    if ($restarts -and [DiscordUi.Stats]::Processes -gt 0) {
        $msg = if ($bench) { 'Discord will close and reopen twice over the next 3 to 5 minutes. Leave any voice call first.' }
               else { 'Discord will close and reopen. Leave any voice call first.' }
        if (-not (Confirm-Action $msg)) { return }
    }
    Start-Task $label ($parts -join ' ')
})

$ui.ClearBtn.Add_Click({
    $areas = Get-SelectedAreas
    if (-not $areas) {
        $ui.AreasPanel.Visibility = 'Visible'; $ui.AreasToggle.Content = 'Hide list'
        [void][Windows.MessageBox]::Show($window, 'Tick at least one thing to clear.', 'Discord Optimizer')
        return
    }
    Save-Config
    $what = ($areas | ForEach-Object { $DiscordCleanAreas[$_].Label.ToLower() }) -join ', '
    $msg = "Clear ${what}?" + $(if ([DiscordUi.Stats]::Processes -gt 0) { "`n`nDiscord will close and reopen. You stay logged in. Leave any voice call first." } else { '' })
    if (-not (Confirm-Action $msg)) { return }
    Start-Task 'Clearing' "-ClearCache -Areas $($areas -join ',')"
})

$ui.AreasToggle.Add_Click({
    $show = $ui.AreasPanel.Visibility -ne 'Visible'
    $ui.AreasPanel.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    $ui.AreasToggle.Content = if ($show) { 'Hide list' } else { 'Choose what to clear' }
})
foreach ($key in $DiscordCleanAreas.Keys) { $ui["Area_$key"].Add_Click({ Save-Config }) }

$ui.UndoBtn.Add_Click({
    if (-not (Confirm-Action 'Put everything back: features, hardware acceleration and settings are restored and the background helper is removed. Discord will restart.')) { return }
    Start-Task 'Undoing' '-Restore'
})

$ui.AutoClear.Add_Click({
    $limit = Get-Limit
    if ($ui.AutoClear.IsChecked -and -not $limit) {
        [void][Windows.MessageBox]::Show($window, 'Enter a limit of at least 50 MB first.', 'Discord Optimizer')
        $ui.AutoClear.IsChecked = $false
        return
    }
    Save-Config
    $helperInstalled = [bool](Get-ItemProperty $RunKey -ErrorAction SilentlyContinue).DiscordGovernor
    if ($ui.AutoClear.IsChecked -or $helperInstalled) {
        $script:appliedLimit = if ($ui.AutoClear.IsChecked) { $limit } else { 0 }
        Start-Task 'Updating the background helper' (Get-HelperArgs ([bool]$ui.AutoClear.IsChecked) ((Get-HelperRunValue) -match '--maintain'))
    }
})

# Apply a new limit when the box loses focus or Enter is pressed
$applyLimit = {
    # Focus also leaves the box while the window closes; a task started then would run with nobody watching
    if ($script:closing) { return }
    $limit = Get-Limit
    if (-not $limit) { return }
    Save-Config
    Update-Stats
    if ($ui.AutoClear.IsChecked -and $limit -ne $script:appliedLimit -and -not $runner.Busy) {
        $script:appliedLimit = $limit
        Start-Task 'Updating the background helper' (Get-HelperArgs $true ((Get-HelperRunValue) -match '--maintain'))
    }
}
$ui.Limit.Add_LostFocus($applyLimit)
$ui.Limit.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $applyLimit } })

$ui.LogToggle.Add_Click({
    $show = $ui.Log.Visibility -ne 'Visible'
    $ui.Log.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    $ui.LogToggle.Content = if ($show) { 'Hide details' } else { 'Show details' }
})

$ui.ResultsBtn.Add_Click({ Show-Results })

$ui.ReportsBtn.Add_Click({
    $reports = Join-Path $InstallDir 'reports'
    if (Test-Path $reports) { Invoke-Item $reports }
    else { [void][Windows.MessageBox]::Show($window, 'No reports yet. Tick "Benchmark before and after" and press Run.', 'Discord Optimizer') }
})

$window.Add_SourceInitialized({
    [DiscordUi.Win]::SetDarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $window).Handle, $dark)
})

$window.Add_Closing({
    param($s, $e)
    if ($runner.Busy) {
        $e.Cancel = $true
        [void][Windows.MessageBox]::Show($window, 'Wait for the current task to finish first.', 'Discord Optimizer')
    }
    else { $script:closing = $true }
})

# One timer drives everything on the UI thread: task output every 0.5 s, stats every 2 s,
# option states every 5 s, cache targets every 30 s
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:tick = 0
$timer.Add_Tick({
  # An unexpected error here must not take the whole window down; it goes to the log instead
  try {
    foreach ($line in $runner.Drain()) {
        Add-Log $line
        if ($line.StartsWith('! ')) { $script:sawError = $true }
        $t = $line.Trim()
        if ($t -and $t -notmatch '^[-=\s]+$' -and $t -notmatch '^(Metric\s|-{3})') { $script:lastLine = $t }
    }
    if ($runner.Busy) {
        $ui.Activity.Text = '{0}  {1:m\:ss}  {2}  {3}' -f $script:taskLabel, $script:taskClock.Elapsed, $Dot, $script:lastLine
    }
    elseif ($runner.Finished) {
        foreach ($line in $runner.Drain()) { Add-Log $line; if ($line.StartsWith('! ')) { $script:sawError = $true } }
        $ok = $runner.ExitCode -eq 0 -and -not $script:sawError
        $ui.Activity.Text = if ($ok) { '{0}: done in {1:m\:ss}' -f $script:taskLabel, $script:taskClock.Elapsed }
                            else { "$($script:taskLabel): finished with problems. Show details for the log." }
        $runner.Reset()
        $script:taskDone = $true
        Set-Busy $false
        Update-Targets
        Update-State
        # Pop the results up when this task produced a fresh benchmark
        if ($script:taskBench -and (Test-Path $LastBench) -and (Get-Item $LastBench).LastWriteTime -gt $script:taskStart) { Show-Results }
    }
    $script:tick++
    if ($script:tick % 4 -eq 0) { Update-Stats }
    if ($script:tick % 10 -eq 0 -and -not $runner.Busy) { Update-State }
    if ($script:tick % 60 -eq 0 -and -not $runner.Busy) { Update-Targets }
  }
  catch { Add-Log "! $($_.Exception.Message)" }
})

# --- Test hook: render to PNG without showing anything on screen ----------------------------------

function Save-Png($Win, [string]$Path) {
    $Win.UpdateLayout()
    $content = $Win.Content
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][math]::Ceiling($content.ActualWidth)), ([int][math]::Ceiling($content.ActualHeight)), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($Win)
    $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path)
    $png.Save($fs); $fs.Close()
}

if ($Screenshot -and $PreviewResults) {
    $win = New-ResultsWindow (Get-Content $PreviewResults -Raw | ConvertFrom-Json)
    $win.WindowStartupLocation = 'Manual'; $win.Left = -5000; $win.Top = 0; $win.ShowActivated = $false
    $win.Add_ContentRendered({ param($s) Save-Png $s $Screenshot; $s.Close() })
    [void]$win.ShowDialog()
    return
}

if ($Screenshot) {
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -5000; $window.Top = 0
    $window.ShowActivated = $false; $window.ShowInTaskbar = $false
    $shot = New-Object Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromSeconds(5)
    $shot.Add_Tick({
        if ($SelfTest -and -not $script:taskDone) { return }   # keep waiting for the task
        $shot.Stop()
        Update-Stats
        Save-Png $window $Screenshot
        $window.Close()
    })
    $window.Add_ContentRendered({
        if ($ExpandAreas) { $ui.AreasPanel.Visibility = 'Visible'; $ui.AreasToggle.Content = 'Hide list' }
        if ($SelfTest) {
            $ui.Log.Visibility = 'Visible'; $ui.LogToggle.Content = 'Hide details'
            Start-Task 'Self-test' '-ClearCache -Areas Media,Gpu -WhatIf'
        }
        $shot.Start()
    })
}

Update-Targets
[DiscordUi.Stats]::Start()
Update-State
Update-Stats
$timer.Start()
[void]$window.ShowDialog()
$timer.Stop()
