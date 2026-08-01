<#
.SYNOPSIS
    Cuts a Remote Control release: one version, three artifacts, one published tag.

.DESCRIPTION
    The single command that makes a release exist. In order it:

        1. Preflight  -- version format, clean tree, gh, release keystore,
                         and the public mirror's currently-published latest.
        2. Bump       -- rewrites the THREE version-bearing files to one X.Y.Z:
                         server/server-windows/Cargo.toml
                         app/remote_control/pubspec.yaml   (both halves)
                         extension/manifest.json
        3. Build      -- dist\RemoteControl-vX.Y.Z.apk
                         dist\RemoteControl-Setup-vX.Y.Z.exe
                         dist\RemoteControl-Extension-vX.Y.Z.zip
        4. Hash       -- prints the three sha256 values.
        5. Tag        -- tags the private source repo and pushes it.
        6. Publish    -- creates the mirror release carrying all three assets.

    Version identity is a build-time invariant enforced here ONCE, instead of
    three runtime constants that drift -- which is exactly the bug that pinned
    pubspec.yaml at 1.0.0+1 across four shipped releases.

    Release assets are published to a SEPARATE PUBLIC repo so that no auth
    token ever has to ship inside any artifact: clients read
    api.github.com/repos/nandodeomkar/remote-control-releases anonymously.
    This script authenticates only through the operator's own `gh` login,
    which never enters an artifact.

.PARAMETER Version
    The release version, strictly X.Y.Z. It must be strictly greater than the
    mirror's currently published latest. Pre-release suffixes are not accepted
    here -- see -PreRelease.

.PARAMETER PreRelease
    Marks the mirror release as a pre-release.

    A pre-release is published for the owner's own UAT and is DELIBERATELY
    INVISIBLE TO CLIENTS: the /releases/latest endpoint every client reads
    excludes pre-releases, and the client version parser rejects X.Y.Z-rcN
    tags outright. A pre-release is therefore never offered as an update.

.PARAMETER DryRun
    Report what would happen and write nothing. Every preflight still runs;
    the bump prints one `BUMP <path> <old> -> <new>` line per file, and the
    build/hash/tag/publish stages print their exact command lines prefixed
    with `DRYRUN `. Nothing is written, built, tagged or published.

    Environment-state refusals (dirty tree, unreachable mirror) degrade to a
    printed warning under -DryRun so the preview stays runnable mid-work; a
    real run still refuses. Argument refusals (bad version format, a version
    at or below the published latest) refuse in both modes.

.EXAMPLE
    .\tools\release.ps1 -Version 1.5.0 -DryRun

.EXAMPLE
    .\tools\release.ps1 -Version 1.5.0

.EXAMPLE
    .\tools\release.ps1 -Version 1.6.0 -PreRelease
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$PreRelease,
    [switch]$DryRun
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

# ---- Layout ------------------------------------------------------------
#
# tools/ is one level deep, exactly like installer/, so the same
# Split-Path -Parent $PSScriptRoot idiom yields the repo root.

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ServerDir   = Join-Path $RepoRoot 'server'
$AppDir      = Join-Path $RepoRoot 'app\remote_control'
$CargoToml   = Join-Path $ServerDir 'server-windows\Cargo.toml'
$PubSpec     = Join-Path $AppDir 'pubspec.yaml'
$ExtManifest = Join-Path $RepoRoot 'extension\manifest.json'
$ExtDir      = Join-Path $RepoRoot 'extension'
$DistDir     = Join-Path $RepoRoot 'dist'
$Installer   = Join-Path $RepoRoot 'installer\build-installer.ps1'
$KeyProps    = Join-Path $AppDir 'android\key.properties'

# ---- The public mirror -------------------------------------------------
#
# Release assets live in a SECOND, PUBLIC repo. The private repo keeps source
# and .planning/. Clients read the mirror anonymously, so no token ever has to
# be embedded in a shipped artifact.

$MirrorRepo  = 'nandodeomkar/remote-control-releases'
$RepoApi     = "https://api.github.com/repos/$MirrorRepo"
$ReleasesApi = "https://api.github.com/repos/$MirrorRepo/releases/latest"
$UserAgent   = 'RemoteControl-Release'

# GitHub speaks TLS 1.2+ only, and Windows PowerShell 5.1 still negotiates
# TLS 1.0 by default on some machines. Without this the probe below fails with
# an opaque "underlying connection was closed".
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---- Small helpers -----------------------------------------------------

