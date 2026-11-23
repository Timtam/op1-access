#Requires -Version 7.0
<#
.SYNOPSIS
  Builds a release the way the CI does: fetches the pinned dependencies, builds the shim (without
  deploying it into a game) and the installer, and packs everything into dist\.

.PARAMETER RepositorySlug
  The GitHub repository ("owner/name") the mod and the installer check for updates. The CI passes
  its own repository; without it, the builds have no update source.

.PARAMETER Tools
  The dependency folder (default: tools\, or OP1_TOOLS when set).
#>
param(
    [string]$RepositorySlug = $env:GITHUB_REPOSITORY,
    [string]$Configuration = 'Release',
    [string]$Tools = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $RepositorySlug) { $RepositorySlug = '' }
if (-not $Tools) { $Tools = if ($env:OP1_TOOLS) { $env:OP1_TOOLS } else { Join-Path $root 'tools' } }
$Tools = [System.IO.Path]::GetFullPath($Tools, (Get-Location).Path)

& (Join-Path $PSScriptRoot 'fetch-deps.ps1') -Tools $Tools

$env:OP1_TOOLS = $Tools
& cmd /c "`"$(Join-Path $PSScriptRoot 'build-shim.cmd')`" --no-deploy"
if ($LASTEXITCODE -ne 0) { throw 'Building the shim failed' }

# The installer gets the Static Forms key for problem reports from OP1_STATICFORMS_KEY (the release
# workflow sets it from the repository secret STATICFORMS_KEY); without it, reports are off.
dotnet build (Join-Path $root 'installer\OP1AccessInstaller\OP1AccessInstaller.csproj') -c $Configuration -nologo "-p:RepositorySlug=$RepositorySlug"
if ($LASTEXITCODE -ne 0) { throw 'Building the installer failed' }

# The installer's tests: the ALTCHA solver, the Static Forms client against a local stand-in,
# cleaning and packing of the report's attachments.
dotnet build (Join-Path $root 'installer\OP1AccessInstaller.Tests\OP1AccessInstaller.Tests.csproj') -c $Configuration -nologo "-p:RepositorySlug=$RepositorySlug"
if ($LASTEXITCODE -ne 0) { throw 'Building the installer tests failed' }
& (Join-Path $root "installer\OP1AccessInstaller.Tests\bin\$Configuration\net48\OP1AccessInstaller.Tests.exe")
if ($LASTEXITCODE -ne 0) { throw 'The installer tests failed' }

& (Join-Path $PSScriptRoot 'package.ps1') -Configuration $Configuration -RepositorySlug $RepositorySlug -Tools $Tools
