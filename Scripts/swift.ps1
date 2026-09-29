# Runs a Swift command inside the Visual Studio developer environment.
#
# WHY THIS EXISTS
# ---------------
# The Swift toolchain for Windows reuses the MSVC headers and the Windows SDK
# (ucrt, um, shared) for its C shims. If INCLUDE and LIB are not populated, the
# very first module build fails with:
#
#     error: 'stdlib.h' file not found
#     error: could not build C module 'SwiftShims'
#
# Those variables are normally set by the "Developer Command Prompt for Visual
# Studio", which a normal PowerShell window does not have. This script imports
# that environment so `swift build` / `swift test` just work in any terminal.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File Scripts/swift.ps1 build
#   powershell -ExecutionPolicy Bypass -File Scripts/swift.ps1 test
#   powershell -ExecutionPolicy Bypass -File Scripts/swift.ps1 test --filter SHA256
#
# Once the environment is imported you can also call it inline:
#   . Scripts\Enter-VsDevShell.ps1
#   swift build

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArguments = @('build')
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# --- Locate the Visual Studio developer shell ---------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstall = $null
if (Test-Path $vswhere) {
    $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsInstall) {
    $vsInstall = & $vswhere -latest -products * -property installationPath 2>$null
}

$launcher = $null
if ($vsInstall) {
    $candidate = Join-Path $vsInstall 'Common7\Tools\Launch-VsDevShell.ps1'
    if (Test-Path $candidate) { $launcher = $candidate }
}

if (-not $launcher) {
    Write-Error @"
Could not locate Launch-VsDevShell.ps1.

Install the "Desktop development with C++" workload for Visual Studio 2022, or
run this script from a "Developer Command Prompt" instead.
"@
    exit 1
}

# --- Import the environment ---------------------------------------------------
# -SkipAutomaticLocation avoids VS trying to auto-detect (and prompt for) a
# workspace solution, which is slow and unnecessary for a pure Swift build.
& $launcher -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null

if (-not $env:INCLUDE) {
    Write-Error "Failed to populate INCLUDE. The Visual Studio C++ workload may be incomplete."
    exit 1
}

Write-Host "Visual Studio environment loaded: $vsInstall"
Write-Host "INCLUDE entries: $((($env:INCLUDE -split ';') | Where-Object { $_ }).Count)"
Write-Host ""

# --- Run Swift ----------------------------------------------------------------
Push-Location $repoRoot
try {
    & swift @SwiftArguments
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
