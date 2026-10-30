param(
    [Parameter(Position = 0)][string]$Apk,
    [string]$Lang,               # forza una lingua, es. -Lang de (default: la lingua di Windows)
    [string]$PreviewPng,         # salva il popup in questo PNG ed esce (per i test)
    [string]$PreviewKey,         # con -PreviewPng: mostra anche questo messaggio nella zona di stato
    [switch]$ParseOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Adb      = Join-Path $Root 'bin\adb\adb.exe'
$Aapt2    = Join-Path $Root 'bin\aapt2\aapt2.exe'
$WsaClient = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\WsaClient.exe'
$WsaAppId = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$Endpoint = '127.0.0.1:58526'

# ---------- language ----------
# I testi stanno in strings.json (accanto a questo script). Si usa la lingua di Windows, inglese se manca.
# Si può forzare con -Lang o con la variabile WSA_APK_LANG.
$Strings = @{}
try {
    $parsed = [IO.File]::ReadAllText((Join-Path $Root 'strings.json')) | ConvertFrom-Json
    foreach ($p in $parsed.PSObject.Properties) {
        $d = @{}
        foreach ($q in $p.Value.PSObject.Properties) { $d[$q.Name] = [string]$q.Value }
        $Strings[$p.Name] = $d
    }
} catch { }

$WantedLang = $Lang
if (-not $WantedLang) { $WantedLang = $env:WSA_APK_LANG }
if (-not $WantedLang) { $WantedLang = [Globalization.CultureInfo]::CurrentUICulture.Name }
$WantedLang = "$WantedLang".Trim().Replace('_', '-')

function Resolve-Language([string]$Wanted) {
    if (-not $Wanted) { return 'en' }
    $keys = @($Strings.Keys)
    $hit = $keys | Where-Object { $_ -ieq $Wanted } | Select-Object -First 1
    if ($hit) { return $hit }
    $prefix = $Wanted.Split('-')[0].ToLowerInvariant()
    if ($prefix -eq 'zh') {      # cinese: tradizionale per Taiwan, Hong Kong, Macao (o Hant esplicito), semplificato negli altri casi
        if ($Wanted -match '(?i)hant|-tw$|-hk$|-mo$') { return 'zh-Hant' }
        return 'zh-Hans'
    }
    $hit = $keys | Where-Object { $_ -ieq $prefix } | Select-Object -First 1
    if ($hit) { return $hit }
    'en'
}
$LangCode = Resolve-Language $WantedLang
$RightToLeft = @('ar', 'he', 'fa', 'ur') -contains $LangCode.Split('-')[0]

# racchiude i pezzi in caratteri latini (ABI, indirizzo, API) così non si rimescolano nel testo da destra a sinistra
function Isolate([string]$s) { ([string][char]0x2066) + $s + ([string][char]0x2069) }

# Txt 'chiave' [argomenti]  ->  il testo nella lingua scelta ({0}, {1} presi dagli argomenti)
function Txt([string]$Key) {
    $s = $null
    if ($Strings.ContainsKey($LangCode)) { $s = $Strings[$LangCode][$Key] }
    if ($null -eq $s -and $Strings.ContainsKey('en')) { $s = $Strings['en'][$Key] }
    if ($null -eq $s) { return $Key }
    if ($args.Count -gt 0) { return [string]::Format($s, [object[]]$args) }
    $s
}

# ---------- tool helpers ----------

function ConvertTo-ArgLine([string[]]$Arguments) {
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Start-ToolProcess([string]$File, [string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ConvertTo-ArgLine $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    @{ Proc = $p; OutTask = $p.StandardOutput.ReadToEndAsync(); ErrTask = $p.StandardError.ReadToEndAsync() }
}

function Invoke-Tool([string]$File, [string[]]$Arguments) {
    $j = Start-ToolProcess $File $Arguments
    $j.Proc.WaitForExit()
    @{ Out = $j.OutTask.Result; Err = $j.ErrTask.Result; Code = $j.Proc.ExitCode }
}

# ---------- APK parsing ----------

function Get-ApkInfo([string]$Path) {
    $r = Invoke-Tool $Aapt2 @('dump', 'badging', $Path)
    if (-not $r.Out) { throw ((Txt 'err_read_apk') + "`n" + $r.Err) }
    $text = $r.Out
    $q = "'((?:[^'\\]|\\.)*)'"
    $unesc = { param($s) $s -replace "\\'", "'" }

    $m = [regex]::Match($text, "package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'")
    if (-not $m.Success) { throw (Txt 'err_not_apk') }
    $package = $m.Groups[1].Value
    $version = $m.Groups[3].Value

    $ui = $WantedLang          # il nome dell'app lo prendo nella stessa lingua del popup
    if (-not $ui) { $ui = 'en' }
    $label = $null
    foreach ($c in @("application-label-$ui", "application-label-$($ui.Split('-')[0])", 'application-label')) {
        $lm = [regex]::Match($text, '(?m)^' + [regex]::Escape($c) + ':' + $q)
        if ($lm.Success) { $label = & $unesc $lm.Groups[1].Value; break }
    }
    if (-not $label) { $label = $package }

    $iconPath = $null
    $im = [regex]::Match($text, "(?m)^application: .*icon='([^']*)'")
    if ($im.Success) { $iconPath = $im.Groups[1].Value }

    $abis = @()
    $nm = [regex]::Match($text, '(?m)^native-code: (.*)$')
    if ($nm.Success) { $abis = @([regex]::Matches($nm.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }

    $sdk = $null
    $sm = [regex]::Match($text, "(?m)^minSdkVersion:'(\d+)'")
    if ($sm.Success) { $sdk = $sm.Groups[1].Value }

    [pscustomobject]@{
        Label    = $label
        Package  = $package
        Version  = $version
        MinSdk   = $sdk
        Abis     = $abis
        IconPath = $iconPath
        SizeMB   = [Math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
    }
}

# ---------- icon extraction ----------

function Read-ZipEntry($Entry) {
    $s = $Entry.Open()
    try {
        $ms = New-Object IO.MemoryStream
        $s.CopyTo($ms)
        , $ms.ToArray()
    } finally { $s.Dispose() }
}

function Get-DensityRank([string]$Name) {
    $m = [regex]::Match($Name, '-(xxxhdpi|xxhdpi|xhdpi|hdpi|mdpi|ldpi)')
    if (-not $m.Success) { return 0 }
    @{ xxxhdpi = 6; xxhdpi = 5; xhdpi = 4; hdpi = 3; mdpi = 2; ldpi = 1 }[$m.Groups[1].Value]
}

function ConvertTo-BitmapImage([byte[]]$Bytes) {
    $ms = New-Object IO.MemoryStream (, $Bytes)
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = 'OnLoad'
    $bi.StreamSource = $ms
    $bi.EndInit()
    $bi.Freeze()
    $bi
}

function New-CompositeIcon([byte[]]$Background, [byte[]]$Foreground) {
    $size = 432
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    # i livelli sono 108dp e se ne vedono 72 al centro: li disegno 1.5x
    $rect = New-Object Windows.Rect (-0.25 * $size), (-0.25 * $size), (1.5 * $size), (1.5 * $size)
    foreach ($b in @($Background, $Foreground)) { $dc.DrawImage((ConvertTo-BitmapImage $b), $rect) }
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    $rtb
}

function New-PlaceholderIcon([string]$Label, [string]$Accent) {
    $size = 432
    $letter = '?'
    if ($Label) { $letter = $Label.Substring(0, 1).ToUpper() }
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Accent))
    $dc.DrawRectangle($brush, $null, (New-Object Windows.Rect 0, 0, $size, $size))
    $ft = New-Object Windows.Media.FormattedText $letter, ([Globalization.CultureInfo]::CurrentUICulture), ([Windows.FlowDirection]::LeftToRight), (New-Object Windows.Media.Typeface 'Segoe UI Semibold'), 220, ([Windows.Media.Brushes]::White), 1.0
    $dc.DrawText($ft, (New-Object Windows.Point (($size - $ft.Width) / 2), (($size - $ft.Height) / 2)))
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    $rtb
}

function Get-ApkIcon($Info, [string]$Path, [string]$Accent) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries)
        $bases = @()
        if ($Info.IconPath) { $bases += [IO.Path]::GetFileNameWithoutExtension($Info.IconPath) }
        $bases += 'ic_launcher', 'icon', 'app_icon'
        $bases = $bases | Select-Object -Unique

        # 1) icona bitmap con lo stesso nome di quella del manifest, densità più alta
        foreach ($b in $bases) {
            $rx = '^res/[^/]+/' + [regex]::Escape($b) + '\.(png|webp|jpg)$'
            $best = $entries | Where-Object { $_.FullName -match $rx } |
                Sort-Object @{ Expression = { Get-DensityRank $_.FullName }; Descending = $true }, @{ Expression = { $_.Length }; Descending = $true } |
                Select-Object -First 1
            if ($best) {
                try { return ConvertTo-BitmapImage (Read-ZipEntry $best) } catch { }
            }
        }
        # 2) icona adattiva a due livelli
        foreach ($b in $bases) {
            $rxFg = '^res/([^/]+)/' + [regex]::Escape($b) + '_foreground\.(png|webp)$'
            $fgs = $entries | Where-Object { $_.FullName -match $rxFg } |
                Sort-Object @{ Expression = { Get-DensityRank $_.FullName }; Descending = $true }
            foreach ($fg in $fgs) {
                $dir = [regex]::Match($fg.FullName, $rxFg).Groups[1].Value
                $bg = $entries | Where-Object { $_.FullName -match ('^res/' + [regex]::Escape($dir) + '/' + [regex]::Escape($b) + '_background\.(png|webp)$') } | Select-Object -First 1
                if ($bg) {
                    try { return New-CompositeIcon (Read-ZipEntry $bg) (Read-ZipEntry $fg) } catch { }
                }
            }
        }
    } finally { $zip.Dispose() }
    # nessuna icona utilizzabile nell'APK: il robot
    $droid = Join-Path $Root 'droid.png'
    if (Test-Path $droid) {
        try { return ConvertTo-BitmapImage ([IO.File]::ReadAllBytes($droid)) } catch { }
    }
    New-PlaceholderIcon $Info.Label $Accent
}

# ---------- theme ----------

$light = $true
try { $light = [bool](Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) } catch { }
if ($light) {
    $T = @{ BG = '#FFFFFF'; FG = '#1B1B1F'; MUTED = '#6B6B76'; ICONBG = '#ECECF1'; BTN = '#F1F1F5'; BORDER = '#D9D9E0'; ACCENT = '#1E8E5A'; ACCENTFG = '#FFFFFF'; WARNBG = '#FFF4E0'; WARNFG = '#7A4B00'; OKFG = '#1E8E5A'; ERRFG = '#B3261E' }
} else {
    $T = @{ BG = '#1F1F23'; FG = '#F2F2F5'; MUTED = '#A0A0AC'; ICONBG = '#2C2C32'; BTN = '#2C2C32'; BORDER = '#3A3A42'; ACCENT = '#2FB574'; ACCENTFG = '#08150E'; WARNBG = '#3A2E14'; WARNFG = '#F0C674'; OKFG = '#4CD08C'; ERRFG = '#FF8A80' }
}

# ---------- pick the APK ----------

if (-not $Apk) {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = Txt 'pick_title'
    $dlg.Filter = Txt 'pick_filter'
    if (-not $dlg.ShowDialog()) { exit 0 }
    $Apk = $dlg.FileName
}

try {
    $Apk = (Resolve-Path -LiteralPath $Apk).Path
    $info = Get-ApkInfo $Apk
} catch {
    if ($ParseOnly) { throw }
    [void][Windows.MessageBox]::Show($_.Exception.Message, (Txt 'window_title'), 'OK', 'Error')
    exit 1
}

if ($ParseOnly) {
    $info | ConvertTo-Json
    exit 0
}

$icon = Get-ApkIcon $info $Apk $T.ACCENT

# ---------- dialog ----------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="" Width="520" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True"
        Background="@@BG@@" Foreground="@@FG@@"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="@@FG@@"/>
      <Setter Property="Background" Value="@@BTN@@"/>
      <Setter Property="BorderBrush" Value="@@BORDER@@"/>
      <Setter Property="Padding" Value="20,9"/>
      <Setter Property="MinWidth" Value="112"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="@@ACCENTFG@@"/>
      <Setter Property="Background" Value="@@ACCENT@@"/>
      <Setter Property="BorderBrush" Value="@@ACCENT@@"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>
  <Grid x:Name="RootGrid" Margin="28,26,28,22" Background="@@BG@@">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border x:Name="IconBox" Width="88" Height="88" CornerRadius="20" Background="@@ICONBG@@" VerticalAlignment="Top"/>
      <StackPanel Grid.Column="1" Margin="18,2,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="TitleText" FontSize="22" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="PkgText" FontSize="13" Foreground="@@MUTED@@" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="MetaText" FontSize="13" Foreground="@@MUTED@@" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Grid>
    <TextBlock x:Name="Question" Grid.Row="1" Margin="0,22,0,0" FontSize="15" TextWrapping="Wrap"/>
    <Border x:Name="WarnBox" Grid.Row="2" Margin="0,16,0,0" Padding="12,10" CornerRadius="8" Background="@@WARNBG@@" Visibility="Collapsed">
      <TextBlock x:Name="WarnText" FontSize="13" Foreground="@@WARNFG@@" TextWrapping="Wrap"/>
    </Border>
    <StackPanel x:Name="StatusPanel" Grid.Row="3" Margin="0,18,0,0" Visibility="Collapsed">
      <TextBlock x:Name="StatusText" FontSize="14" TextWrapping="Wrap"/>
      <ProgressBar x:Name="Bar" Height="4" Margin="0,10,0,0" IsIndeterminate="True" Foreground="@@ACCENT@@" Background="@@ICONBG@@" BorderThickness="0"/>
    </StackPanel>
    <WrapPanel Grid.Row="4" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnExtra" Style="{StaticResource Btn}" Margin="0,8,10,0" Visibility="Collapsed"/>
      <Button x:Name="BtnYes" Style="{StaticResource BtnPrimary}" Margin="0,8,10,0" IsDefault="True"/>
      <Button x:Name="BtnNo" Style="{StaticResource Btn}" Margin="0,8,0,0" IsCancel="True"/>
    </WrapPanel>
  </Grid>
</Window>
'@
foreach ($k in $T.Keys) { $xaml = $xaml.Replace("@@$k@@", $T[$k]) }

$script:W = [Windows.Markup.XamlReader]::Parse($xaml)
$script:C = @{}
foreach ($n in 'RootGrid', 'IconBox', 'TitleText', 'PkgText', 'MetaText', 'Question', 'WarnBox', 'WarnText', 'StatusPanel', 'StatusText', 'Bar', 'BtnExtra', 'BtnYes', 'BtnNo') {
    $script:C[$n] = $script:W.FindName($n)
}
$C = $script:C

$brush = New-Object Windows.Media.ImageBrush $icon
$brush.Stretch = 'UniformToFill'
$C.IconBox.Background = $brush

$script:W.Title = Txt 'window_title'
$C.Question.Text = Txt 'question'
$C.BtnYes.Content = Txt 'btn_install'
$C.BtnNo.Content = Txt 'btn_no'
$C.BtnExtra.Content = Txt 'btn_fix'
if ($RightToLeft) { $script:W.FlowDirection = 'RightToLeft' }

$C.TitleText.Text = $info.Label
$C.PkgText.Text = $info.Package
$meta = @()
if ($info.Version) { $meta += (Txt 'meta_version' $info.Version) }
$meta += (Txt 'meta_size' $info.SizeMB)
if ($info.MinSdk) { $meta += (Isolate (Txt 'meta_api' $info.MinSdk)) }
$C.MetaText.Text = $meta -join '  ·  '

if ($info.Abis.Count -gt 0 -and -not ($info.Abis -contains 'x86_64' -or $info.Abis -contains 'x86')) {
    $C.WarnText.Text = Txt 'warn_arm' (Isolate ($info.Abis -join ', '))
    $C.WarnBox.Visibility = 'Visible'
}

# ---------- preview mode (render to PNG, no window) ----------

if ($PreviewPng) {
    if ($PreviewKey) {
        $C.StatusText.Text = (Txt $PreviewKey $Endpoint (Txt 'btn_fix') 'x')
        $C.Bar.Visibility = 'Collapsed'
        $C.StatusPanel.Visibility = 'Visible'
        $C.Question.Visibility = 'Collapsed'
        $C.BtnExtra.Visibility = 'Visible'
        $C.BtnYes.Content = Txt 'btn_retry'
        $C.BtnNo.Content = Txt 'btn_close'
    }
    $root = $script:W.Content
    $root.Measure([Windows.Size]::new(464, [double]::PositiveInfinity))
    $root.Arrange((New-Object Windows.Rect 0, 0, $root.DesiredSize.Width, $root.DesiredSize.Height))
    $root.UpdateLayout()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][Math]::Ceiling($root.DesiredSize.Width)), ([int][Math]::Ceiling($root.DesiredSize.Height)), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($PreviewPng)
    $enc.Save($fs)
    $fs.Dispose()
    exit 0
}

