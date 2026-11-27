<#
.SYNOPSIS
  Builds Respool for Windows, installs it for the current user and starts it.

.DESCRIPTION
  Installs to %LOCALAPPDATA%\Programs\Respool, adds Respool to the Start menu and to
  Settings > Apps (so it can be removed there), and starts it. Nothing needs administrator
  rights; nothing outside the current user's profile is touched.

.PARAMETER StartAtLogin
  Also start Respool when you sign in to Windows.

.PARAMETER NoStartAtLogin
  Stop starting Respool when you sign in.

.PARAMETER Uninstall
  Remove Respool, its shortcuts and its Settings > Apps entry. The Claude Code transcripts it
  reads are not touched.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\install.ps1 -StartAtLogin
#>
[CmdletBinding()]
param(
    [switch]$StartAtLogin,
    [switch]$NoStartAtLogin,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$InstallDir   = Join-Path $env:LOCALAPPDATA 'Programs\Respool'
$Exe          = Join-Path $InstallDir 'Respool.exe'
$StartMenu    = Join-Path ([Environment]::GetFolderPath('Programs')) 'Respool.lnk'
$StartupLink  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Respool.lnk'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Respool'
$Project      = Join-Path $PSScriptRoot 'Respool.Windows'

function Stop-Respool {
    Get-Process -Name 'Respool' -ErrorAction SilentlyContinue | ForEach-Object {
        $_.CloseMainWindow() | Out-Null
        if (-not $_.WaitForExit(2000)) { $_.Kill(); $_.WaitForExit(5000) | Out-Null }
    }
}

# Windows lets go of a closed program's files a moment after it exits, so this tries a few times.
function Remove-Folder([string]$Path) {
    for ($try = 1; $try -le 10 -and (Test-Path $Path); $try++) {
        try { Remove-Item $Path -Recurse -Force -ErrorAction Stop }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (Test-Path $Path) { throw "$Path could not be removed; close Respool and run this again." }
}

function New-Shortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Exe
    $link.WorkingDirectory = $InstallDir
    $link.IconLocation = "$Exe,0"
    $link.Description = 'Your Claude Code chats, at the edge of the screen'
    $link.Save()
}

if ($Uninstall) {
    Stop-Respool
    foreach ($path in @($StartMenu, $StartupLink)) {
        if (Test-Path $path) { Remove-Item $path -Force }
    }
    if (Test-Path $UninstallKey) { Remove-Item $UninstallKey -Recurse -Force }
    Remove-Folder $InstallDir
    Write-Host 'Respool is removed.'
    return
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK (8 or later) is needed to build Respool: https://dotnet.microsoft.com/download'
}

# Build to a folder of its own first, so a failed build leaves the installed copy as it was.
$Staging = Join-Path $PSScriptRoot '..\build\windows-install'
if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
& dotnet publish $Project -c Release -r win-x64 --self-contained false -o $Staging -nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "The build failed (dotnet publish exited with $LASTEXITCODE)." }

Stop-Respool
Remove-Folder $InstallDir
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $Staging '*') $InstallDir -Recurse -Force
Remove-Item $Staging -Recurse -Force

New-Shortcut $StartMenu
if ($StartAtLogin) { New-Shortcut $StartupLink }
if ($NoStartAtLogin -and (Test-Path $StartupLink)) { Remove-Item $StartupLink -Force }

# Settings > Apps lists it and its Uninstall button runs this script's -Uninstall, from a copy
# kept beside the app so it works after the repository is moved.
Copy-Item $PSCommandPath (Join-Path $InstallDir 'install.ps1') -Force
$version = ((Get-Item $Exe).VersionInfo.ProductVersion -split '\+')[0]
New-Item -Path $UninstallKey -Force | Out-Null
$values = @{
    DisplayName     = 'Respool'
    DisplayIcon     = "$Exe,0"
    DisplayVersion  = "$version"
    Publisher       = 'Respool'
    InstallLocation = $InstallDir
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\install.ps1`" -Uninstall"
}
foreach ($name in $values.Keys) { Set-ItemProperty -Path $UninstallKey -Name $name -Value $values[$name] }
Set-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -Type DWord

Start-Process $Exe
Write-Host "Respool is installed in $InstallDir and running."
if (Test-Path $StartupLink) { Write-Host 'It starts when you sign in.' }
