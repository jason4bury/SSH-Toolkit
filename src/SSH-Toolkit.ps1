<#
.SYNOPSIS
    SSH Toolkit - One-click SSH to the NAS, the server and the laptop, with quick commands, key setup, file copy and Docker shortcuts.

.DESCRIPTION
    PowerShell/WPF tool for connecting to and running commands on home machines over SSH.

    One window: the saved machines on the left (a dot shows which ones answer), and for the
    selected machine: Open terminal, quick commands (disk space, uptime, docker ps, restart),
    Docker Compose pull/up/down in its compose folder, file copy both ways, a box for any
    other command, and the SSH key helper.

    Everything goes through Windows' own OpenSSH Client (ssh.exe, scp.exe, ssh-keygen.exe).
    Commands in the window run with BatchMode, so they never stop to ask for a password:
    they need the SSH key, which the key helper sets up. Restart and the key copy open a
    window of their own instead, because they do ask for a password.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "SSH Toolkit v<version>\" release folders, their zips and
                                        "SSH Toolkit.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\SSH Toolkit (never inside the repo or a release folder)

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "SSH Toolkit v<version>".
$script:AppName     = 'SSH Toolkit'
$script:AppVersion  = '1.02'
$script:Description = 'PowerShell/WPF tool for connecting to and running commands on home machines over SSH'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/SSH-Toolkit'
$script:IsPrivate   = $false   # public tool: settings live in %APPDATA%\SSH Toolkit
$script:AppId       = 'jason4bury.SSH-Toolkit'   # taskbar ID; the shortcut made by New-SSHToolkitShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\SSH Toolkit v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
# DwmSetWindowAttribute gives each window a dark title bar to match the app (Windows 10 2004 and later).
try {
    if (-not ('SshToolkit.Native' -as [type])) {
        Add-Type -Namespace 'SshToolkit' -Name 'Native' -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
    }
    [void][SshToolkit.Native]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# %APPDATA%\SSH Toolkit. Never inside Source\ (keeps machine details out of git) or a release
       folder (each version has its own, so data kept there would be left behind by the next one). #>
    return (Join-Path $env:APPDATA $script:AppName)
}

$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AppIcon {
    <# The .ico's largest frame for the windows and taskbar. A BitmapImage of an .ico loads only
       the 16 px frame, which looks faint and blurry on the taskbar. #>
    $path = Join-Path $script:AssetsDir 'SSH-Toolkit.ico'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stream = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($stream, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $frame = $decoder.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
    $frame.Freeze()
    return $frame
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}

function New-Brush([string]$Hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}

function New-XamlWindow {
    <# Loads a window from XAML with the app's look (<!--THEME-->), its icon and a title bar to match. #>
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    # Colours are DynamicResource so Set-Theme can swap them in an open window (style values get frozen).
    $text = $Xaml.Replace('<!--THEME-->', $script:ThemeXaml)
    $text = [regex]::Replace($text, '\{StaticResource (' + (@($script:Colours.Keys) -join '|') + ')\}', '{DynamicResource $1}')
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$text)
    $w = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner -and $Owner.IsLoaded) { $w.Owner = $Owner } else { $w.WindowStartupLocation = 'CenterScreen' }
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    Set-TitleBar $w
    return $w
}

function Set-TitleBar([Windows.Window]$Window) {
    <# Dark title bar in the dark theme, Windows' normal one in the light theme. #>
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = [int][bool]$script:IsDark
        [void][SshToolkit.Native]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)
    } catch { Write-Verbose "No title bar colour: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look (the app's own: dark, with a teal accent). Every window uses these.
# ---------------------------------------------------------------------------
# Two palettes with the same names. Theme is Dark, Light or System (follow Windows' app mode).
$script:Palettes = @{
    Dark  = [ordered]@{
        Page = '#171B21'; Panel = '#1F252D'; Raised = '#2A313B'; Hover = '#252C35'; Line = '#38414D'; Well = '#11151A'
        Ink = '#E6EAEE'; SoftInk = '#9AA5B1'; Accent = '#2FBF9F'; AccentInk = '#0C1A16'
        Ok = '#5CCB7A'; Warn = '#E5B454'; Bad = '#E36A6A'; Unknown = '#6B7682'
    }
    Light = [ordered]@{
        Page = '#F3F5F7'; Panel = '#FFFFFF'; Raised = '#E3E8ED'; Hover = '#EDF1F4'; Line = '#C5CDD5'; Well = '#FFFFFF'
        Ink = '#1B2128'; SoftInk = '#56616C'; Accent = '#14876D'; AccentInk = '#FFFFFF'
        Ok = '#23893F'; Warn = '#9A6200'; Bad = '#C23434'; Unknown = '#7D8894'
    }
}
$script:ThemeNames = [ordered]@{ System = 'Follow Windows'; Dark = 'Dark'; Light = 'Light' }
$script:Theme = 'System'

function Test-WindowsLightMode {
    <# Windows' "app mode": $true for light, $false for dark. #>
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$v -eq 1)
    } catch { return $false }
}

function Use-Palette {
    <# Picks the palette for $script:Theme and makes the brushes and the XAML colours from it. #>
    $script:IsDark = switch ($script:Theme) { 'Dark' { $true } 'Light' { $false } default { -not (Test-WindowsLightMode) } }
    $script:Colours = if ($script:IsDark) { $script:Palettes.Dark } else { $script:Palettes.Light }
    $script:Brush = @{}
    foreach ($k in $script:Colours.Keys) { $script:Brush[$k] = New-Brush $script:Colours[$k] }
    $brushes = foreach ($k in $script:Colours.Keys) { '<SolidColorBrush x:Key="{0}" Color="{1}"/>' -f $k, $script:Colours[$k] }
    $script:ThemeXaml = ($brushes -join "`r`n") + "`r`n" + $script:StyleXaml
}

$script:StyleXaml = @'
<Style x:Key="Btn" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Background" Value="{StaticResource Raised}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="Padding" Value="12,6"/>
    <Setter Property="Margin" Value="0,0,8,8"/>
    <Setter Property="MinWidth" Value="76"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="Button">
                <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Line}"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Foreground" Value="{StaticResource AccentInk}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
</Style>
<Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Foreground" Value="{StaticResource Bad}"/>
</Style>
<Style x:Key="Field" TargetType="TextBox">
    <Setter Property="Background" Value="{StaticResource Panel}"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
    <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Padding" Value="6,5"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
</Style>
<Style x:Key="Heading" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource SoftInk}"/>
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,14,0,6"/>
</Style>
<Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource SoftInk}"/>
    <Setter Property="Margin" Value="0,10,0,4"/>
</Style>
'@
Use-Palette

