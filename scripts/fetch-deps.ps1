#Requires -Version 7.0
<#
.SYNOPSIS
  Fetches the pinned build dependencies into tools\ (gitignored): Lua from the UE4SS sources
  (LuaRaw), Prism, MinHook, miniaudio, the Steam Audio SDK, the UE4SS 3.0.1 release and the
  license texts the package ships. Whatever is there already is kept.

.DESCRIPTION
  Git sources are fetched at a fixed commit (only that commit, without history; UE4SS only its
  deps\first\LuaRaw folder). Downloads are checked against their SHA-256. The CI caches tools\
  keyed on this file, so changing a pin here fetches it again.

.PARAMETER Tools
  The folder to fill instead of tools\ (as OP1_TOOLS for build-shim.cmd).
#>
param([string]$Tools = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $true

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Tools) { $Tools = Join-Path $root 'tools' }
$Tools = [System.IO.Path]::GetFullPath($Tools, (Get-Location).Path)
New-Item -ItemType Directory -Force -Path $Tools | Out-Null

# Lua must be UE4SS's own (LuaRaw, with its lua_lock): the shim runs on UE4SS's Lua state.
$UE4SSSourceCommit = '265115c05bfcc75f96d8a1f4beda105a7d2753b1'
# Also PRISM_REF in build-shim.cmd.
$PrismCommit = 'a5fec84e3409cc466a98dfef77b1ea1eeb18aaa8'
$MinHookCommit = '05c06c5bbca226b72ffb40fc0caaef33bcaf6f74'
$MiniaudioTag = '0.11.25'
$MiniaudioSha256 = 'ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89'
$SteamAudioVersion = '4.8.1'
$SteamAudioSha256 = '4a0aa5ec1176f38f0b0993a37c2259d9e86f27e22d5e24f83ec4c3cb9a1d5449'
$UE4SSVersion = '3.0.1'
$UE4SSSha256 = '4b47d4bceddd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec'

function Get-GitCommit([string]$Url, [string]$Commit, [string]$Dir, [string[]]$Sparse = @()) {
    Write-Host "Fetching $Url at $Commit"
    if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
    git init -q $Dir
    git -C $Dir remote add origin $Url
    if ($Sparse.Count -gt 0) {
        git -C $Dir sparse-checkout set --no-cone @Sparse
        git -C $Dir fetch -q --depth 1 --filter=blob:none origin $Commit
    }
    else {
        git -C $Dir fetch -q --depth 1 origin $Commit
    }
    git -C $Dir -c advice.detachedHead=false checkout -q FETCH_HEAD
}

function Get-Download([string]$Url, [string]$File, [string]$Sha256) {
    Write-Host "Downloading $Url"
    New-Item -ItemType Directory -Force -Path (Split-Path $File) | Out-Null
    $partial = "$File.part"
    Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    $actual = (Get-FileHash $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Sha256 -and $actual -ne $Sha256) {
        Remove-Item -Force $partial
        throw "$Url has SHA-256 $actual, expected $Sha256"
    }
    Move-Item -Force $partial $File
}

$lua = Join-Path $Tools 'ue4ss-src'
if (-not (Test-Path (Join-Path $lua 'deps\first\LuaRaw\src\lapi.c'))) {
    Get-GitCommit 'https://github.com/UE4SS-RE/RE-UE4SS' $UE4SSSourceCommit $lua @('/deps/first/LuaRaw/')
}

$prism = Join-Path $Tools 'prism-src'
if (-not (Test-Path (Join-Path $prism 'include\prism.h'))) {
    Get-GitCommit 'https://github.com/ethindp/prism' $PrismCommit $prism
}

$minhook = Join-Path $Tools 'minhook'
if (-not (Test-Path (Join-Path $minhook 'src\hook.c'))) {
    Get-GitCommit 'https://github.com/TsudaKageyu/minhook' $MinHookCommit $minhook
}

$miniaudio = Join-Path $Tools 'miniaudio\miniaudio.h'
if (-not (Test-Path $miniaudio)) {
    Get-Download "https://raw.githubusercontent.com/mackron/miniaudio/$MiniaudioTag/miniaudio.h" $miniaudio $MiniaudioSha256
}

# Steam Audio: only the headers and the Windows x64 libraries from the SDK (181 MB).
$steamaudio = Join-Path $Tools 'steamaudio'
if (-not (Test-Path (Join-Path $steamaudio 'lib\windows-x64\phonon.dll'))) {
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) "steamaudio_$SteamAudioVersion.zip"
    Get-Download "https://github.com/ValveSoftware/steam-audio/releases/download/v$SteamAudioVersion/steamaudio_$SteamAudioVersion.zip" $zip $SteamAudioSha256
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $match = [regex]::Match($name, '^(?:[^/]+/)?(include/.+|lib/windows-x64/.+)$')
            if (-not $match.Success -or $name.EndsWith('/')) { continue }
            $target = Join-Path $steamaudio ($match.Groups[1].Value.Replace('/', '\'))
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
    finally {
        $archive.Dispose()
    }
    Remove-Item -Force $zip
    if (-not (Test-Path (Join-Path $steamaudio 'lib\windows-x64\phonon.lib'))) { throw "The Steam Audio SDK has no lib\windows-x64\phonon.lib" }
}

$ue4ss = Join-Path $Tools "UE4SS_v$UE4SSVersion.zip"
if (-not (Test-Path $ue4ss)) {
    Get-Download "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v$UE4SSVersion/UE4SS_v$UE4SSVersion.zip" $ue4ss $UE4SSSha256
}

# License texts the package ships, from the pinned sources.
$licenses = Join-Path $Tools 'licenses'
$licenseSources = [ordered]@{
    'LICENSE-UE4SS.txt'      = "https://raw.githubusercontent.com/UE4SS-RE/RE-UE4SS/v$UE4SSVersion/LICENSE"
    'LICENSE-SteamAudio.txt' = "https://raw.githubusercontent.com/ValveSoftware/steam-audio/v$SteamAudioVersion/LICENSE.md"
}
foreach ($name in $licenseSources.Keys) {
    $target = Join-Path $licenses $name
    if (-not (Test-Path $target)) { Get-Download $licenseSources[$name] $target '' }
}

Write-Host "Dependencies are in $Tools"