function ConvertTo-VersionTriple {
    <# 'v1.4.0' / '1.4.0' -> @(1,4,0); $null when it does not start X.Y.Z. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t.StartsWith('v')) { $t = $t.Substring(1) }
    if ($t -notmatch '^(\d+)\.(\d+)\.(\d+)') { return $null }
    return ,@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

function Compare-VersionTriple {
    <# Integer-triple comparison. NEVER compare versions as strings: '1.10.0'
       sorts below '1.9.0' lexically, which would silently allow a downgrade. #>
    param([Parameter(Mandatory)][int[]]$A, [Parameter(Mandatory)][int[]]$B)

    for ($i = 0; $i -lt 3; $i++) {
        if ($A[$i] -gt $B[$i]) { return 1 }
        if ($A[$i] -lt $B[$i]) { return -1 }
    }
    return 0
}

function Invoke-GitHubProbe {
    <# Anonymous GET. No auth header and no credential, ever (D-01): this is
       the same anonymous read every installed client performs. #>
    param([Parameter(Mandatory)][string]$Uri)

    try {
        $data = Invoke-RestMethod -Uri $Uri -UserAgent $UserAgent -TimeoutSec 20 -ErrorAction Stop
        return @{ Ok = $true; Status = 200; Data = $data }
    } catch {
        $status = 0
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) { $status = [int]$response.StatusCode }
        return @{ Ok = $false; Status = $status; Message = $_.Exception.Message }
    }
}

function Deny-Or-Warn {
    <# Environment-state refusals. A real run throws; -DryRun prints the very
       same message and continues, so the bump preview stays runnable while
       work is still uncommitted. Argument refusals do not come through here --
       they throw unconditionally. #>
    param([Parameter(Mandatory)][string]$Message)

    if ($DryRun) {
        Write-Host "`nWOULD REFUSE (continuing because -DryRun):" -ForegroundColor Yellow
        Write-Host $Message -ForegroundColor Yellow
        return
    }
    throw $Message
}

Write-Host "Remote Control release" -ForegroundColor Cyan
Write-Host "  version : $Version"
Write-Host "  mirror  : $MirrorRepo"
if ($PreRelease) { Write-Host "  channel : pre-release (invisible to clients)" -ForegroundColor Yellow }
if ($DryRun)     { Write-Host "  mode    : DRY RUN -- nothing is written" -ForegroundColor Yellow }

# ---- Preflight 1: version format ---------------------------------------

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw @"
-Version '$Version' is not a plain X.Y.Z.

All three version fields carry the same literal string, and the client parser
rejects anything else, so a suffix or a two-part version cannot be released.
Pass something like -Version 1.5.0. For an owner-only UAT build, keep X.Y.Z
and add -PreRelease.
"@
}

# ---- Preflight 2: clean working tree ------------------------------------
#
# dist/ is gitignored (.gitignore line 9, `/dist/`), so this script's own
# build output can never trip this check on a later run.

$dirty = Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'status', '--porcelain')
if ($LASTEXITCODE -ne 0) {
    throw "git status failed with exit code $LASTEXITCODE in $RepoRoot."
}
if ($dirty) {
    Deny-Or-Warn @"
The working tree is not clean, so this release would not be reproducible from
its own tag. Uncommitted paths:

$($dirty -join "`n")

Commit or stash them, then re-run. (dist/ is gitignored and never appears here.)
"@
}

# ---- Preflight 3: locate gh --------------------------------------------
#
# gh is NOT on PATH on the owner's machine, so resolve it the same
# three-candidate way build-installer.ps1 resolves ISCC.exe. The absolute path
# is a FALLBACK, never the only candidate -- hardcoding it alone would break
# this script on every other machine.

$Gh = $null
$GhOnPath = Get-Command gh -ErrorAction SilentlyContinue
if ($GhOnPath) { $Gh = $GhOnPath.Source }
if (-not $Gh) {
    $GhFallback = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path $GhFallback) { $Gh = $GhFallback }
}
if (-not $Gh) {
    throw @"
The GitHub CLI is required to publish the release, and gh.exe was not found.

Looked on PATH, and at:
C:\Program Files\GitHub CLI\gh.exe

Install it with either:
  winget install --id GitHub.cli -e -s winget
or download it from https://cli.github.com/ , then run `gh auth login` once.
"@
}
Write-Host "  gh      : $Gh"