# ---------------------------------------------------------------------------
#  App-styled dialogs (no plain Windows message boxes)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <StackPanel Margin="22,20,22,14" MaxWidth="500" MinWidth="320">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="MsgGlyph" FontFamily="Segoe MDL2 Assets" FontSize="26" Margin="0,0,16,0" VerticalAlignment="Top"/>
            <TextBlock x:Name="MsgText" Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center" LineHeight="20"/>
        </Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
            <Button x:Name="MsgYes" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button x:Name="MsgNo" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,0,8"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Show-AppMessage {
    <# The app's own message box. With -NoText it asks a question and returns $true for the
       first button (YesText); otherwise it just shows the message with an OK button. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Info', 'Warn', 'Error', 'Question')][string]$Kind = 'Info',
        [string]$Title = $script:AppName,
        [string]$YesText = 'OK',
        [string]$NoText,
        [Windows.Window]$Owner = $script:Window
    )
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $glyph = $w.FindName('MsgGlyph')
    switch ($Kind) {
        'Info'     { $glyph.Text = [string][char]0xE946; $glyph.Foreground = $script:Brush.Accent }
        'Warn'     { $glyph.Text = [string][char]0xE7BA; $glyph.Foreground = $script:Brush.Warn }
        'Error'    { $glyph.Text = [string][char]0xEA39; $glyph.Foreground = $script:Brush.Bad }
        'Question' { $glyph.Text = [string][char]0xE9CE; $glyph.Foreground = $script:Brush.Accent }
    }
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText }
    else { $no.Visibility = 'Collapsed'; $yes.IsCancel = $true; $yes.Margin = '0,0,0,8' }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; [Windows.Window]::GetWindow($this).Close() })
    $no.Add_Click({ $script:MsgAnswer = $false; [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
    return [bool]$script:MsgAnswer
}

$script:InputXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="500" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <StackPanel Margin="22,18,22,14">
        <TextBlock x:Name="InPrompt" TextWrapping="Wrap"/>
        <TextBox x:Name="InText" Style="{StaticResource Field}" FontFamily="Consolas" Margin="0,10,0,0"/>
        <TextBlock x:Name="InHint" TextWrapping="Wrap" Foreground="{StaticResource SoftInk}" Margin="0,8,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
            <Button x:Name="InOk" Content="OK" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button x:Name="InCancel" Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,0,8"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Show-AppInput {
    <# Asks for one line of text. Returns the text, or $null if cancelled. #>
    param([string]$Title, [string]$Prompt, [string]$Default = '', [string]$Hint = '', [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:InputXaml $Owner
    $w.Title = $Title
    $w.FindName('InPrompt').Text = $Prompt
    $hintBox = $w.FindName('InHint')
    if ($Hint) { $hintBox.Text = $Hint } else { $hintBox.Visibility = 'Collapsed' }
    $w.FindName('InText').Text = $Default
    $script:InputAnswer = $null
    $w.FindName('InOk').Add_Click({
        $win = [Windows.Window]::GetWindow($this)
        $script:InputAnswer = $win.FindName('InText').Text.Trim()
        $win.Close()
    })
    $w.Add_ContentRendered({ $b = $this.FindName('InText'); [void]$b.Focus(); $b.CaretIndex = $b.Text.Length })
    [void]$w.ShowDialog()
    return $script:InputAnswer
}

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house-style wording, in the app's own look)
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <StackPanel Margin="22" MaxWidth="440">
        <StackPanel Orientation="Horizontal">
            <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
            <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
                <TextBlock x:Name="AboutVersion" Foreground="{StaticResource SoftInk}"/>
            </StackPanel>
        </StackPanel>
        <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
        <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{StaticResource SoftInk}"/>
        <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{StaticResource Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
        <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{StaticResource SoftInk}"/>
        <Button x:Name="AboutClose" Content="Close" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Right" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
    </StackPanel>
</Window>
'@

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'SSH-Toolkit.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

# ---------------------------------------------------------------------------
#  Help (Help button or F1)
# ---------------------------------------------------------------------------
$script:HelpXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="600" Height="640" MinWidth="420" MinHeight="320" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <DockPanel Margin="22,16,22,12">
        <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Right" Margin="0,12,0,0" IsDefault="True" IsCancel="True"/>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="HelpBody" Margin="0,0,10,0"/>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

$script:HelpText = @(
    @('Getting started', @(
        'Click Add (bottom left) for each machine: a name, its address and SSH port (usually 22), the user to sign in as and, for Docker, its compose folder.',
        'The dot beside each machine is green when its SSH port answers and red when it can''t be reached. It''s checked when the window opens, every minute and on Check now, and never signs in.',
        'Edit changes a machine (for example a VM that got a new address); Remove takes it off the list.')),
    @('First-time key setup', @(
        'Commands in the window sign in with an SSH key, never a password. Pick a machine and click Key helper.',
        'Step 1 makes a key on this PC (skip it if the helper says there''s one already).',
        'Step 2 copies the key to the selected machine: Run it opens PowerShell, which asks for that machine''s password once. Do step 2 once per machine, then click Uptime to check it works.')),
    @('The buttons', @(
        'Open terminal: an SSH session in a terminal window. Double-clicking a machine does the same.',
        'Disk space, Uptime, Docker ps: run on the machine and show the answer in the output box.',
        'Restart machine: asks first, then opens a terminal for the sudo password.',
        'Pull, Up, Down: Docker Compose in the machine''s compose folder. The compose project name (in Edit) is only needed if the stack was started under a name other than the folder''s. Down asks first.',
        'Send files to it: pick files on this PC, then the folder on the machine to copy them to.',
        'Get a file from it: browse the machine''s folders (double-click to open one, Up and Home to move around, or type a path and press Enter), pick one or more files and click Get, then choose the folder on this PC. Tick Show hidden files for files like .env.',
        'Run a command: type any command that doesn''t ask questions and press Enter or Run.')),
    @('When something goes wrong', @(
        'Can''t reach a machine: check it''s switched on, and its address and port (Edit).',
        'Sign-in turned down: the key isn''t on that machine yet. Do Key helper step 2 for it.',
        'Identity changed: normal after a reinstall, or when a VM gets an address another machine had. If you know that''s what happened, click Forget old identity and try again.',
        'A command that takes too long is stopped for you; Stop ends one at any time. Anything that asks a question (like sudo) needs Open terminal.')),
    @('Light and dark', @(
        'The Theme button (bottom right) switches between Follow Windows, Dark and Light. Follow Windows uses the light or dark app mode set in Windows Settings > Personalisation > Colours. Your choice is remembered.')),
    @('Where settings live', @(
        'Your machines and the log are in %APPDATA%\SSH Toolkit on this PC, never in the program folder, so updating SSH Toolkit doesn''t touch them. About shows the exact folder.'))
)

function Show-Help {
    $w = New-XamlWindow $script:HelpXaml $script:Window
    $w.Title = "$script:AppName help"
    $body = $w.FindName('HelpBody')
    $first = $true
    foreach ($section in $script:HelpText) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $section[0].ToUpper()
        $h.Style = $w.FindResource('Heading')
        if ($first) { $h.Margin = '0,0,0,6'; $first = $false }
        [void]$body.Children.Add($h)
        foreach ($para in $section[1]) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = $para
            $t.TextWrapping = 'Wrap'
            $t.LineHeight = 19
            $t.Margin = '0,0,0,6'
            [void]$body.Children.Add($t)
        }
    }
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Machines (saved in settings.json in the data folder)
# ---------------------------------------------------------------------------
function New-Machine {
    param([string]$Name, [string]$Address, [int]$Port = 22, [string]$User, [string]$Folder = '', [string]$Project = '')
    return [pscustomobject]@{ Name = $Name; Address = $Address; Port = $Port; User = $User; Folder = $Folder; Project = $Project }
}

function Read-Settings {
    $list = $null
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $s = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($script:ThemeNames.Contains([string]$s.Theme)) { $script:Theme = [string]$s.Theme; Use-Palette }
            $list = @(foreach ($m in @($s.Machines)) {
                if (-not $m -or -not $m.Name) { continue }
                $port = 22
                if (-not [int]::TryParse([string]$m.Port, [ref]$port)) { $port = 22 }
                New-Machine -Name ([string]$m.Name) -Address ([string]$m.Address) -Port $port -User ([string]$m.User) -Folder ([string]$m.Folder) -Project ([string]$m.Project)
            })
        } catch {
            Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)"
            $script:SettingsProblem = "settings.json couldn't be read, so the list starts empty. The old file was kept as settings.json.bad."
            Copy-Item -LiteralPath $script:SettingsPath -Destination "$script:SettingsPath.bad" -Force -ErrorAction SilentlyContinue
            $list = $null
        }
    }
    if ($null -eq $list) {
        # First run: no machines yet. Add them in the window with Add.
        $script:Machines = New-Object Collections.ArrayList
        Save-Settings
        return
    }
    $script:Machines = New-Object Collections.ArrayList
    foreach ($m in $list) { [void]$script:Machines.Add($m) }
}

function Save-Settings {
    $rows = @(foreach ($m in $script:Machines) { [ordered]@{ Name = $m.Name; Address = $m.Address; Port = $m.Port; User = $m.User; Folder = $m.Folder; Project = $m.Project } })
    try { ConvertTo-Json -InputObject ([ordered]@{ Theme = $script:Theme; Machines = $rows }) -Depth 5 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { [void](Show-AppMessage -Kind Error -Text "The machines couldn't be saved:`n$($_.Exception.Message)") }
}

function Get-Login($Machine) { return "$($Machine.User)@$($Machine.Address)" }

function Get-SelectedMachine {
    $i = $script:UI.LstMachines.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:Machines.Count) { return $null }
    return $script:Machines[$i]
}