# ---------- dark title bar ----------

if (-not $light) {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);'
    $script:W.Add_SourceInitialized({
        $h = (New-Object Windows.Interop.WindowInteropHelper $script:W).Handle
        $v = 1
        [void][Win32.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
    })
}

# ---------- install flow ----------

$script:State = 'confirm'
$script:Job = $null
$script:Attempts = 0

function Show-Status([string]$Text, [bool]$Busy, [string]$Color) {
    $C.StatusText.Text = $Text
    if ($Color) { $C.StatusText.Foreground = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Color))) }
    else { $C.StatusText.Foreground = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($T.FG))) }
    $C.Bar.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
    $C.StatusPanel.Visibility = 'Visible'
}

function Test-Endpoint {
    $tc = New-Object Net.Sockets.TcpClient
    try {
        $iar = $tc.BeginConnect('127.0.0.1', 58526, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(300) -and $tc.Connected)
    } catch { return $false } finally { $tc.Close() }
}

function Start-Delay([int]$Ms, [scriptblock]$Done) {
    $script:Job = @{ Kind = 'delay'; Until = [DateTime]::UtcNow.AddMilliseconds($Ms); Done = $Done }
}

function Start-Async([string]$File, [string[]]$Arguments, [scriptblock]$Done) {
    $j = Start-ToolProcess $File $Arguments
    $j.Kind = 'proc'
    $j.Done = $Done
    $script:Job = $j
}