# ---- Preflight 4: release signing --------------------------------------
#
# Without key.properties `flutter build apk --release` still succeeds -- it
# just DEBUG-signs the APK. A debug-signed APK cannot upgrade a release-signed
# install: Android refuses it with STATUS_FAILURE_CONFLICT (signature
# mismatch), which would break every already-installed user. Refuse loudly
# instead of silently shipping one.

if (-not (Test-Path $KeyProps)) {
    throw @"
The Android release keystore config is missing:
  $KeyProps

Without it `flutter build apk --release` produces a DEBUG-signed APK, which
can never upgrade a release-signed install -- Android rejects it with
STATUS_FAILURE_CONFLICT. Copy android\key.properties.template to
android\key.properties and fill in the four fields (see DISTRIBUTION.md).
"@
}
Write-Host "  signing : $KeyProps"

# ---- Preflight 5: mirror reachable, and -Version beats its latest -------
#
# "Latest" is read from the mirror's releases API over TLS, NEVER from
# `git describe`: the local tag history is known-incomplete (the whole v1.3.x
# line was shipped untagged), so tag continuity cannot be assumed.
#
# Two probes, not one, because /releases/latest returns 404 for BOTH "repo
# does not exist" and "repo exists but has no releases yet" -- and the second
# of those is exactly the first-ever release, which must be allowed.

$MissingRepoMessage = @"
The public mirror repo does not exist yet:
  $MirrorRepo

Create it once, as PUBLIC (clients read it anonymously, with no token):
  gh repo create nandodeomkar/remote-control-releases --public

Nothing can be published until it exists.
"@

$repoProbe = Invoke-GitHubProbe -Uri $RepoApi
if (-not $repoProbe.Ok) {
    if ($repoProbe.Status -eq 404) {
        Deny-Or-Warn $MissingRepoMessage
    } else {
        Deny-Or-Warn @"
Could not reach the public mirror repo $MirrorRepo
  GET $RepoApi
  $($repoProbe.Message)

Check the network, then re-run. The published latest cannot be confirmed
without it, and publishing over an unknown latest risks a downgrade.
"@
    }
} else {
    $latestProbe = Invoke-GitHubProbe -Uri $ReleasesApi
    if ($latestProbe.Ok) {
        $publishedTag = [string]$latestProbe.Data.tag_name
        $publishedTriple = ConvertTo-VersionTriple -Text $publishedTag
        if (-not $publishedTriple) {
            Deny-Or-Warn "The mirror's published latest tag '$publishedTag' is not an X.Y.Z tag; refusing to guess whether $Version is newer."
        } else {
            $requested = ConvertTo-VersionTriple -Text $Version
            if ((Compare-VersionTriple -A $requested -B $publishedTriple) -le 0) {
                # Argument refusal: throws even under -DryRun.
                throw @"
-Version $Version is at or below the mirror's published latest ($publishedTag).

Clients only ever move forward, so a release at or below the published latest
would be invisible at best and a downgrade at worst. Pick a strictly greater
X.Y.Z.
"@
            }
            Write-Host "  latest  : $publishedTag published -> $Version is newer"
        }
    } elseif ($latestProbe.Status -eq 404) {
        Write-Host "  latest  : the mirror has no releases yet -- $Version is the first" -ForegroundColor Yellow
    } else {
        Deny-Or-Warn @"
$MirrorRepo exists but its latest release could not be read.
  GET $ReleasesApi
  $($latestProbe.Message)

Check the network, then re-run.
"@
    }
}

Write-Host "`nPreflight OK." -ForegroundColor Green

# ---- Version bump ------------------------------------------------------
#
# ANCHORED SINGLE-LINE REGEX REPLACEMENT ONLY. Never parse-and-reserialise:
# both pubspec.yaml and Cargo.toml carry load-bearing comments (the 8-line
# block explaining why the build number must increase, the note naming
# Cargo.toml as the single source of the server version) that any YAML/TOML
# round trip would silently delete. There is deliberately no YAML, TOML or
# JSON serializer anywhere in this script.

function Get-LineSpans {
    <# One Match per line, terminator excluded, so the caller can splice a line
       in place without touching any line ending. The three version files do
       not agree on CRLF vs LF, so joining them back together with one chosen
       separator would rewrite the whole file. #>
    param([Parameter(Mandatory)][string]$Text)

    return [regex]::Matches($Text, '^[^\r\n]*', [System.Text.RegularExpressions.RegexOptions]::Multiline)
}