# ---------------------------------------------------------------------------
#  OpenSSH
# ---------------------------------------------------------------------------
function Find-OpenSsh([string]$Name) {
    foreach ($dir in @((Join-Path $env:SystemRoot 'Sysnative\OpenSSH'), (Join-Path $env:SystemRoot 'System32\OpenSSH'))) {
        $p = Join-Path $dir $Name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:NoOpenSsh = "wasn't found. Turn on the OpenSSH Client in Windows Settings > System > Optional features, then start SSH Toolkit again."

function Get-OpenSsh([string]$Name) {
    <# The full path of ssh.exe / scp.exe / ssh-keygen.exe, or $null after saying how to get it. #>
    $p = Find-OpenSsh $Name
    if (-not $p) { [void](Show-AppMessage -Kind Warn -Text "$Name $script:NoOpenSsh") }
    return $p
}

function ConvertTo-ArgLine {
    <# Joins arguments into one Windows command line, quoted the way ssh.exe and scp.exe read them back. #>
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -eq '') { '""'; continue }
        if ($a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $slashes++; continue }
            if ($ch -eq [char]'"') { [void]$sb.Append([char]'\', 2 * $slashes + 1); [void]$sb.Append([char]'"') }
            else {
                if ($slashes) { [void]$sb.Append([char]'\', $slashes) }
                [void]$sb.Append($ch)
            }
            $slashes = 0
        }
        if ($slashes) { [void]$sb.Append([char]'\', 2 * $slashes) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

function ConvertTo-ShQuote([string]$Text) {
    <# Quotes one word for the machine's (POSIX) shell. A ' inside becomes '"'"' rather than '\''
       because Windows' scp.exe turns backslashes in remote paths into forward slashes. #>
    if ($Text -match '^[A-Za-z0-9_./:=@%+,~-]+$') { return $Text }
    return "'" + $Text.Replace("'", "'`"'`"'") + "'"
}

# SSH commands don't read the login profile, so Synology's /usr/local/bin (docker) isn't on PATH.
$script:PathPrefix = 'PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; '

function Get-SshOptions([switch]$Interactive) {
    <# BatchMode for commands in the window: fail at once rather than wait for a password nobody sees. #>
    $o = @('-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR')
    if (-not $Interactive) { $o = @('-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=20') + $o }
    return $o
}

function Get-SshArguments($Machine, [string]$Command, [switch]$Interactive, [switch]$Tty) {
    $a = @(Get-SshOptions -Interactive:$Interactive)
    if ($Machine.Port -and $Machine.Port -ne 22) { $a += @('-p', [string]$Machine.Port) }
    if ($Tty) { $a += '-t' }
    $a += (Get-Login $Machine)
    if ($Command) { $a += $Command }
    return $a
}

function Get-ScpArguments($Machine, [string[]]$Paths, [switch]$Legacy, [switch]$QuotedNames) {
    $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR')
    if ($Legacy) { $a = @('-O') + $a }
    # scp -O compares the names it gets back with the (quoted) names asked for and refuses the
    # copy when they differ; -T turns that check off. Only used for paths quoted by the app.
    if ($Legacy -and $QuotedNames) { $a = @('-T') + $a }
    if ($Machine.Port -and $Machine.Port -ne 22) { $a += @('-P', [string]$Machine.Port) }
    return $a + $Paths
}

# Newer scp uses SFTP; a machine without SFTP (some Synology setups) needs the older way (scp -O).
$script:NoSftp = 'subsystem request failed|sftp-server|Connection closed|lost connection|Couldn''t read packet'
$script:HostKeyChanged = 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed'

function Get-FriendlyError {
    <# Plain English for the usual ssh/scp failures, or $null. #>
    param([string]$Text, $Machine)
    $n = $Machine.Name
    if ($Text -match $script:HostKeyChanged) {
        return "$n's identity (host key) isn't the one this PC remembers. That's normal after a reinstall, or when a VM gets an address another machine had before."
    }
    if ($Text -match 'Permission denied \(') { return "$n turned down the sign-in. Open Key helper and copy your SSH key to $n (step 2)." }
    if ($Text -match 'Could not resolve hostname') { return "Can't find $n at $($Machine.Address). Check the address with Edit." }
    if ($Text -match 'Connection timed out|Operation timed out|No route to host|Network is unreachable|Connection refused') {
        return "Can't reach $n at $($Machine.Address), port $($Machine.Port). Check it's switched on, and that the address and port are right (Edit)."
    }
    if ($Text -match 'permission denied while trying to connect to the Docker daemon') {
        return "$($Machine.User) isn't allowed to use Docker on $n. On a Synology NAS, run this once in a terminal there: sudo synogroup --add docker $($Machine.User)"
    }
    if ($Text -match 'docker: (command )?not found') { return "Docker wasn't found on $n." }
    if ($Text -match 'no configuration file provided|Can''t find a suitable configuration file') { return "There's no compose file in $($Machine.Folder) on $n. Check the compose folder with Edit." }
    if ($Text -match 'No such file or directory') { return "That file or folder isn't on $n. Check the path." }
    return $null
}

# ---------------------------------------------------------------------------
#  Running a command (one at a time). Output shows as it arrives and the window
#  stays responsive: a timer reads the lines and notices the end.
# ---------------------------------------------------------------------------
function Add-Output {
    param([string]$Line)
    $box = $script:UI.TxtOutput
    if ($box.Text.Length -gt 400000) { $box.Text = $box.Text.Substring($box.Text.Length - 200000) }
    $box.AppendText($Line + "`r`n")
    $box.ScrollToEnd()
}

function Set-Status {
    param([string]$Text, [ValidateSet('Ink', 'Ok', 'Warn', 'Bad', 'SoftInk')][string]$Tone = 'SoftInk')
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = $script:Brush[$Tone]
}

function Start-Remote {
    <# Runs ssh.exe or scp.exe for a machine in the background and shows its output.
       -RetryArguments: run once more with these if the first run fails with a message matching -RetryWhen. #>
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [string[]]$RetryArguments,
        [string]$RetryWhen
    )
    if ($script:Job) { [void](Show-AppMessage -Text "Wait for '$($script:Job.Title)' to finish, or press Stop."); return }
    $exePath = Get-OpenSsh $Exe
    if (-not $exePath) { return }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = ConvertTo-ArgLine $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $env:USERPROFILE

    try { $p = [Diagnostics.Process]::Start($psi) }
    catch { [void](Show-AppMessage -Kind Error -Text "Couldn't start $Exe`n$($_.Exception.Message)"); return }
    try { $p.StandardInput.Close() } catch { Write-Verbose 'stdin already closed' }

    $script:Job = @{
        Machine = $Machine; Title = $Title; Exe = $Exe; Process = $p; Started = Get-Date; Timeout = $TimeoutSeconds
        OutReader = $p.StandardOutput; ErrReader = $p.StandardError
        OutTask = $p.StandardOutput.ReadLineAsync(); ErrTask = $p.StandardError.ReadLineAsync()
        ErrText = New-Object Text.StringBuilder; Lines = 0; Stopped = $false; TimedOut = $false
        RetryArguments = $RetryArguments; RetryWhen = $RetryWhen
    }
    if ($script:UI.TxtOutput.Text) { Add-Output '' }
    Add-Output ('--- {0} on {1}  ({2})' -f $Title, $Machine.Name, (Get-Date).ToString('HH:mm:ss'))
    $script:UI.BtnStop.Visibility = 'Visible'
    Set-Status "$Title on $($Machine.Name)..." 'Ink'
    Write-AppLog "$Title on $($Machine.Name): $Exe $($psi.Arguments)"
    $script:JobTimer.Start()
}

function Update-Remote {
    $j = $script:Job
    if (-not $j) { $script:JobTimer.Stop(); return }
    foreach ($s in 'Out', 'Err') {
        $guard = 0
        while ($j["${s}Task"] -and $j["${s}Task"].IsCompleted -and $guard -lt 500) {
            $task = $j["${s}Task"]
            $line = $null
            if (-not $task.IsFaulted) { $line = $task.Result }
            if ($null -eq $line) { $j["${s}Task"] = $null; break }
            Add-Output $line
            $j.Lines++
            if ($s -eq 'Err') { [void]$j.ErrText.AppendLine($line) }
            $j["${s}Task"] = $j["${s}Reader"].ReadLineAsync()
            $guard++
        }
    }
    if (-not $j.OutTask -and -not $j.ErrTask -and $j.Process.HasExited) { Complete-Remote; return }
    $secs = [int]((Get-Date) - $j.Started).TotalSeconds
    if ($j.Timeout -gt 0 -and $secs -ge $j.Timeout -and -not $j.TimedOut) {
        $j.TimedOut = $true
        try { if (-not $j.Process.HasExited) { $j.Process.Kill() } } catch { Write-Verbose 'already ended' }
    }
    if ($secs -ge 2) { Set-Status "$($j.Title) on $($j.Machine.Name)... $secs s" 'Ink' }
}

function Stop-Remote {
    $j = $script:Job
    if (-not $j) { return }
    $j.Stopped = $true
    try { if (-not $j.Process.HasExited) { $j.Process.Kill() } } catch { Write-Verbose 'already ended' }
}

function Complete-Remote {
    $j = $script:Job
    $script:Job = $null
    $script:JobTimer.Stop()
    $script:UI.BtnStop.Visibility = 'Collapsed'
    $code = -1
    try { $code = $j.Process.ExitCode } catch { Write-Verbose 'no exit code' }
    $err = $j.ErrText.ToString()
    $j.Process.Dispose()
    $m = $j.Machine

    if ($j.Stopped) { Add-Output '--- Stopped.'; Set-Status "$($j.Title) on $($m.Name) was stopped." 'Warn'; return }
    if ($j.TimedOut) {
        Add-Output "--- No end after $($j.Timeout) s, so it was stopped."
        Set-Status "$($j.Title) on $($m.Name) took too long and was stopped. A command that asks questions needs Open terminal." 'Warn'
        return
    }
    if ($code -ne 0 -and $j.RetryArguments -and $err -match $j.RetryWhen) {
        Add-Output '--- Trying again the older way (this machine has no SFTP)...'
        Start-Remote -Machine $m -Title $j.Title -Exe $j.Exe -Arguments $j.RetryArguments -TimeoutSeconds $j.Timeout
        return
    }
    if ($code -eq 0) {
        if ($j.Lines -eq 0) { Add-Output '(done, nothing printed)' }
        Set-Status "$($j.Title) on $($m.Name): done at $((Get-Date).ToString('HH:mm'))." 'Ok'
        Set-MachineState $m.Name 'Online'
        return
    }
    $friendly = Get-FriendlyError $err $m
    if ($friendly) { Add-Output "--- $friendly"; Set-Status $friendly 'Bad' }
    else { Add-Output "--- Finished with exit code $code."; Set-Status "$($j.Title) on $($m.Name) didn't work (exit code $code). The details are in the output." 'Bad' }
    Write-AppLog "$($j.Title) on $($m.Name) failed ($code): $($err.Trim())"
    if ($err -match $script:HostKeyChanged) {
        $forget = Show-AppMessage -Kind Warn -Text "$friendly`n`nIf you know $($m.Name) was reinstalled or got a new address, forget its old identity and try again. If not, leave it: another machine could be pretending to be $($m.Name)." -YesText 'Forget old identity' -NoText 'Leave it'
        if ($forget) { Remove-KnownHost $m }
    }
}

function Remove-KnownHost($Machine) {
    $keygen = Get-OpenSsh 'ssh-keygen.exe'
    if (-not $keygen) { return }
    $hostKey = if ($Machine.Port -and $Machine.Port -ne 22) { "[$($Machine.Address)]:$($Machine.Port)" } else { $Machine.Address }
    $ErrorActionPreference = 'Continue'   # ssh-keygen reports on stderr; that isn't a failure here
    try {
        $out = & $keygen -R $hostKey 2>&1 | Out-String
        Write-AppLog "ssh-keygen -R $hostKey : $($out.Trim())"
        Add-Output "--- Forgot the old identity of $hostKey. The next connection remembers the new one."
        Set-Status "Forgot $($Machine.Name)'s old identity. Try again." 'Ok'
    } catch { [void](Show-AppMessage -Kind Error -Text "Couldn't forget the old identity:`n$($_.Exception.Message)") }
}

function Test-HostKey {
    <# Before a terminal or a PowerShell window opens to a machine: a quick, silent ssh (no
       password, nothing run) to see whether the machine's identity (host key) still matches
       the one this PC remembers. When it has changed, it shows the new fingerprint, says how
       to check it on the machine itself, and offers to forget the old one. Returns $false
       only when the identity changed and was left alone, so the caller doesn't open a
       window that would just show ssh's warning. #>
    param($Machine, [Windows.Window]$Owner = $script:Window)
    $ssh = Find-OpenSsh 'ssh.exe'
    if (-not $ssh) { return $true }
    $err = ''
    $p = $null
    try { [Windows.Input.Mouse]::OverrideCursor = [Windows.Input.Cursors]::Wait } catch { Write-Verbose 'no cursor' }
    try {
        $si = New-Object Diagnostics.ProcessStartInfo
        $si.FileName = $ssh
        $si.Arguments = ConvertTo-ArgLine (Get-SshArguments $Machine 'exit')
        $si.UseShellExecute = $false; $si.CreateNoWindow = $true
        $si.RedirectStandardError = $true; $si.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($si)
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(12000)) { try { $p.Kill() } catch { Write-Verbose 'already ended' } }
        if ($errTask.Wait(1000)) { $err = $errTask.Result }
    } catch { return $true } finally { if ($p) { $p.Dispose() }; try { [Windows.Input.Mouse]::OverrideCursor = $null } catch { Write-Verbose 'no cursor' } }
    if ($err -notmatch $script:HostKeyChanged) { return $true }
    Write-AppLog "Host key changed for $($Machine.Name): $($err.Trim())"
    $n = $Machine.Name
    $fp = if ($err -match '(SHA256:[A-Za-z0-9+/=]+)') { $Matches[1] } else { '' }
    $text = "$n's identity (host key) has changed since this PC last connected. That's normal after $n was reinstalled or rebuilt, or when it took over an address another machine had."
    if ($fp) { $text += "`n`n$n now shows:`n$fp`n`nTo be sure it's really $n, run this on $n itself (its own screen, not over SSH) and check the SHA256 part matches:`nssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" }
    $text += "`n`nIf it matches, or you know $n was reinstalled, forget the old identity. If not, leave it: another machine could be pretending to be $n."
    $forget = Show-AppMessage -Owner $Owner -Kind Warn -Title 'Identity changed' -Text $text -YesText 'Forget old identity' -NoText 'Leave it'
    if (-not $forget) { Set-Status "Left $n's changed identity alone, so nothing was opened." 'Warn'; return $false }
    Remove-KnownHost $Machine
    return $true
}

function Invoke-RemoteCommand {
    <# Runs one shell command on the selected machine. #>
    param([string]$Title, [string]$Command, [int]$TimeoutSeconds = 60)
    $m = Get-SelectedMachine
    if (-not $m) { return }
    Start-Remote -Machine $m -Title $Title -Exe 'ssh.exe' -Arguments (Get-SshArguments $m ($script:PathPrefix + $Command)) -TimeoutSeconds $TimeoutSeconds
}

function Invoke-TypedCommand {
    $text = $script:UI.TxtCommand.Text.Trim()
    if ($text) { Invoke-RemoteCommand -Title $text -Command $text -TimeoutSeconds 120 }
}

function Invoke-Compose {
    param([ValidateSet('pull', 'up', 'down')][string]$Action)
    $m = Get-SelectedMachine
    if (-not $m) { return }
    if (-not $m.Folder) { [void](Show-AppMessage -Text "Set $($m.Name)'s compose folder first (Edit)."); return }
    if ($Action -eq 'down') {
        $ok = Show-AppMessage -Kind Question -Text "Stop and remove every container in $($m.Folder) on $($m.Name)?`n`nTheir settings and data stay where they are. Up starts them again." -YesText 'Compose down' -NoText 'Cancel'
        if (-not $ok) { return }
    }
    $project = if ($m.Project) { ' -p ' + (ConvertTo-ShQuote $m.Project) } else { '' }
    $verb = switch ($Action) { 'pull' { 'pull' } 'up' { 'up -d' } 'down' { 'down' } }
    $cmd = 'cd {0} && docker compose --ansi never --progress plain{1} {2}' -f (ConvertTo-ShQuote $m.Folder), $project, $verb
    Invoke-RemoteCommand -Title "Compose $Action" -Command $cmd -TimeoutSeconds 3600
}

# ---------------------------------------------------------------------------
#  Windows of their own (for what asks for a password or needs a terminal)
# ---------------------------------------------------------------------------
function Open-Terminal {
    <# Opens ssh in a terminal window (Windows Terminal, if Windows is set to use it), optionally running one command. #>
    param($Machine, [string]$Command)
    $ssh = Get-OpenSsh 'ssh.exe'
    if (-not $ssh) { return $false }
    if (-not (Test-HostKey $Machine)) { return $false }
    $line = ConvertTo-ArgLine (Get-SshArguments $Machine $Command -Interactive -Tty:([bool]$Command))
    try {
        Start-Process -FilePath $ssh -ArgumentList $line
        Write-AppLog "Terminal to $($Machine.Name): ssh $line"
        return $true
    } catch {
        [void](Show-AppMessage -Kind Error -Text "Couldn't open a terminal:`n$($_.Exception.Message)")
        return $false
    }
}

function Start-PowerShellWindow {
    <# Opens a PowerShell window that runs $Script and stays open so the result can be read. #>
    param([string]$Script, [string]$Title)
    $full = "`$Host.UI.RawUI.WindowTitle = '$($Title.Replace("'", "''"))'`r`n$Script"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', $encoded)
        Write-AppLog "PowerShell window: $Title"
        return $true
    } catch {
        [void](Show-AppMessage -Kind Error -Text "Couldn't open PowerShell:`n$($_.Exception.Message)")
        return $false
    }
}

function Restart-SelectedMachine {
    $m = Get-SelectedMachine
    if (-not $m) { return }
    $ok = Show-AppMessage -Kind Question -Text "Restart $($m.Name) now?`n`nEverything on it stops for a few minutes, its containers too. A terminal opens and asks for $($m.User)'s password (sudo)." -YesText 'Restart' -NoText 'Cancel'
    if (-not $ok) { return }
    if (Open-Terminal $m 'sudo reboot') {
        Set-Status "Restart sent to $($m.Name). It's back in a few minutes; its dot turns green again when it answers." 'Warn'
    }
}

# ---------------------------------------------------------------------------
#  Files
# ---------------------------------------------------------------------------
function Send-Files {
    $m = Get-SelectedMachine
    if (-not $m) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Files to copy to $($m.Name)"
    $dlg.Multiselect = $true
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $files = @($dlg.FileNames)
    $default = if ($m.Folder) { $m.Folder } else { '~' }
    $to = Show-AppInput -Title 'Send files' -Prompt "Copy $($files.Count) file(s) to this folder on $($m.Name):" -Default $default -Hint 'A file with the same name there is replaced.'
    if (-not $to) { return }
    $remote = '{0}:{1}/' -f (Get-Login $m), $to.TrimEnd('/')
    $paths = $files + $remote
    Start-Remote -Machine $m -Title 'Send files' -Exe 'scp.exe' -TimeoutSeconds 0 `
        -Arguments (Get-ScpArguments $m $paths) -RetryArguments (Get-ScpArguments $m $paths -Legacy) -RetryWhen $script:NoSftp
}

function Receive-File {
    <# Browse the machine, pick files, pick a folder on this PC, copy them there. #>
    $m = Get-SelectedMachine
    if (-not $m) { return }
    $start = if ($m.Folder) { $m.Folder } else { '~' }
    $files = @(Show-RemoteBrowser -Machine $m -Start $start)
    if ($files.Count -eq 0) { return }
    $to = Select-LocalFolder "Copy $($files.Count) file(s) from $($m.Name) to this folder:"
    if (-not $to) { return }
    $existing = @(foreach ($f in $files) { $n = ($f -split '/')[-1]; if (Test-Path -LiteralPath (Join-Path $to $n)) { $n } })
    if ($existing.Count -gt 0) {
        $ok = Show-AppMessage -Kind Question -Text ("Already in {0}:`n{1}`n`nReplace with the copies from {2}?" -f $to, ($existing -join "`n"), $m.Name) -YesText 'Replace' -NoText 'Cancel'
        if (-not $ok) { return }
    }
    $login = Get-Login $m
    # SFTP takes the path as it is; the older way (scp -O) hands it to the machine's shell, so it's quoted there.
    $paths  = @(foreach ($f in $files) { '{0}:{1}' -f $login, $f }) + $to
    $legacy = @(foreach ($f in $files) { '{0}:{1}' -f $login, (ConvertTo-ShQuote $f) }) + $to
    Start-Remote -Machine $m -Title 'Get files' -Exe 'scp.exe' -TimeoutSeconds 0 `
        -Arguments (Get-ScpArguments $m $paths) -RetryArguments (Get-ScpArguments $m $legacy -Legacy -QuotedNames) -RetryWhen $script:NoSftp
}

# Windows' own (Explorer-style) folder picker. The older FolderBrowserDialog tree doesn't reliably
# open on the folder it's given.
if (-not ('SshToolkit.FolderPicker' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SshToolkit {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] internal class FileOpenDialogCom { }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
    }
    public static class FolderPicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IShellItem ppv);
        public static string Pick(IntPtr owner, string title, string okLabel, string start) {
            IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogCom();
            try {
                uint options;
                dlg.GetOptions(out options);
                dlg.SetOptions(options | 0x20 | 0x40 | 0x800);   // pick folders, file system only, must exist
                dlg.SetTitle(title);
                dlg.SetOkButtonLabel(okLabel);
                if (!string.IsNullOrEmpty(start)) {
                    try { Guid g = typeof(IShellItem).GUID; IShellItem item; SHCreateItemFromParsingName(start, IntPtr.Zero, ref g, out item); dlg.SetFolder(item); }
                    catch (Exception) { }
                }
                if (dlg.Show(owner) != 0) { return null; }
                IShellItem result;
                dlg.GetResult(out result);
                string path;
                result.GetDisplayName(0x80058000, out path);   // SIGDN_FILESYSPATH
                return path;
            } finally { Marshal.ReleaseComObject(dlg); }
        }
    }
}
'@
}

function Select-LocalFolder([string]$Title) {
    <# Pick a folder on this PC, starting in the last one used (or Downloads). Returns the path or $null. #>
    $start = Join-Path $env:USERPROFILE 'Downloads'
    if ($script:LastGetFolder -and (Test-Path -LiteralPath $script:LastGetFolder)) { $start = $script:LastGetFolder }
    $owner = (New-Object Windows.Interop.WindowInteropHelper $script:Window).Handle
    $path = [SshToolkit.FolderPicker]::Pick($owner, $Title, 'Copy here', $start)
    if (-not $path) { return $null }
    $script:LastGetFolder = $path
    return $path
}

# ---------------------------------------------------------------------------
#  Remote file picker: lists a folder on the machine over SSH (in the background,
#  so the window never freezes) and returns the files picked.
# ---------------------------------------------------------------------------
if (-not ('SshToolkit.FileRow' -as [type])) {
    Add-Type -TypeDefinition 'namespace SshToolkit { public class FileRow { public string Name { get; set; } public string Glyph { get; set; } public string Size { get; set; } public string Modified { get; set; } public bool IsFolder { get; set; } } }'
}

$script:BrowseXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="700" Height="560" MinWidth="480" MinHeight="340" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources>
        <!--THEME-->
        <Style x:Key="FileItem" TargetType="ListBoxItem">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="8,4" Margin="0,0,0,1">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Raised}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <DockPanel Margin="18,16,18,10">
        <Grid DockPanel.Dock="Top">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Button x:Name="BrUp" Content="Up" Style="{StaticResource Btn}" MinWidth="56"/>
            <Button x:Name="BrHome" Grid.Column="1" Content="Home" Style="{StaticResource Btn}" MinWidth="56"/>
            <TextBox x:Name="BrPath" Grid.Column="2" Style="{StaticResource Field}" FontFamily="Consolas" Margin="0,0,0,8"
                     ToolTip="Type a folder and press Enter"/>
        </Grid>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="BrHidden" Content="Show hidden files" Foreground="{StaticResource Ink}" VerticalAlignment="Center" Margin="2,0,0,8"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="BrGet" Content="Get" Style="{StaticResource PrimaryBtn}" IsEnabled="False"/>
                <Button x:Name="BrCancel" Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,0,8"/>
            </StackPanel>
        </Grid>
        <TextBlock x:Name="BrStatus" DockPanel.Dock="Bottom" Foreground="{StaticResource SoftInk}" TextWrapping="Wrap" Margin="2,8,0,0"/>
        <Grid DockPanel.Dock="Top" Margin="11,4,27,4">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
            <TextBlock Text="NAME" Style="{StaticResource Heading}" Margin="26,0,0,0"/>
            <TextBlock Grid.Column="1" Text="SIZE" Style="{StaticResource Heading}" Margin="0,0,16,0" HorizontalAlignment="Right"/>
            <TextBlock Grid.Column="2" Text="MODIFIED" Style="{StaticResource Heading}" Margin="0"/>
        </Grid>
        <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="2">
            <ListBox x:Name="BrList" Background="Transparent" BorderThickness="0" SelectionMode="Extended"
                     ItemContainerStyle="{StaticResource FileItem}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                <ListBox.ItemTemplate>
                    <DataTemplate>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="{Binding Glyph}" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Accent}" Width="18" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                <TextBlock Text="{Binding Name}" Foreground="{StaticResource Ink}" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                            <TextBlock Grid.Column="1" Text="{Binding Size}" Foreground="{StaticResource SoftInk}" HorizontalAlignment="Right" Margin="0,0,16,0"/>
                            <TextBlock Grid.Column="2" Text="{Binding Modified}" Foreground="{StaticResource SoftInk}"/>
                        </Grid>
                    </DataTemplate>
                </ListBox.ItemTemplate>
            </ListBox>
        </Border>
    </DockPanel>