function Get-FriendlyError([string]$Text) {
    if ($Text -match 'NO_MATCHING_ABIS') { return (Txt 'err_abi') }
    if ($Text -match 'UPDATE_INCOMPATIBLE') { return (Txt 'err_signature') }
    if ($Text -match 'VERSION_DOWNGRADE') { return (Txt 'err_downgrade') }
    if ($Text -match 'OLDER_SDK') { return (Txt 'err_sdk') }
    if ($Text -match 'INSUFFICIENT_STORAGE') { return (Txt 'err_storage') }
    $line = ($Text -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if (-not $line) { $line = Txt 'err_unknown' }
    $line
}

function Show-Fix([string]$Text, [bool]$CanFix) {
    $script:State = 'retry'
    Show-Status $Text $false $T.ERRFG
    $C.BtnExtra.Visibility = $(if ($CanFix) { 'Visible' } else { 'Collapsed' })
    $C.BtnYes.Visibility = 'Visible'
    $C.BtnYes.Content = Txt 'btn_retry'
    $C.BtnYes.IsEnabled = $true
    $C.BtnNo.Content = Txt 'btn_close'
}

function Show-DevModeHelp {
    Show-Fix (Txt 'help_devmode' (Isolate $Endpoint) (Txt 'btn_fix')) (Test-Path (Join-Path $Root 'Enable-WsaDeveloperMode.ps1'))
}

function Show-AuthHelp {
    Show-Fix (Txt 'help_auth' (Txt 'btn_fix')) (Test-Path (Join-Path $Root 'Enable-WsaDeveloperMode.ps1'))
}

function Show-NoWsa {
    Show-Fix (Txt 'help_nowsa') $false
}

# accende la modalità sviluppatore di WSA (e riavvia WSA se serve), poi riprova
function Start-EnableDevMode {
    $enable = Join-Path $Root 'Enable-WsaDeveloperMode.ps1'
    if (-not (Test-Path $enable)) { Start-Process explorer.exe "shell:appsFolder\$WsaAppId!SettingsApp"; return }
    $script:State = 'busy'
    $C.BtnExtra.Visibility = 'Collapsed'
    $C.BtnYes.IsEnabled = $false
    Show-Status (Txt 'status_enabling') $true
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Async $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $enable, '-Force', '-AdbPath', $Adb) {
        param($r)
        if ($r.Code -eq 0) { Start-Flow }
        else {
            $msg = ($r.Err + "`n" + $r.Out -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
            Show-Fix (Txt 'help_enable_failed' $msg) $true
        }
    }
}

function Start-Connect {
    $script:Attempts++
    if ($script:Unauthorized) { Show-Status (Txt 'status_waiting_auth') $true }
    else { Show-Status (Txt 'status_connecting') $true }
    Start-Async $Adb @('connect', $Endpoint) {
        param($r)
        Start-Async $Adb @('devices') {
            param($d)
            $line = ($d.Out -split "\r?\n" | Where-Object { $_ -like "$Endpoint*" } | Select-Object -First 1)
            $state = ''
            if ($line) { $state = ($line -split '\s+')[1] }
            if ($state -eq 'device') { Start-InstallStep }
            elseif ($state -eq 'unauthorized') {
                $script:Unauthorized = $true
                if ($script:Attempts -lt 45) { Start-Delay 2000 { Start-Connect } } else { Show-AuthHelp }
            }
            elseif ($script:Attempts -lt 20) { Start-Delay 1500 { Start-Connect } }
            else { Show-DevModeHelp }
        }
    }
}

function Start-InstallStep {
    Show-Status (Txt 'status_installing') $true
    Start-Async $Adb @('-s', $Endpoint, 'install', '-r', $Apk) {
        param($r)
        $all = ($r.Out + "`n" + $r.Err)
        if ($all -match '(?m)^Success') {
            $script:State = 'done-ok'
            Show-Status (Txt 'status_installed') $false $T.OKFG
            $C.BtnYes.Content = Txt 'btn_open'
            $C.BtnYes.IsEnabled = $true
            $C.BtnNo.Content = Txt 'btn_close'
        } else {
            $script:State = 'done-err'
            Show-Status (Txt 'status_failed' (Get-FriendlyError $all)) $false $T.ERRFG
            $C.BtnYes.Visibility = 'Collapsed'
            $C.BtnNo.Content = Txt 'btn_close'
        }
    }
}

function Start-Flow {
    $script:State = 'busy'
    $script:Attempts = 0
    $script:Unauthorized = $false
    $C.Question.Visibility = 'Collapsed'
    $C.BtnExtra.Visibility = 'Collapsed'
    $C.BtnYes.IsEnabled = $false
    if (-not (Test-Path $WsaClient)) { Show-NoWsa; return }       # l'alias WsaClient esiste solo se WSA è installata
    Show-Status (Txt 'status_start_wsa') $true
    $script:W.Dispatcher.Invoke([Action] {}, 'Render')
    # non Start-Process -Wait: aspetterebbe anche il demone adb, che resta attivo
    $psi = New-Object Diagnostics.ProcessStartInfo $Adb, 'start-server'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $srv = [Diagnostics.Process]::Start($psi)
    [void]$srv.WaitForExit(15000)
    if (-not (Test-Endpoint) -and (Test-Path $WsaClient)) {
        Start-Process -FilePath $WsaClient -ArgumentList '/launch', 'wsa://system' -WindowStyle Hidden
    }
    Start-Connect
}

$C.BtnYes.Add_Click({
    switch ($script:State) {
        'confirm' { Start-Flow }
        'retry'   { Start-Flow }
        'done-ok' {
            if (Test-Path $WsaClient) { Start-Process -FilePath $WsaClient -ArgumentList '/launch', "wsa://$($info.Package)" -WindowStyle Hidden }
            $script:W.Close()
        }
    }
})
$C.BtnNo.Add_Click({ $script:W.Close() })
$C.BtnExtra.Add_Click({ Start-EnableDevMode })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    $j = $script:Job
    if ($null -eq $j) { return }
    try {
        if ($j.Kind -eq 'delay') {
            if ([DateTime]::UtcNow -ge $j.Until) { $script:Job = $null; & $j.Done }
        } elseif ($j.Proc.HasExited -and $j.OutTask.IsCompleted -and $j.ErrTask.IsCompleted) {
            $script:Job = $null
            & $j.Done @{ Out = $j.OutTask.Result; Err = $j.ErrTask.Result; Code = $j.Proc.ExitCode }
        }
    } catch {
        $script:Job = $null
        $script:State = 'done-err'
        Show-Status (Txt 'status_failed' $_.Exception.Message) $false $T.ERRFG
        $C.BtnYes.Visibility = 'Collapsed'
        $C.BtnNo.Content = Txt 'btn_close'
    }
})
$timer.Start()

[void]$script:W.ShowDialog()
