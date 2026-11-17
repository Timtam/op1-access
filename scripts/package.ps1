#Requires -Version 7.0
<#
.SYNOPSIS
  Packs a release into dist\: OP1Access-<version>.zip, OP1AccessInstaller.exe and SHA256SUMS.txt.

.DESCRIPTION
  The ZIP mirrors the game folder (the one with Octopath_Traveler.exe): extracted there, it is a
  complete installation. Everything goes to Octopath_Traveler\Binaries\Win64:
  - UE4SS 4.0.0 as released: its proxy dwmapi.dll there, the rest in ue4ss\ (UE4SS.dll, its
    settings, its mods), with GuiConsoleEnabled = 0 in ue4ss\UE4SS-settings.ini, and in
    ue4ss\Mods\mods.txt UE4SS's own mods off (consoles, cheat manager, BP mod loader, key
    binds: nothing the mod needs, and less running in the game) and "OP1Access : 1",
  - phonon.dll (Steam Audio) next to the game EXE, where the shim's dependency resolves,
  - ue4ss\Mods\OP1Access: the Lua mod, the shim, buildinfo.lua (version, update source, UE4SS
    version), the sounds, the installer, a README and the licenses.
  The installer installs from the same ZIP. Run scripts\build-release.ps1 first (or build the shim
  with build-shim.cmd --no-deploy and the installer yourself).
#>
param(
    [string]$Configuration = 'Release',
    [string]$RepositorySlug = '',
    [string]$Tools = '',
    [string]$Output = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Tools) { $Tools = if ($env:OP1_TOOLS) { $env:OP1_TOOLS } else { Join-Path $root 'tools' } }
if (-not $Output) { $Output = Join-Path $root 'dist' }
# Relative paths are meant from the current PowerShell location, not .NET's current directory.
$Tools = [System.IO.Path]::GetFullPath($Tools, (Get-Location).Path)
$Output = [System.IO.Path]::GetFullPath($Output, (Get-Location).Path)
$utf8 = [System.Text.UTF8Encoding]::new($false)

$propsText = [System.IO.File]::ReadAllText((Join-Path $root 'Directory.Build.props'))
$versionMatch = [regex]::Match($propsText, '<ModVersion>\s*([^<\s]+)\s*</ModVersion>')
if (-not $versionMatch.Success) { throw 'No <ModVersion> in Directory.Build.props' }
$version = $versionMatch.Groups[1].Value
$ue4ssVersion = '4.0.0'

$shim = Join-Path $root 'build\shim\OP1AccessShim.dll'
$installer = Join-Path $root "installer\OP1AccessInstaller\bin\$Configuration\net48\OP1AccessInstaller.exe"
$ue4ssZip = Join-Path $Tools "UE4SS_v$ue4ssVersion.zip"
$phonon = Join-Path $Tools 'steamaudio\lib\windows-x64\phonon.dll'
$prism = Join-Path $Tools 'prism-src'
$required = @($shim, $installer, $ue4ssZip, $phonon, (Join-Path $prism 'LICENSE'),
    (Join-Path $Tools 'licenses\LICENSE-UE4SS.txt'), (Join-Path $Tools 'licenses\LICENSE-SteamAudio.txt'))
foreach ($file in $required) {
    if (-not (Test-Path $file)) { throw "Missing $file. Run scripts\build-release.ps1 first." }
}

$builtVersion = (Get-Item $installer).VersionInfo.ProductVersion
if ($builtVersion -ne $version) {
    throw "OP1AccessInstaller.exe has version $builtVersion, Directory.Build.props says $version. Build again."
}

# The game is a 64-bit process; a 32-bit shim would not load.
$peBytes = [System.IO.File]::ReadAllBytes($shim)
$peOffset = [BitConverter]::ToInt32($peBytes, 0x3C)
if ([BitConverter]::ToUInt16($peBytes, $peOffset + 4) -ne 0x8664) { throw "$shim is not a 64-bit DLL" }

$stage = Join-Path $Output 'package'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Get-ChildItem $Output -Filter 'OP1Access-*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force

$bin = Join-Path $stage 'Octopath_Traveler\Binaries\Win64'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# UE4SS as released (dwmapi.dll and the ue4ss folder), without a README or changelog.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ue4ssDir = Join-Path $Output 'ue4ss'
if (Test-Path $ue4ssDir) { Remove-Item -Recurse -Force $ue4ssDir }
[System.IO.Compression.ZipFile]::ExtractToDirectory($ue4ssZip, $ue4ssDir)
foreach ($item in Get-ChildItem $ue4ssDir) {
    if ($item.Name -in @('README.md', 'Changelog.md')) { continue }
    Copy-Item -LiteralPath $item.FullName -Destination $bin -Recurse
}
Remove-Item -Recurse -Force $ue4ssDir

# The GUI console crashed the game at start on some systems (and takes the focus).
$settings = Join-Path $bin 'ue4ss\UE4SS-settings.ini'
$text = [System.IO.File]::ReadAllText($settings)
$patched = [regex]::Replace($text, '(?m)^(\s*GuiConsoleEnabled\s*=\s*)\d+', '${1}0')
if ($patched -eq $text -and $text -notmatch '(?m)^\s*GuiConsoleEnabled\s*=\s*0') { throw 'GuiConsoleEnabled not found in UE4SS-settings.ini' }
[System.IO.File]::WriteAllText($settings, $patched, $utf8)