function Set-VersionField {
    <#
        Rewrites the version value(s) inside the FIRST line matching $Pattern.

        $Rewrite receives the line's regex Match and returns:
            @{ Groups = @{ <group number> = <new text> ; ... }
               Old    = <old value, for the BUMP line>
               New    = <new value, for the BUMP line> }

        Only the named capture groups are spliced, so indentation, quoting,
        trailing commas and spacing all survive byte for byte.

        Post-condition: exactly one line differs from the pre-image, and that
        line contains $Version. Either check failing aborts the release.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][scriptblock]$Rewrite
    )

    if (-not (Test-Path $Path)) {
        throw "Cannot bump the version: $RelativePath not found at $Path."
    }

    # Bytes in, bytes out. UTF8.GetString keeps a BOM (if the file has one) as
    # a leading U+FEFF character, so it round-trips untouched.
    $before = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))

    $spans  = Get-LineSpans -Text $before
    $target = $null
    foreach ($span in $spans) {
        if ([regex]::IsMatch($span.Value, $Pattern)) { $target = $span; break }
    }
    if (-not $target) {
        throw @"
No line matching the version anchor in $RelativePath
  anchor: $Pattern

The anchor has moved. Fix the anchor -- do NOT fall back to a YAML/TOML/JSON
parser, which would delete this file's comments.
"@
    }

    $match     = [regex]::Match($target.Value, $Pattern)
    $rewritten = & $Rewrite $match

    # Splice highest group index first so the earlier offsets stay valid.
    $after = $before
    foreach ($group in ($rewritten.Groups.Keys | Sort-Object -Descending)) {
        $capture  = $match.Groups[$group]
        $absolute = $target.Index + $capture.Index
        $after = $after.Remove($absolute, $capture.Length).Insert($absolute, [string]$rewritten.Groups[$group])
    }

    # ---- Post-condition: exactly one line changed, and it carries $Version.
    $beforeLines = @($spans | ForEach-Object { $_.Value })
    $afterLines  = @(Get-LineSpans -Text $after | ForEach-Object { $_.Value })
    if ($beforeLines.Count -ne $afterLines.Count) {
        throw "Rewriting $RelativePath changed the line count ($($beforeLines.Count) -> $($afterLines.Count)). Aborting before anything is built."
    }
    $changed = @(0..($beforeLines.Count - 1) | Where-Object { $beforeLines[$_] -ne $afterLines[$_] })
    if ($changed.Count -ne 1) {
        throw "Rewriting $RelativePath changed $($changed.Count) lines; exactly 1 was expected. Aborting before anything is built."
    }
    if (-not $afterLines[$changed[0]].Contains($Version)) {
        throw "Rewriting $RelativePath produced '$($afterLines[$changed[0]])', which does not contain $Version. Aborting before anything is built."
    }

    Write-Host ("BUMP {0} {1} -> {2}" -f $RelativePath, $rewritten.Old, $rewritten.New)

    if ($DryRun) { return }

    [System.IO.File]::WriteAllBytes($Path, (New-Object System.Text.UTF8Encoding($false)).GetBytes($after))

    $readBack = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
    if ($readBack -ne $after) {
        throw "Wrote $RelativePath but reading it back produced different bytes. Aborting before anything is built."
    }
}

Write-Host "`nVersion bump" -ForegroundColor Cyan

# server/server-windows/Cargo.toml -- FIRST `version = "..."` line, which is
# the [package] one; dependency versions further down are all inside inline
# tables. Same anchor installer/build-installer.ps1 reads, so the two scripts
# cannot disagree about where the server's version lives.
Set-VersionField -Path $CargoToml -RelativePath 'server/server-windows/Cargo.toml' `
    -Pattern '^\s*version\s*=\s*"([^"]+)"' -Rewrite {
        param($m)
        @{ Groups = @{ 1 = $Version }; Old = $m.Groups[1].Value; New = $Version }
    }

# app/remote_control/pubspec.yaml -- BOTH halves. The build number after the +
# is Android's versionCode and must STRICTLY increase: Android refuses to
# install a lower code over a higher one. Leaving it pinned is the exact bug
# that made four shipped APKs all report themselves as 1.0.0.
Set-VersionField -Path $PubSpec -RelativePath 'app/remote_control/pubspec.yaml' `
    -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)$' -Rewrite {
        param($m)
        $oldSemver = $m.Groups[1].Value
        $oldBuild  = [int]$m.Groups[2].Value
        $newBuild  = $oldBuild + 1
        if ($newBuild -le $oldBuild) {
            throw "pubspec.yaml build number would not increase ($oldBuild -> $newBuild); Android would refuse the install."
        }
        @{ Groups = @{ 1 = $Version; 2 = [string]$newBuild }
           Old    = "$oldSemver+$oldBuild"
           New    = "$Version+$newBuild" }
    }