</Window>
'@

function ConvertTo-RemoteDir([string]$Path) {
    <# A folder for the machine's shell: ~ and ~/... become $HOME, everything else is quoted. #>
    $p = $Path.Trim()
    if (-not $p -or $p -eq '~') { return '"$HOME"' }
    if ($p.StartsWith('~/')) { return '"$HOME"/' + (ConvertTo-ShQuote $p.Substring(2)) }
    return (ConvertTo-ShQuote $p)
}

function Format-Size([long]$Bytes) {
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:0.#} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:0.#} MB' -f ($Bytes / 1MB)) }
    return ('{0:0.##} GB' -f ($Bytes / 1GB))
}

function Set-BrowseStatus([string]$Text, [string]$Tone = 'SoftInk') {
    $s = $script:Browse.Window.FindName('BrStatus')
    $s.Text = $Text
    $s.Foreground = $script:Brush[$Tone]
}

function Stop-RemoteListing {
    $b = $script:Browse
    if ($b.Timer) { $b.Timer.Stop() }
    if ($b.Proc) {
        try { if (-not $b.Proc.HasExited) { $b.Proc.Kill() } } catch { Write-Verbose 'already ended' }
        $b.Proc.Dispose()
        $b.Proc = $null
    }
}

function Start-RemoteListing([string]$Path) {
    <# Starts listing $Path on the machine; Update-RemoteListing shows it when it arrives. #>
    $b = $script:Browse
    Stop-RemoteListing
    $ssh = Find-OpenSsh 'ssh.exe'
    if (-not $ssh) { Set-BrowseStatus "ssh.exe $script:NoOpenSsh" 'Bad'; return }
    $globs = if ($b.Window.FindName('BrHidden').IsChecked) { '* .*' } else { '*' }
    # Line 1 is the folder's full path, then one line per entry: type|size|modified (Unix time)|name.
    $cmd = $script:PathPrefix + "command -v stat >/dev/null || exit 4; cd -- $(ConvertTo-RemoteDir $Path) 2>&1 || exit 3; pwd; stat -L -c '%F|%s|%Y|%n' -- $globs 2>/dev/null; exit 0"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ssh
    $psi.Arguments = ConvertTo-ArgLine (Get-SshArguments $b.Machine $cmd)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    try { $p = [Diagnostics.Process]::Start($psi) }
    catch { Set-BrowseStatus "Couldn't start ssh.exe: $($_.Exception.Message)" 'Bad'; return }
    try { $p.StandardInput.Close() } catch { Write-Verbose 'stdin already closed' }
    $b.Proc = $p
    $b.OutTask = $p.StandardOutput.ReadToEndAsync()
    $b.ErrTask = $p.StandardError.ReadToEndAsync()
    $b.Started = Get-Date
    $b.Asked = $Path
    $b.Window.FindName('BrList').IsEnabled = $false
    Set-BrowseStatus "Opening $Path on $($b.Machine.Name)..."
    $b.Timer.Start()
}