# mods.txt keeps its byte order mark; UE4SS's own mods are off; the mod's line goes last, after
# the built-in Keybinds.
$modsTxt = Join-Path $bin 'ue4ss\Mods\mods.txt'
$bytes = [System.IO.File]::ReadAllBytes($modsTxt)
$bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$modsText = $utf8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
$stockMods = 'CheatManagerEnablerMod|ConsoleCommandsMod|ConsoleEnablerMod|SplitScreenMod|LineTraceMod|BPML_GenericFunctions|BPModLoaderMod|Keybinds|ActorDumperMod|jsbLuaProfilerMod'
$modsText = [regex]::Replace($modsText, "(?m)^(\s*(?:$stockMods)\s*:\s*)1", '${1}0')
if ($modsText -notmatch '(?m)^\s*OP1Access\s*:') {
    $modsText = $modsText.TrimEnd() + "`r`nOP1Access : 1`r`n"
}
[System.IO.File]::WriteAllText($modsTxt, $modsText, [System.Text.UTF8Encoding]::new($bom))

Copy-Item -LiteralPath $phonon -Destination $bin

# The mod.
$mod = Join-Path $bin 'ue4ss\Mods\OP1Access'
$source = Join-Path $root 'scripts\Mods\OP1Access'
New-Item -ItemType Directory -Force -Path (Join-Path $mod 'Scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'enabled.txt') -Destination $mod
Copy-Item -LiteralPath (Join-Path $source 'Scripts\main.lua') -Destination (Join-Path $mod 'Scripts')
# the area links for the world map's route finder (scripts/level-links.py)
Copy-Item -LiteralPath (Join-Path $source 'Scripts\worldlinks.lua') -Destination (Join-Path $mod 'Scripts')
# the mod's own texts in other languages (scripts/i18n.py): Scripts\lang\<language>.po + the template
New-Item -ItemType Directory -Force -Path (Join-Path $mod 'Scripts\lang') | Out-Null
Copy-Item -Path (Join-Path $source 'Scripts\lang\*.po'), (Join-Path $source 'Scripts\lang\*.pot') -Destination (Join-Path $mod 'Scripts\lang')
Copy-Item -LiteralPath $shim -Destination (Join-Path $mod 'Scripts')
Copy-Item -LiteralPath (Join-Path $source 'Assets') -Destination (Join-Path $mod 'Assets') -Recurse
$buildInfo = @"
-- Written by scripts/package.ps1 for a release. Development copies have no such file and so
-- check for no updates.
return { version = "$version", repo = "$RepositorySlug", ue4ss = "$ue4ssVersion" }
"@
[System.IO.File]::WriteAllText((Join-Path $mod 'Scripts\buildinfo.lua'), $buildInfo.Replace("`r`n", "`n") + "`n", $utf8)
Copy-Item -LiteralPath $installer -Destination $mod

# Licenses.
$licenses = Join-Path $mod 'licenses'
New-Item -ItemType Directory -Force -Path (Join-Path $licenses 'prism') | Out-Null
Copy-Item -LiteralPath (Join-Path $prism 'LICENSE'), (Join-Path $prism 'NOTICE') -Destination (Join-Path $licenses 'prism')
Copy-Item -LiteralPath (Join-Path $prism 'LICENSES') -Destination (Join-Path $licenses 'prism\LICENSES') -Recurse
Copy-Item -LiteralPath (Join-Path $Tools 'licenses\LICENSE-UE4SS.txt'), (Join-Path $Tools 'licenses\LICENSE-SteamAudio.txt') -Destination $licenses
Copy-Item -LiteralPath (Join-Path $Tools 'minhook\LICENSE.txt') -Destination (Join-Path $licenses 'LICENSE-MinHook.txt')
Copy-Item -LiteralPath (Join-Path $Tools 'ue4ss-src\deps\first\LuaRaw\LICENSE') -Destination (Join-Path $licenses 'LICENSE-Lua.txt')
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $mod 'LICENSE.txt')

$projectUrl = if ($RepositorySlug) { "https://github.com/$RepositorySlug" } else { 'see the README of the source code' }
foreach ($template in 'README.txt', 'THIRD-PARTY-NOTICES.txt') {
    $text = [System.IO.File]::ReadAllText((Join-Path $root "packaging\$template"))
    $text = $text.Replace('{VERSION}', $version).Replace('{PROJECT_URL}', $projectUrl).Replace('{UE4SS_VERSION}', $ue4ssVersion)
    $text = $text -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $mod $template), $text, $utf8)
}

$zip = Join-Path $Output "OP1Access-$version.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -Recurse -Force $stage

$installerOut = Join-Path $Output 'OP1AccessInstaller.exe'
Copy-Item -LiteralPath $installer -Destination $installerOut -Force

$sums = foreach ($file in $zip, $installerOut) {
    '{0}  {1}' -f (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $file -Leaf)
}
[System.IO.File]::WriteAllText((Join-Path $Output 'SHA256SUMS.txt'), ($sums -join "`n") + "`n")

foreach ($file in $zip, $installerOut) {
    Write-Host ('{0} ({1:N0} KB)' -f $file, ((Get-Item $file).Length / 1KB))
}
