<#
.SYNOPSIS
    Builds the Remote Control Windows server and packages it as a setup .exe.

.DESCRIPTION
    One command from a clean checkout to a shippable installer:

        cargo build --release -p server-windows
        ISCC /DMyAppVersion=<ver> installer\RemoteControl.iss
        -> dist\RemoteControl-Setup-v<ver>.exe

    The version comes from server/server-windows/Cargo.toml, which is the
    single source of truth for the server's version -- the same value
    winresource embeds into the exe's VERSIONINFO at build time. Pass
    -Version to override it for a one-off build.

.PARAMETER Version
    Overrides the version read from Cargo.toml. Any pre-release suffix
    (e.g. 1.3.0-rc1) is kept in the product version and filename, and
    stripped for the numeric VersionInfoVersion field Inno requires.

.PARAMETER SkipBuild
    Package whatever is already in server/target/release. Useful when
    iterating on the .iss alone.

.EXAMPLE
    .\installer\build-installer.ps1

.EXAMPLE
    .\installer\build-installer.ps1 -Version 1.3.0-rc2 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 turns ANY stderr output from a native exe into a
# terminating NativeCommandError while ErrorActionPreference is 'Stop' -- and
# cargo writes its ordinary progress lines to stderr. Native calls are wrapped
# in this helper so exit codes, not stream routing, decide success.
#
# Nothing is returned on purpose: the command's own output must flow to the
# host, and anything this function emitted would be indistinguishable from it.
# Callers read the global $LASTEXITCODE afterwards.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    } finally {
        $ErrorActionPreference = $previous
    }
}

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ServerDir  = Join-Path $RepoRoot 'server'
$CargoToml  = Join-Path $ServerDir 'server-windows\Cargo.toml'
$IssPath    = Join-Path $PSScriptRoot 'RemoteControl.iss'
$DistDir    = Join-Path $RepoRoot 'dist'

# ---- Version -----------------------------------------------------------

if (-not $Version) {
    if (-not (Test-Path $CargoToml)) {
        throw "Cannot read the version: $CargoToml not found."
    }
    # First `version = "..."` line, which is the [package] one -- dependency
    # versions further down the file are all inside inline tables.
    $match = Select-String -Path $CargoToml -Pattern '^\s*version\s*=\s*"([^"]+)"' |
             Select-Object -First 1
    if (-not $match) {
        throw "No package version field found in $CargoToml. Pass -Version explicitly."
    }
    $Version = $match.Matches[0].Groups[1].Value
}

# Inno's VersionInfoVersion field must be strictly numeric.
$VersionInfo = ($Version -split '-')[0]
if ($VersionInfo -notmatch '^\d+(\.\d+){0,3}$') {
    throw "Version '$Version' does not start with a numeric x.y.z -- Inno cannot use it for VersionInfoVersion."
}

Write-Host "Remote Control installer" -ForegroundColor Cyan
Write-Host "  version : $Version (VersionInfoVersion $VersionInfo)"

# ---- Locate ISCC -------------------------------------------------------

$IsccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$Iscc = $IsccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $Iscc) {
    $onPath = Get-Command iscc -ErrorAction SilentlyContinue
    if ($onPath) { $Iscc = $onPath.Source }
}
if (-not $Iscc) {
    throw @"
Inno Setup 6 is required to build the installer, and ISCC.exe was not found.

Looked in:
$($IsccCandidates -join "`n")
...and on PATH.

Install it with either:
  winget install --id JRSoftware.InnoSetup -e -s winget
or download it from https://jrsoftware.org/isdl.php (per-user install works;
no admin rights needed).
"@
}
Write-Host "  ISCC    : $Iscc"

# ---- Build the server --------------------------------------------------

if ($SkipBuild) {
    Write-Host "  build   : skipped (-SkipBuild)" -ForegroundColor Yellow
} else {
    Write-Host "`nBuilding server-windows (release)..." -ForegroundColor Cyan
    Push-Location $ServerDir
    try {
        Invoke-Native -Exe 'cargo' -Arguments @('build', '--release', '-p', 'server-windows')
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

$ServerExe = Join-Path $ServerDir 'target\release\server-windows.exe'
if (-not (Test-Path $ServerExe)) {
    throw "Expected $ServerExe to exist. Run without -SkipBuild."
}

# ---- Compile the installer --------------------------------------------

Write-Host "`nCompiling installer..." -ForegroundColor Cyan
Invoke-Native -Exe $Iscc -Arguments @("/DMyAppVersion=$Version", "/DMyVersionInfo=$VersionInfo", $IssPath)
if ($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit code $LASTEXITCODE (its error is in the output above)."
}

$Setup = Join-Path $DistDir "RemoteControl-Setup-v$Version.exe"
if (-not (Test-Path $Setup)) {
    throw "ISCC reported success but $Setup is missing."
}

$SizeMB = [math]::Round((Get-Item $Setup).Length / 1MB, 2)
Write-Host "`nDone." -ForegroundColor Green
Write-Host "  $Setup"
Write-Host "  $SizeMB MB"