# extension/manifest.json -- the extension joins the unified version line here.
Set-VersionField -Path $ExtManifest -RelativePath 'extension/manifest.json' `
    -Pattern '"version"\s*:\s*"([^"]+)"' -Rewrite {
        param($m)
        @{ Groups = @{ 1 = $Version }; Old = $m.Groups[1].Value; New = $Version }
    }

# ---- Artifacts ---------------------------------------------------------
#
# These three names are a CONTRACT, not a convention: the server resolves each
# asset URL and its sha256 from a compiled-in prefix plus the release tag, and
# never accepts a download target supplied over the wire. Renaming an asset
# here silently breaks every installed client's self-update.

$Tag        = "v$Version"
$ApkAsset   = Join-Path $DistDir "RemoteControl-v$Version.apk"
$SetupAsset = Join-Path $DistDir "RemoteControl-Setup-v$Version.exe"
$ExtAsset   = Join-Path $DistDir "RemoteControl-Extension-v$Version.zip"
$FlutterApk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
$NotesFile  = Join-Path $env:TEMP "RemoteControl-$Tag-notes.md"

$BumpedFiles = @(
    'server/server-windows/Cargo.toml',
    'app/remote_control/pubspec.yaml',
    'extension/manifest.json'
)

function Write-DryRunStep {
    param([Parameter(Mandatory)][string]$Command)
    Write-Host "DRYRUN $Command" -ForegroundColor Yellow
}

# ---- Build -------------------------------------------------------------

Write-Host "`nBuild" -ForegroundColor Cyan

if ($DryRun) {
    Write-DryRunStep "cd `"$AppDir`"; flutter build apk --release"
    Write-DryRunStep "copy `"$FlutterApk`" -> `"$ApkAsset`""
    Write-DryRunStep "& `"$Installer`" -Version $Version   (writes `"$SetupAsset`")"
    Write-DryRunStep "Compress-Archive -Path `"$ExtDir`" -DestinationPath `"$ExtAsset`""
} else {
    if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }

    Write-Host "  flutter build apk --release ..."
    Push-Location $AppDir
    try {
        Invoke-Native -Exe 'flutter' -Arguments @('build', 'apk', '--release')
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build apk --release failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path $FlutterApk)) {
        throw "flutter reported success but $FlutterApk is missing."
    }
    Copy-Item -Path $FlutterApk -Destination $ApkAsset -Force

    # CALL installer/build-installer.ps1 -- never reimplement it. It already
    # writes exactly dist\RemoteControl-Setup-v<version>.exe.
    Write-Host "  installer/build-installer.ps1 ..."
    & $Installer -Version $Version
    if (-not (Test-Path $SetupAsset)) {
        throw "build-installer.ps1 reported success but $SetupAsset is missing."
    }

    # -Path <dir> puts the `extension` folder itself at the zip root, which is
    # what the extension README's "load the extension folder unpacked"
    # instructions assume.
    Write-Host "  extension zip ..."
    if (Test-Path $ExtAsset) { Remove-Item -Path $ExtAsset -Force }
    Compress-Archive -Path $ExtDir -DestinationPath $ExtAsset
    if (-not (Test-Path $ExtAsset)) {
        throw "Compress-Archive reported success but $ExtAsset is missing."
    }

    Write-Host "  three artifacts in $DistDir" -ForegroundColor Green
}

# ---- Hash --------------------------------------------------------------
#
# Printed so the published per-asset digests can be eyeballed against what
# was actually built on this machine.

Write-Host "`nsha256" -ForegroundColor Cyan

