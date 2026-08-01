<#
.SYNOPSIS
    Asserts that `tools/release.ps1 -DryRun` previews exactly three version
    rewrites at one version and writes nothing.

.DESCRIPTION
    The automated half of the phase's "one command, one version" criterion.
    It runs the release script in dry-run mode against a probe version and
    checks five things:

        (a) the dry run exits 0
        (b) it prints exactly three `BUMP ` lines
        (c) they name the three version-bearing files
        (d) every rewrite targets the SAME probe version
        (e) `git status --porcelain` is byte-identical before and after,
            proving the dry run is genuinely side-effect-free

    Prints OK and exits 0 on success; prints the failing assertion and exits 1
    otherwise. Safe to run on a dirty tree -- criterion (e) compares the tree
    against itself, not against clean.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-release-dryrun.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Release  = Join-Path $PSScriptRoot 'release.ps1'

# Deliberately far above anything that could ever be published, so the
# harness is not invalidated by the mirror's latest moving forward.
$Probe = '9.9.9'

$ExpectedPaths = @(
    'server/server-windows/Cargo.toml',
    'app/remote_control/pubspec.yaml',
    'extension/manifest.json'
)

# Same PS 5.1 stderr/NativeCommandError workaround release.ps1 uses.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Assert-Failed {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Release)) { Assert-Failed "tools/release.ps1 not found at $Release" }

# Run the dry run through the SAME host this harness is running under.
$PSExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path $PSExe)) { $PSExe = Join-Path $PSHOME 'pwsh.exe' }
if (-not (Test-Path $PSExe)) { Assert-Failed "no PowerShell host executable found under $PSHOME" }

$statusBefore = (Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'status', '--porcelain') |
                 ForEach-Object { [string]$_ }) -join "`n"

$output = Invoke-Native -Exe $PSExe -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Release, '-Version', $Probe, '-DryRun'
)
$exit = $LASTEXITCODE
$lines = @($output | ForEach-Object { [string]$_ })
$transcript = $lines -join "`n"

$statusAfter = (Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'status', '--porcelain') |
                ForEach-Object { [string]$_ }) -join "`n"

# (a) the dry run succeeds
if ($exit -ne 0) {
    Assert-Failed "(a) release.ps1 -Version $Probe -DryRun exited $exit, expected 0.`n--- transcript ---`n$transcript"
}

# (b) exactly three BUMP lines
$bumps = @($lines | Where-Object { $_ -like 'BUMP *' })
if ($bumps.Count -ne 3) {
    Assert-Failed "(b) expected exactly 3 'BUMP ' lines, found $($bumps.Count).`n--- transcript ---`n$transcript"
}

# (c) they name the three version-bearing files, in any order
$paths = @($bumps | ForEach-Object { ($_ -split '\s+')[1] })
foreach ($expected in $ExpectedPaths) {
    if ($paths -notcontains $expected) {
        Assert-Failed "(c) no BUMP line for $expected. Reported: $($paths -join ', ')"
    }
}
foreach ($reported in $paths) {
    if ($ExpectedPaths -notcontains $reported) {
        Assert-Failed "(c) unexpected BUMP target $reported."
    }
}

# (d) every rewrite lands on the SAME version
foreach ($bump in $bumps) {
    $arrow = $bump.IndexOf(' -> ')
    if ($arrow -lt 0) { Assert-Failed "(d) malformed BUMP line, no ' -> ': $bump" }
    $newValue = $bump.Substring($arrow + 4)
    if (-not $newValue.Contains($Probe)) {
        Assert-Failed "(d) BUMP target '$newValue' is not at $Probe : $bump"
    }
}

# (e) the dry run touched nothing
if ($statusAfter -ne $statusBefore) {
    Assert-Failed @"
(e) the dry run changed the working tree.
--- before ---
$statusBefore
--- after ---
$statusAfter
"@
}

Write-Host 'OK' -ForegroundColor Green
exit 0