function Update-RemoteListing {
    <# Timer tick: shows the listing once ssh has finished, or gives up after 20 seconds. #>
    $b = $script:Browse
    $p = $b.Proc
    if (-not $p) { $b.Timer.Stop(); return }
    if (-not ($p.HasExited -and $b.OutTask.IsCompleted -and $b.ErrTask.IsCompleted)) {
        if (((Get-Date) - $b.Started).TotalSeconds -ge 20) {
            Stop-RemoteListing
            $b.Window.FindName('BrList').IsEnabled = $true
            Set-BrowseStatus "$($b.Machine.Name) didn't answer within 20 seconds. Check it's switched on, then try again." 'Bad'
        }
        return
    }
    $b.Timer.Stop()
    $code = $p.ExitCode
    $out = $b.OutTask.Result
    $err = $b.ErrTask.Result
    $p.Dispose()
    $b.Proc = $null
    $list = $b.Window.FindName('BrList')
    $list.IsEnabled = $true

    if ($code -eq 3) {
        $why = ($out.Trim() -split ':')[-1].Trim()
        Set-BrowseStatus "Can't open $($b.Asked) on $($b.Machine.Name): $why." 'Bad'
        return
    }
    if ($code -eq 4) { Set-BrowseStatus "$($b.Machine.Name) has no stat command, so its folders can't be listed." 'Bad'; return }
    if ($code -ne 0) {
        $friendly = Get-FriendlyError $err $b.Machine
        if (-not $friendly) { $friendly = "Couldn't list the folder (exit code $code). $(($err.Trim() -split "`n")[0])" }
        Write-AppLog "File picker on $($b.Machine.Name) failed ($code): $($err.Trim())"
        Set-BrowseStatus $friendly 'Bad'
        return
    }

    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne '' })
    $dir = $lines[0]
    $rows = foreach ($line in @($lines | Select-Object -Skip 1)) {
        $parts = $line.Split([char]'|', 4)
        if ($parts.Count -lt 4 -or $parts[3] -eq '.' -or $parts[3] -eq '..') { continue }
        $isFolder = $parts[0] -eq 'directory'
        $size = 0L; [void][long]::TryParse($parts[1], [ref]$size)
        $time = 0L; [void][long]::TryParse($parts[2], [ref]$time)
        New-Object SshToolkit.FileRow -Property @{
            Name     = $parts[3]
            Glyph    = if ($isFolder) { [string][char]0xF12B } else { [string][char]0xE8A5 }
            Size     = if ($isFolder) { '' } else { Format-Size $size }
            Modified = [DateTimeOffset]::FromUnixTimeSeconds($time).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
            IsFolder = $isFolder
        }
    }
    $rows = @($rows | Sort-Object @{ Expression = { -not $_.IsFolder } }, Name)
    $list.ItemsSource = $rows
    $b.Path = $dir
    $b.Window.FindName('BrPath').Text = $dir
    $folders = @($rows | Where-Object IsFolder).Count
    $fileCount = $rows.Count - $folders
    if ($rows.Count -eq 0) { Set-BrowseStatus 'This folder is empty.' }
    else { Set-BrowseStatus "$folders folder(s), $fileCount file(s). Double-click a folder to open it; pick one or more files (Ctrl or Shift for several) and click Get." }
}

function Get-RemoteChild([string]$Name) {
    $dir = $script:Browse.Path
    if ($dir -eq '/') { return "/$Name" }
    return "$dir/$Name"
}

function Complete-RemoteBrowser {
    <# Get: return the selected files (folders are left out) and close. #>
    $b = $script:Browse
    $picked = @($b.Window.FindName('BrList').SelectedItems | Where-Object { -not $_.IsFolder } | ForEach-Object { Get-RemoteChild $_.Name })
    if ($picked.Count -eq 0) { return }
    $b.Result = $picked
    $b.Window.Close()
}

function Show-RemoteBrowser {
    <# The file picker for a machine. Returns the full paths of the files picked, or nothing. #>
    param([Parameter(Mandatory)]$Machine, [string]$Start = '~')
    $w = New-XamlWindow $script:BrowseXaml $script:Window
    $w.Title = "Get files from $($Machine.Name)"
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:Browse = @{ Window = $w; Machine = $Machine; Timer = $timer; Proc = $null; Path = $Start; Asked = $Start; Result = $null }
    $timer.Add_Tick({ Invoke-Safely { Update-RemoteListing } })

    $w.FindName('BrUp').Add_Click({
        $dir = $script:Browse.Path
        if ($dir -and $dir -ne '/' -and $dir.StartsWith('/')) {
            $parent = $dir.Substring(0, $dir.LastIndexOf('/'))
            if (-not $parent) { $parent = '/' }
            Start-RemoteListing $parent
        }
    })
    $w.FindName('BrHome').Add_Click({ Start-RemoteListing '~' })
    $hidden = $w.FindName('BrHidden')
    $hidden.Add_Checked({ Start-RemoteListing $script:Browse.Path })
    $hidden.Add_Unchecked({ Start-RemoteListing $script:Browse.Path })
    $w.FindName('BrPath').Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') { $e.Handled = $true; Start-RemoteListing $s.Text }
    })
    $list = $w.FindName('BrList')
    $list.Add_SelectionChanged({
        $any = @($script:Browse.Window.FindName('BrList').SelectedItems | Where-Object { -not $_.IsFolder }).Count -gt 0
        $script:Browse.Window.FindName('BrGet').IsEnabled = $any
    })
    $list.Add_MouseDoubleClick({
        $item = $script:Browse.Window.FindName('BrList').SelectedItem
        if (-not $item) { return }
        if ($item.IsFolder) { Start-RemoteListing (Get-RemoteChild $item.Name) } else { Complete-RemoteBrowser }
    })
    $list.Add_KeyDown({
        param($s, $e)
        if ($e.Key -ne 'Return') { return }
        $e.Handled = $true
        $item = $s.SelectedItem
        if ($item -and $item.IsFolder -and $s.SelectedItems.Count -eq 1) { Start-RemoteListing (Get-RemoteChild $item.Name) } else { Complete-RemoteBrowser }
    })
    $w.FindName('BrGet').Add_Click({ Complete-RemoteBrowser })
    $w.FindName('BrCancel').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $w.Add_ContentRendered({ Start-RemoteListing $script:Browse.Path })
    $w.Add_Closed({ Stop-RemoteListing })
    [void]$w.ShowDialog()
    $result = $script:Browse.Result
    $script:Browse = $null
    if ($result) { return $result }
}

# ---------------------------------------------------------------------------
#  Which machines answer? A quick check that each SSH port takes a connection
#  (no sign-in), for every machine at once, and again every minute.
# ---------------------------------------------------------------------------
$script:State = @{}
$script:Checks = @()

# A plain .NET class for the list rows: WPF can't read a brush through a PowerShell object, so the dot stayed blank.
if (-not ('SshToolkit.MachineRow' -as [type])) {
    Add-Type -TypeDefinition 'namespace SshToolkit { public class MachineRow { public string Name { get; set; } public string Detail { get; set; } public string Dot { get; set; } } }'
}

function Set-MachineState([string]$Name, [string]$State) {
    if ($script:State[$Name] -ne $State) { $script:State[$Name] = $State; Update-MachineList }
}

function Start-ReachCheck {
    if ($script:Checks.Count) { return }   # one check at a time
    $isNew = $false
    $script:Checks = @(foreach ($m in $script:Machines) {
        $client = New-Object Net.Sockets.TcpClient
        $task = $null
        try { $task = $client.ConnectAsync([string]$m.Address, [int]$m.Port) } catch { Write-Verbose "No check for $($m.Name)" }
        if (-not $script:State.ContainsKey($m.Name)) { $script:State[$m.Name] = 'Checking'; $isNew = $true }
        @{ Name = $m.Name; Client = $client; Task = $task; Started = Get-Date }
    })
    $script:UI.BtnCheck.IsEnabled = $false
    $script:UI.TxtChecked.Text = 'Checking which machines answer...'
    if ($isNew) { Update-MachineList }
    $script:ReachTimer.Start()
}

function Update-ReachCheck {
    $left = @()
    $changed = $false
    foreach ($c in $script:Checks) {
        $result = $null
        if (-not $c.Task -or $c.Task.IsFaulted -or $c.Task.IsCanceled) { $result = 'Offline' }
        elseif ($c.Task.IsCompleted) { $result = $(if ($c.Client.Connected) { 'Online' } else { 'Offline' }) }
        elseif (((Get-Date) - $c.Started).TotalSeconds -ge 3) { $result = 'Offline' }
        if ($result) {
            if ($script:State[$c.Name] -ne $result) { $script:State[$c.Name] = $result; $changed = $true }
            try { $c.Client.Close() } catch { Write-Verbose 'closed' }
        } else { $left += $c }
    }
    $script:Checks = $left
    if (-not $left.Count) {
        $script:ReachTimer.Stop()
        $script:UI.BtnCheck.IsEnabled = $true
        $on = @($script:Machines | Where-Object { $script:State[$_.Name] -eq 'Online' }).Count
        $script:UI.TxtChecked.Text = "$on of $($script:Machines.Count) answering  ·  checked $((Get-Date).ToString('HH:mm'))"
    }
    if ($changed) { Update-MachineList }
}

function Update-MachineList {
    <# Redraws the machine list (dot, name, login) and the selected machine's details. #>
    $ui = $script:UI
    $keep = $ui.LstMachines.SelectedIndex
    $script:Refreshing = $true
    $items = foreach ($m in $script:Machines) {
        $dot = switch ([string]$script:State[$m.Name]) { 'Online' { $script:Colours.Ok } 'Offline' { $script:Colours.Bad } default { $script:Colours.Unknown } }
        $port = if ($m.Port -and $m.Port -ne 22) { ":$($m.Port)" } else { '' }
        New-Object SshToolkit.MachineRow -Property @{ Name = $m.Name; Detail = "$($m.User)@$($m.Address)$port"; Dot = $dot }
    }
    $ui.LstMachines.ItemsSource = @($items)
    if ($keep -ge $script:Machines.Count) { $keep = $script:Machines.Count - 1 }
    if ($keep -lt 0 -and $script:Machines.Count) { $keep = 0 }
    $ui.LstMachines.SelectedIndex = $keep
    $script:Refreshing = $false
    Update-Details
}

function Update-Details {
    $ui = $script:UI
    $m = Get-SelectedMachine
    foreach ($b in $script:MachineControls) { $ui[$b].IsEnabled = [bool]$m }
    if (-not $m) {
        $ui.TxtName.Text = 'No machine'
        $ui.TxtLogin.Text = 'Click Add (bottom left) to add your first machine.'
        $ui.TxtFolder.Text = ''
        $ui.TxtState.Text = ''
        return
    }
    $ui.TxtName.Text = $m.Name
    $port = if ($m.Port -and $m.Port -ne 22) { " -p $($m.Port)" } else { '' }
    $ui.TxtLogin.Text = "ssh$port $(Get-Login $m)"
    $folder = if ($m.Folder) { $m.Folder } else { '(not set)' }
    $proj = if ($m.Project) { "   (project $($m.Project))" } else { '' }
    $ui.TxtFolder.Text = "Compose folder: $folder$proj"
    switch ([string]$script:State[$m.Name]) {
        'Online'  { $ui.TxtState.Text = 'Answering'; $ui.TxtState.Foreground = $script:Brush.Ok }
        'Offline' { $ui.TxtState.Text = "Can't reach it"; $ui.TxtState.Foreground = $script:Brush.Bad }
        default   { $ui.TxtState.Text = 'Checking...'; $ui.TxtState.Foreground = $script:Brush.SoftInk }
    }
}

# ---------------------------------------------------------------------------
#  Add / edit a machine
# ---------------------------------------------------------------------------
$script:EditXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="480" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <StackPanel Margin="22,8,22,14">
        <TextBlock Text="Name" Style="{StaticResource Label}"/>
        <TextBox x:Name="EdName" Style="{StaticResource Field}"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="Address (an IP address works best)" Style="{StaticResource Label}"/>
                <TextBox x:Name="EdAddress" Style="{StaticResource Field}"/>
            </StackPanel>
            <StackPanel Grid.Column="2">
                <TextBlock Text="Port" Style="{StaticResource Label}"/>
                <TextBox x:Name="EdPort" Style="{StaticResource Field}"/>
            </StackPanel>
        </Grid>
        <TextBlock Text="User" Style="{StaticResource Label}"/>
        <TextBox x:Name="EdUser" Style="{StaticResource Field}"/>
        <TextBlock Text="Compose folder (where docker-compose.yml is, and where files are sent to)" Style="{StaticResource Label}" TextWrapping="Wrap"/>
        <TextBox x:Name="EdFolder" Style="{StaticResource Field}" FontFamily="Consolas"/>
        <TextBlock Text="Compose project name (optional: only if the stack was started under another name, like myapp)" Style="{StaticResource Label}" TextWrapping="Wrap"/>
        <TextBox x:Name="EdProject" Style="{StaticResource Field}"/>
        <TextBlock x:Name="EdError" Foreground="{StaticResource Bad}" TextWrapping="Wrap" Margin="0,10,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="EdSave" Content="Save" Style="{StaticResource PrimaryBtn}" IsDefault="True"/>
            <Button x:Name="EdCancel" Content="Cancel" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,0,8"/>
        </StackPanel>
    </StackPanel>
</Window>
'@

function Show-MachineEditor {
    <# Returns a new machine object, or $null if cancelled. -Existing fills in the boxes. #>
    param($Existing)
    $w = New-XamlWindow $script:EditXaml $script:Window
    $w.Title = if ($Existing) { "Edit $($Existing.Name)" } else { 'Add a machine' }
    $e = @{ Window = $w; Result = $null; OldName = $(if ($Existing) { $Existing.Name } else { '' }) }
    foreach ($n in 'EdName', 'EdAddress', 'EdPort', 'EdUser', 'EdFolder', 'EdProject', 'EdError', 'EdSave') { $e[$n] = $w.FindName($n) }
    if ($Existing) {
        $e.EdName.Text = $Existing.Name; $e.EdAddress.Text = $Existing.Address; $e.EdPort.Text = [string]$Existing.Port
        $e.EdUser.Text = $Existing.User; $e.EdFolder.Text = $Existing.Folder; $e.EdProject.Text = $Existing.Project
    } else { $e.EdPort.Text = '22' }
    $script:Edit = $e
    $e.EdSave.Add_Click({
        $e = $script:Edit
        $name = $e.EdName.Text.Trim(); $addr = $e.EdAddress.Text.Trim(); $user = $e.EdUser.Text.Trim()
        $folder = $e.EdFolder.Text.Trim(); $project = $e.EdProject.Text.Trim()
        $port = 0
        $problem = $null
        if (-not $name) { $problem = 'Give the machine a name.' }
        elseif (@($script:Machines | Where-Object { $_.Name -eq $name -and $_.Name -ne $e.OldName }).Count) { $problem = "There's already a machine called $name." }
        elseif (-not $addr -or $addr -match '[\s@/]') { $problem = 'The address is an IP address like 192.168.1.10, or a host name, with no spaces.' }
        elseif (-not [int]::TryParse($e.EdPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $problem = 'The port is a number from 1 to 65535 (SSH is usually 22).' }
        elseif (-not $user -or $user -match '[\s@]') { $problem = 'The user is the name you sign in to that machine with, with no spaces.' }
        elseif ($folder -and -not ($folder.StartsWith('/') -or $folder.StartsWith('~'))) { $problem = 'The compose folder is a full path on that machine, starting with / (or ~).' }
        elseif ($project -and $project -notmatch '^[a-z0-9][a-z0-9_-]*$') { $problem = 'A compose project name uses lower-case letters, digits, - and _.' }
        if ($problem) { $e.EdError.Text = $problem; return }
        if ($folder.Length -gt 1) { $folder = $folder.TrimEnd('/') }
        $e.Result = New-Machine -Name $name -Address $addr -Port $port -User $user -Folder $folder -Project $project
        $e.Window.Close()
    })
    $w.Add_ContentRendered({ [void]$script:Edit.EdName.Focus() })
    [void]$w.ShowDialog()
    $result = $script:Edit.Result
    $script:Edit = $null
    return $result
}

# ---------------------------------------------------------------------------
#  SSH key helper
# ---------------------------------------------------------------------------
$script:KeyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="660" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources><!--THEME--></Window.Resources>
    <StackPanel Margin="22,16,22,14">
        <TextBlock TextWrapping="Wrap" Text="With an SSH key, SSH Toolkit signs in without a password. Make the key once on this PC (step 1), then copy it once to each machine (step 2)."/>
        <TextBlock x:Name="KeyStatus" TextWrapping="Wrap" Margin="0,10,0,0"/>

        <TextBlock Text="STEP 1  -  MAKE A KEY ON THIS PC (press Enter at each question)" Style="{StaticResource Heading}"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="KeyCmd1" Style="{StaticResource Field}" IsReadOnly="True" FontFamily="Consolas" TextWrapping="Wrap" Margin="0,0,8,8"/>
            <Button x:Name="KeyCopy1" Grid.Column="1" Content="Copy" Style="{StaticResource Btn}" VerticalAlignment="Top"/>
            <Button x:Name="KeyRun1" Grid.Column="2" Content="Run it" Style="{StaticResource Btn}" VerticalAlignment="Top" Margin="0,0,0,8"/>
        </Grid>

        <TextBlock x:Name="KeyStep2" Style="{StaticResource Heading}"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="KeyCmd2" Style="{StaticResource Field}" IsReadOnly="True" FontFamily="Consolas" TextWrapping="Wrap" Margin="0,0,8,8"/>
            <Button x:Name="KeyCopy2" Grid.Column="1" Content="Copy" Style="{StaticResource Btn}" VerticalAlignment="Top"/>
            <Button x:Name="KeyRun2" Grid.Column="2" Content="Run it" Style="{StaticResource Btn}" VerticalAlignment="Top" Margin="0,0,0,8"/>
        </Grid>
        <TextBlock TextWrapping="Wrap" Foreground="{StaticResource SoftInk}"
                   Text="Both commands are for PowerShell. Run it opens a PowerShell window that runs the command; step 2 asks for that machine's password once."/>

        <TextBlock Text="STEP 3  -  CHECK IT" Style="{StaticResource Heading}"/>
        <TextBlock TextWrapping="Wrap" Text="Close this and click Uptime. If it answers, the key works."/>
        <TextBlock TextWrapping="Wrap" Foreground="{StaticResource SoftInk}" Margin="0,10,0,0"
                   Text="Synology: SSH must be on (Control Panel &gt; Terminal &amp; SNMP), the user home service on (Control Panel &gt; User &amp; Group &gt; Advanced), and the user an administrator."/>

        <Grid Margin="0,16,0,0">
            <TextBlock x:Name="KeyNote" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,100,0"/>
            <Button x:Name="KeyClose" Content="Close" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Right" IsDefault="True" IsCancel="True" Margin="0,0,0,8"/>
        </Grid>
    </StackPanel>
</Window>
'@

function Get-KeyCommands($Machine) {
    $port = if ($Machine.Port -and $Machine.Port -ne 22) { " -p $($Machine.Port)" } else { '' }
    $remote = 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod go-w ~ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'
    return @{
        One = 'ssh-keygen -t ed25519'
        Two = "Get-Content `"`$env:USERPROFILE\.ssh\id_ed25519.pub`" | ssh$port $(Get-Login $Machine) '$remote'"
    }
}

function Get-PublicKeyPath { return (Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub') }

function Set-KeyNote([string]$Text, [string]$Tone) {
    $script:Key.KeyNote.Text = $Text
    $script:Key.KeyNote.Foreground = $script:Brush[$Tone]
}

function Update-KeyStatus {
    $k = $script:Key
    $pub = Get-PublicKeyPath
    if (Test-Path -LiteralPath $pub) {
        $k.KeyStatus.Text = "This PC has a key ($pub), so step 1 is done."
        $k.KeyStatus.Foreground = $script:Brush.Ok
    } else {
        $k.KeyStatus.Text = 'This PC has no SSH key yet. Start with step 1.'
        $k.KeyStatus.Foreground = $script:Brush.Warn
    }
}

function Copy-KeyCommand([int]$Step) {
    $box = $script:Key["KeyCmd$Step"]
    try {
        [Windows.Clipboard]::SetText($box.Text)
        Set-KeyNote "Step $Step command copied." 'Ok'
    } catch {
        Set-KeyNote 'The clipboard is busy. Select the text and press Ctrl+C instead.' 'Bad'
    }
    [void]$box.Focus()
    $box.SelectAll()
}

function Show-KeyHelper {
    $m = Get-SelectedMachine
    if (-not $m) { return }
    $w = New-XamlWindow $script:KeyXaml $script:Window
    $w.Title = 'SSH key helper'
    $k = @{ Window = $w; Machine = $m }
    foreach ($n in 'KeyStatus', 'KeyCmd1', 'KeyCopy1', 'KeyRun1', 'KeyStep2', 'KeyCmd2', 'KeyCopy2', 'KeyRun2', 'KeyNote', 'KeyClose') { $k[$n] = $w.FindName($n) }
    $cmds = Get-KeyCommands $m
    $k.KeyCmd1.Text = $cmds.One
    $k.KeyCmd2.Text = $cmds.Two
    $k.KeyStep2.Text = "STEP 2  -  COPY THE KEY TO $($m.Name.ToUpper()) (asks for its password once)"
    $script:Key = $k
    Update-KeyStatus
    $k.KeyCopy1.Add_Click({ Copy-KeyCommand 1 })
    $k.KeyCopy2.Add_Click({ Copy-KeyCommand 2 })
    $k.KeyRun1.Add_Click({
        if (Test-Path -LiteralPath (Get-PublicKeyPath)) {
            $again = Show-AppMessage -Owner $script:Key.Window -Kind Warn -Text 'This PC already has a key. A new one would replace it (ssh-keygen asks first), and every machine would need the new key copied to it again.' -YesText 'Run it anyway' -NoText 'Cancel'
            if (-not $again) { return }
        }
        if (Start-PowerShellWindow -Script $script:Key.KeyCmd1.Text -Title 'SSH Toolkit - make a key') {
            Set-KeyNote 'A PowerShell window is making the key. Press Enter at each question, then come back here.' 'Ok'
        }
    })
    $k.KeyRun2.Add_Click({
        if (-not (Test-Path -LiteralPath (Get-PublicKeyPath))) { Set-KeyNote 'Make the key first (step 1).' 'Bad'; return }
        $name = $script:Key.Machine.Name
        Set-KeyNote "Checking $name's identity..." 'SoftInk'
        if (-not (Test-HostKey $script:Key.Machine $script:Key.Window)) { Set-KeyNote "$name's identity has changed and was left alone, so the key wasn't copied." 'Bad'; return }
        if (Start-PowerShellWindow -Script $script:Key.KeyCmd2.Text -Title "SSH Toolkit - copy the key to $name") {
            Set-KeyNote "A PowerShell window is copying the key. Type $name's password there when it asks." 'Ok'
        }
    })
    $k.KeyClose.Add_Click({ $script:Key.Window.Close() })
    $w.Add_Activated({ if ($script:Key) { Update-KeyStatus } })
    [void]$w.ShowDialog()
    $script:Key = $null
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1040" Height="720" MinWidth="820" MinHeight="600"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Page}" Foreground="{DynamicResource Ink}">
    <Window.Resources>
        <!--THEME-->
        <Style x:Key="MachineItem" TargetType="ListBoxItem">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="10,8" Margin="0,0,0,4">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Hover}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource Raised}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="270"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

        <!-- Machines -->
        <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
            <DockPanel Margin="14,14,14,6">
                <TextBlock DockPanel.Dock="Top" Text="MACHINES" Style="{StaticResource Heading}" Margin="2,0,0,8"/>
                <StackPanel DockPanel.Dock="Bottom">
                    <TextBlock x:Name="TxtChecked" Foreground="{StaticResource SoftInk}" FontSize="12" Margin="2,6,0,8" TextWrapping="Wrap"/>
                    <WrapPanel>
                        <Button x:Name="BtnAdd" Content="Add" Style="{StaticResource Btn}" MinWidth="64"/>
                        <Button x:Name="BtnEdit" Content="Edit" Style="{StaticResource Btn}" MinWidth="64"/>
                        <Button x:Name="BtnRemove" Content="Remove" Style="{StaticResource DangerBtn}" MinWidth="64" Margin="0,0,0,8"/>
                    </WrapPanel>
                    <Button x:Name="BtnCheck" Content="Check now" Style="{StaticResource Btn}" HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                </StackPanel>
                <ListBox x:Name="LstMachines" Background="Transparent" BorderThickness="0" ItemContainerStyle="{StaticResource MachineItem}"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Ellipse Width="10" Height="10" Fill="{Binding Dot}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1">
                                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{StaticResource Ink}" TextTrimming="CharacterEllipsis"/>
                                    <TextBlock Text="{Binding Detail}" Foreground="{StaticResource SoftInk}" FontSize="12" TextTrimming="CharacterEllipsis"/>
                                </StackPanel>
                            </Grid>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                </ListBox>
            </DockPanel>
        </Border>

        <!-- Selected machine -->
        <DockPanel Grid.Column="1" Margin="20,14,20,10">
            <StackPanel DockPanel.Dock="Top">
                <Grid>
                    <TextBlock x:Name="TxtName" FontSize="22" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtState" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="SemiBold"/>
                </Grid>
                <TextBlock x:Name="TxtLogin" FontFamily="Consolas" Foreground="{StaticResource SoftInk}" Margin="0,2,0,0"/>
                <TextBlock x:Name="TxtFolder" FontFamily="Consolas" Foreground="{StaticResource SoftInk}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>

                <WrapPanel>
                    <StackPanel Margin="0,0,24,0">
                        <TextBlock Text="CONNECT" Style="{StaticResource Heading}"/>
                        <WrapPanel>
                            <Button x:Name="BtnTerminal" Content="Open terminal" Style="{StaticResource PrimaryBtn}"/>
                            <Button x:Name="BtnKey" Content="Key helper" Style="{StaticResource Btn}"/>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel Margin="0,0,24,0">
                        <TextBlock Text="QUICK COMMANDS" Style="{StaticResource Heading}"/>
                        <WrapPanel>
                            <Button x:Name="BtnDisk" Content="Disk space" Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnUptime" Content="Uptime" Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnPs" Content="Docker ps" Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnRestart" Content="Restart machine" Style="{StaticResource DangerBtn}"/>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel Margin="0,0,24,0">
                        <TextBlock Text="DOCKER COMPOSE (IN THE COMPOSE FOLDER)" Style="{StaticResource Heading}"/>
                        <WrapPanel>
                            <Button x:Name="BtnPull" Content="Pull" Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnUp" Content="Up" Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnDown" Content="Down" Style="{StaticResource DangerBtn}"/>
                        </WrapPanel>
                    </StackPanel>
                    <StackPanel>
                        <TextBlock Text="FILES" Style="{StaticResource Heading}"/>
                        <WrapPanel>
                            <Button x:Name="BtnSend" Content="Send files to it..." Style="{StaticResource Btn}"/>
                            <Button x:Name="BtnGet" Content="Get a file from it..." Style="{StaticResource Btn}"/>
                        </WrapPanel>
                    </StackPanel>
                </WrapPanel>

                <TextBlock Text="RUN A COMMAND" Style="{StaticResource Heading}"/>
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="TxtCommand" Style="{StaticResource Field}" FontFamily="Consolas" Margin="0,0,8,8"
                             ToolTip="Any command that doesn't ask questions; press Enter to run it. For one that does, use Open terminal."/>
                    <Button x:Name="BtnRun" Grid.Column="1" Content="Run" Style="{StaticResource Btn}" Margin="0,0,0,8"/>
                </Grid>

                <Grid>
                    <TextBlock Text="OUTPUT" Style="{StaticResource Heading}" Margin="0,8,0,6"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="BtnStop" Content="Stop" Style="{StaticResource DangerBtn}" Visibility="Collapsed" Padding="10,3" MinWidth="60" Margin="0,0,8,4"/>
                        <Button x:Name="BtnClear" Content="Clear" Style="{StaticResource Btn}" Padding="10,3" MinWidth="60" Margin="0,0,0,4"/>
                    </StackPanel>
                </Grid>
            </StackPanel>
            <TextBox x:Name="TxtOutput" Style="{StaticResource Field}" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
                     Background="{StaticResource Well}" VerticalContentAlignment="Top" TextWrapping="NoWrap" MinHeight="120"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </DockPanel>

        <!-- Status bar -->
        <Border Grid.Row="1" Grid.ColumnSpan="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
            <Grid Margin="14,6,14,6">
                <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,380,0"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="BtnTheme" Style="{StaticResource Btn}" Padding="10,3" MinWidth="70" Margin="0,0,8,0" ToolTip="Click to switch: Follow Windows, Dark, Light"/>
                    <Button x:Name="BtnHelp" Content="Help" Style="{StaticResource Btn}" Padding="10,3" MinWidth="70" Margin="0,0,8,0" ToolTip="Help (F1)"/>
                    <Button x:Name="BtnAbout" Content="About" Style="{StaticResource Btn}" Padding="10,3" MinWidth="70" Margin="0"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

# Everything that needs a machine selected.
$script:MachineControls = 'BtnEdit', 'BtnRemove', 'BtnTerminal', 'BtnKey', 'BtnDisk', 'BtnUptime', 'BtnPs', 'BtnRestart', 'BtnPull', 'BtnUp', 'BtnDown', 'BtnSend', 'BtnGet', 'BtnRun', 'TxtCommand'

function Invoke-Safely {
    <# Runs a button's work; anything unexpected goes to the log and an app message instead of being lost. #>
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        Write-AppLog "Error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
        [void](Show-AppMessage -Kind Error -Text "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath")
    }
}

function Add-Machine {
    $new = Show-MachineEditor
    if (-not $new) { return }
    [void]$script:Machines.Add($new)
    Save-Settings
    Update-MachineList
    $script:UI.LstMachines.SelectedIndex = $script:Machines.Count - 1
    Start-ReachCheck
}

function Edit-Machine {
    $i = $script:UI.LstMachines.SelectedIndex
    $m = Get-SelectedMachine
    if (-not $m) { return }
    $new = Show-MachineEditor -Existing $m
    if (-not $new) { return }
    $script:State.Remove($m.Name)
    $script:Machines[$i] = $new
    Save-Settings
    Update-MachineList
    Start-ReachCheck
}

function Remove-Machine {
    $m = Get-SelectedMachine
    if (-not $m) { return }
    if (Show-AppMessage -Kind Question -Text "Remove $($m.Name) from the list?`n`nNothing on the machine itself changes." -YesText 'Remove' -NoText 'Cancel') {
        $script:Machines.Remove($m)
        $script:State.Remove($m.Name)
        Save-Settings
        Update-MachineList
    }
}

function Switch-Theme {
    <# The Theme button: Follow Windows -> Dark -> Light -> Follow Windows. #>
    $names = @($script:ThemeNames.Keys)
    $next = $names[($names.IndexOf($script:Theme) + 1) % $names.Count]
    Set-Theme $next
    Save-Settings
    Set-Status "Theme: $($script:ThemeNames[$next])$(if ($next -eq 'System') { if ($script:IsDark) { ' (dark now)' } else { ' (light now)' } })."
}

function Set-Theme([string]$Name) {
    <# Applies a theme to the open main window by recolouring its brushes; windows opened later use it too. #>
    $script:Theme = $Name
    Use-Palette
    $w = $script:Window
    if (-not $w) { return }
    foreach ($k in $script:Colours.Keys) {
        # The bare brush, not PowerShell's wrapper around it, or WPF sees a string.
        $w.Resources.Remove($k)
        $w.Resources.Add($k, $script:Brush[$k].psobject.BaseObject)
    }
    Set-TitleBar $w
    $script:UI.BtnTheme.Content = "Theme: $($script:ThemeNames[$Name])"
    $script:UI.TxtStatus.Foreground = $script:Brush.SoftInk
    Update-MachineList
}

function Initialize-MainWindow {
    $w = New-XamlWindow $script:MainXaml
    $w.Title = $script:AppName
    $script:Window = $w
    $ui = @{}
    foreach ($n in @('LstMachines', 'TxtChecked', 'BtnAdd', 'BtnCheck', 'TxtName', 'TxtState', 'TxtLogin', 'TxtFolder', 'BtnStop', 'BtnClear', 'TxtOutput', 'TxtStatus', 'BtnAbout', 'BtnHelp', 'BtnTheme') + $script:MachineControls) {
        $ui[$n] = $w.FindName($n)
    }
    $script:UI = $ui

    $ui.LstMachines.Add_SelectionChanged({ if (-not $script:Refreshing) { Update-Details } })
    $ui.LstMachines.Add_MouseDoubleClick({ Invoke-Safely { $m = Get-SelectedMachine; if ($m -and (Open-Terminal $m)) { Set-Status "Opened a terminal to $($m.Name)." 'Ok' } } })
    $ui.BtnAdd.Add_Click({ Invoke-Safely { Add-Machine } })
    $ui.BtnEdit.Add_Click({ Invoke-Safely { Edit-Machine } })
    $ui.BtnRemove.Add_Click({ Invoke-Safely { Remove-Machine } })
    $ui.BtnCheck.Add_Click({ Invoke-Safely { Start-ReachCheck } })

    $ui.BtnTerminal.Add_Click({ Invoke-Safely { $m = Get-SelectedMachine; if ($m -and (Open-Terminal $m)) { Set-Status "Opened a terminal to $($m.Name)." 'Ok' } } })
    $ui.BtnKey.Add_Click({ Invoke-Safely { Show-KeyHelper } })
    $ui.BtnDisk.Add_Click({ Invoke-Safely { Invoke-RemoteCommand -Title 'Disk space' -Command 'df -h -x tmpfs -x devtmpfs 2>/dev/null || df -h' } })
    $ui.BtnUptime.Add_Click({ Invoke-Safely { Invoke-RemoteCommand -Title 'Uptime' -Command 'uptime' } })
    $ui.BtnPs.Add_Click({ Invoke-Safely { Invoke-RemoteCommand -Title 'Docker ps' -Command "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'" } })
    $ui.BtnRestart.Add_Click({ Invoke-Safely { Restart-SelectedMachine } })
    $ui.BtnPull.Add_Click({ Invoke-Safely { Invoke-Compose pull } })
    $ui.BtnUp.Add_Click({ Invoke-Safely { Invoke-Compose up } })
    $ui.BtnDown.Add_Click({ Invoke-Safely { Invoke-Compose down } })
    $ui.BtnSend.Add_Click({ Invoke-Safely { Send-Files } })
    $ui.BtnGet.Add_Click({ Invoke-Safely { Receive-File } })
    $ui.BtnRun.Add_Click({ Invoke-Safely { Invoke-TypedCommand } })
    $ui.TxtCommand.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Invoke-Safely { Invoke-TypedCommand } } })
    $ui.BtnStop.Add_Click({ Stop-Remote })
    $ui.BtnClear.Add_Click({ $script:UI.TxtOutput.Clear() })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $script:Window })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $w.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'F1') { $e.Handled = $true; Show-Help } })
    $ui.BtnTheme.Content = "Theme: $($script:ThemeNames[$script:Theme])"
    $ui.BtnTheme.Add_Click({ Invoke-Safely { Switch-Theme } })
    # Following Windows: pick up a change of Windows' app mode when the window is next used.
    $w.Add_Activated({ if ($script:Theme -eq 'System' -and $script:IsDark -eq (Test-WindowsLightMode)) { Invoke-Safely { Set-Theme 'System' } } })

    $script:JobTimer = New-Object Windows.Threading.DispatcherTimer
    $script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:JobTimer.Add_Tick({ try { Update-Remote } catch { Write-AppLog "Output reader: $($_.Exception.Message)" } })

    $script:ReachTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ReachTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:ReachTimer.Add_Tick({
        try { Update-ReachCheck }
        catch { Write-AppLog "Reach check: $($_.Exception.Message)"; $script:ReachTimer.Stop(); $script:Checks = @(); $script:UI.BtnCheck.IsEnabled = $true }
    })

    $script:MinuteTimer = New-Object Windows.Threading.DispatcherTimer
    $script:MinuteTimer.Interval = [TimeSpan]::FromSeconds(60)
    $script:MinuteTimer.Add_Tick({ try { Start-ReachCheck } catch { Write-AppLog "Reach check: $($_.Exception.Message)" } })

    $w.Add_ContentRendered({
        Start-ReachCheck
        $script:MinuteTimer.Start()
        if ($script:SettingsProblem) { [void](Show-AppMessage -Kind Warn -Text $script:SettingsProblem) }
        elseif (-not (Find-OpenSsh 'ssh.exe')) { [void](Show-AppMessage -Kind Warn -Text "ssh.exe $script:NoOpenSsh") }
    })
    $w.Add_Closing({
        param($s, $e)
        if ($script:Job) {
            $stop = Show-AppMessage -Kind Question -Text "'$($script:Job.Title)' is still running on $($script:Job.Machine.Name). Stop it and close?" -YesText 'Stop and close' -NoText 'Keep running'
            if (-not $stop) { $e.Cancel = $true; return }
            Stop-Remote
        }
        $script:MinuteTimer.Stop(); $script:ReachTimer.Stop(); $script:JobTimer.Stop()
    })
    return $w
}

try {
    $script:AppIcon = Get-AppIcon
    Read-Settings
    $window = Initialize-MainWindow
    Update-MachineList
    Set-Status 'Pick a machine. Double-click one to open a terminal to it.'
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    $text = "$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath"
    try { [void](Show-AppMessage -Kind Error -Text $text -Owner $null) }
    catch { [void][Windows.MessageBox]::Show($text, $script:AppName, 'OK', 'Error') }   # last resort, only if WPF windows can't load at all
    exit 1
}