foreach ($asset in @($ApkAsset, $SetupAsset, $ExtAsset)) {
    if ($DryRun) {
        Write-DryRunStep "Get-FileHash -Algorithm SHA256 `"$asset`""
        continue
    }
    $digest = Get-FileHash -Algorithm SHA256 -Path $asset
    Write-Host ("SHA256 {0} {1}" -f (Split-Path -Leaf $asset), $digest.Hash.ToLowerInvariant())
}

# ---- Tag ---------------------------------------------------------------
#
# "Tag both repos" (D-20) is satisfied by this private-repo tag PLUS the
# mirror's own release tag, which `gh release create` creates for us -- the
# mirror holds no source, so it needs no --target.
#
# The bump is committed first: a tag placed on a dirty tree would point at the
# PREVIOUS commit, so the tag would not name the source the artifacts were
# built from.

Write-Host "`nTag" -ForegroundColor Cyan

if ($DryRun) {
    Write-DryRunStep "git add $($BumpedFiles -join ' ')"
    Write-DryRunStep "git commit -m `"chore(release): $Tag`""
    Write-DryRunStep "git tag $Tag"
    Write-DryRunStep "git push origin HEAD"
    Write-DryRunStep "git push origin $Tag"
} else {
    $existing = Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'tag', '--list', $Tag)
    if ($existing) {
        throw @"
The tag $Tag already exists in the private repo.

The version bump has been written to the working tree but nothing has been
pushed or published. Either delete the stale tag, or re-run with a higher
-Version after reverting the bump (git checkout -- $($BumpedFiles -join ' ')).
"@
    }

    Invoke-Native -Exe 'git' -Arguments (@('-C', $RepoRoot, 'add') + $BumpedFiles)
    if ($LASTEXITCODE -ne 0) { throw "git add of the bumped version files failed with exit code $LASTEXITCODE." }

    Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'commit', '-m', "chore(release): $Tag")
    if ($LASTEXITCODE -ne 0) { throw "git commit of the version bump failed with exit code $LASTEXITCODE." }

    Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'tag', $Tag)
    if ($LASTEXITCODE -ne 0) { throw "git tag $Tag failed with exit code $LASTEXITCODE." }

    Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'push', 'origin', 'HEAD')
    if ($LASTEXITCODE -ne 0) { throw "git push origin HEAD failed with exit code $LASTEXITCODE." }

    Invoke-Native -Exe 'git' -Arguments @('-C', $RepoRoot, 'push', 'origin', $Tag)
    if ($LASTEXITCODE -ne 0) { throw "git push origin $Tag failed with exit code $LASTEXITCODE." }

    Write-Host "  $Tag tagged and pushed" -ForegroundColor Green
}

# ---- Publish -----------------------------------------------------------
#
# Publishing authenticates through the operator's own `gh` login only. No
# credential, no auth header and no credential-bearing argument appears
# anywhere in this script, so nothing secret can leak into an artifact.
#
# -PreRelease semantics: a pre-release is published for the owner's own UAT
# and is DELIBERATELY INVISIBLE TO CLIENTS. The /releases/latest endpoint the
# clients read excludes pre-releases, and the client version parser rejects
# X.Y.Z-rcN tags as unknown, so a pre-release is never offered as an update.

Write-Host "`nPublish" -ForegroundColor Cyan

$Notes = "Remote Control $Tag -- Android app, Windows server and browser extension, all at $Version."

$GhArgs = @(
    'release', 'create', $Tag,
    $ApkAsset, $SetupAsset, $ExtAsset,
    '--repo', $MirrorRepo,
    '--title', $Tag,
    '--notes-file', $NotesFile
)
if ($PreRelease) { $GhArgs += '--prerelease' }

if ($DryRun) {
    Write-DryRunStep "write release notes -> `"$NotesFile`""
    Write-DryRunStep "& `"$Gh`" $($GhArgs -join ' ')"
    Write-Host "`nDry run complete. Nothing was written, built, tagged or published." -ForegroundColor Green
} else {
    Set-Content -Path $NotesFile -Value $Notes -Encoding UTF8

    Invoke-Native -Exe $Gh -Arguments $GhArgs
    if ($LASTEXITCODE -ne 0) {
        throw @"
gh release create failed with exit code $LASTEXITCODE.

$Tag is already tagged and pushed in the private repo, so re-running this
script would refuse the tag. Fix the cause (usually `gh auth login`, or an
existing draft release on $MirrorRepo) and finish by hand:

  & "$Gh" $($GhArgs -join ' ')
"@
    }

    Write-Host "`nReleased." -ForegroundColor Green
    Write-Host "  https://github.com/$MirrorRepo/releases/tag/$Tag"
}
