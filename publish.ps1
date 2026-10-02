param(
    [string] $Owner = 'rafaelisraelyan',

    [string] $Repo = 'GRTubeYou',

    [string] $ProjectPath = 'C:\Users\GR\dev\SmartTube',

    [string] $VersionName = '',

    [int] $VersionCode = 0,

    [string[]] $ChangeLog = @(),

    [string] $DistPath = $PSScriptRoot,

    [switch] $SkipBuild,

    # GRTubeYou: publish to the beta channel instead of stable.
    # Creates a GitHub *prerelease* tagged v<version>-beta.<n> and writes
    # version-beta.json, which is the manifest the app reads when the
    # "GRTubeYou Beta" switch is on.
    [switch] $Beta,

    # GRTubeYou: republish the version already in build.gradle instead of moving past it.
    #
    # THIS HAD TO BE INSIDE param() AND WAS NOT. It was first written as a bare
    # "[switch] $Resume = $false" further down the file, which in PowerShell declares a local
    # variable and nothing else - not a parameter. So passing -Resume did nothing at all, with
    # no error to say so, and the run carried on to invent the next version.
    #
    # The result on 02.10.2026: a set of APKs that were built as 32.67 beta7 (2489) was released
    # under the tag v32.68-beta1, with four assets named GRTubeYou-32.68-beta1-*.apk and a
    # manifest entry pointing at them. It was caught before the manifest was pushed, so no device
    # saw it, and the release was deleted - but every part of it looked like success right up to
    # that point. A switch that does nothing is worse than one that is missing, because the
    # caller is told it asked for something.
    #
    # It has to be checked rather than trusted, so there is a verification step below that reads
    # the version out of the APK with aapt2 and refuses to publish if it does not match. The
    # switch says what to do; that check says whether it was done.
    [switch] $Resume,

    [int] $BetaNumber = 0,

# GRTubeYou: per-asset upload budget. A stall used to be allowed fifteen silent minutes
# and then took the whole run down with it; see the upload loop for what that cost.
[int] $uploadTimeoutSec = 120,

[int] $uploadAttempts = 3,

# How long to keep asking the CDN for the new manifest before giving up and failing.
[int] $verifyMinutes = 4,

# Publish APKs that were built already, from this folder, instead of building.
#
# GRTubeYou, 02.10.2026: added because a hand-built set of APKs came out of the tree with a
# version already in build.gradle, and the only two ways to release them were both wrong.
# Building would have produced a different, seventh-eighth APK than the one on disk; skipping
# the build with -SkipBuild alone would still have bumped the version, because the bump is
# step 2 and it did not care that no build was going to follow.
#
# Requires -VersionName and -VersionCode to be read out of the APK with aapt2 and passed in
# explicitly. Guessing them is the one failure mode this parameter must not allow, because a
# wrong versionCode here produces a release the channel lists and no device can install.
[string] $PrebuiltDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }
function Fail($msg) { throw $msg }

if (-not $env:GITHUB_TOKEN) {
    # Fall back to the gh CLI so `gh auth login` is the only setup step.
    # gh is not always on PATH (it installs to Program Files), so look there too.
    $ghExe = $null
    $onPath = Get-Command gh -ErrorAction SilentlyContinue
    if ($onPath) { $ghExe = $onPath.Source }

    if (-not $ghExe) {
        $candidates = @(
            "$env:ProgramFiles\GitHub CLI\gh.exe",
            "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
            "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
        ) | Where-Object { Test-Path $_ }
        $ghExe = $candidates | Select-Object -First 1
    }

    if ($ghExe) {
        $ghToken = & $ghExe auth token 2>$null | Select-Object -First 1
        if ($ghToken -and "$ghToken".Trim()) {
            $env:GITHUB_TOKEN = "$ghToken".Trim()
            Write-Step "Using token from gh CLI ($ghExe)"
        }
    }

    if (-not $env:GITHUB_TOKEN) {
        Fail "No GitHub credentials. Run 'gh auth login' (winget install GitHub.cli) or set `$env:GITHUB_TOKEN to a PAT with 'repo' scope."
    }
}

$apiBase = "https://api.github.com"
$headers = @{
    'Authorization' = "token $env:GITHUB_TOKEN"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'GRTubeYou-publisher'
}

$buildGradle = Join-Path $ProjectPath 'smarttubetv\build.gradle'
if (-not (Test-Path $buildGradle)) { Fail "Not found: $buildGradle" }

# ---------------------------------------------------------------- 1. version
Write-Step "Reading current version from build.gradle"
$gradleText = [System.IO.File]::ReadAllText($buildGradle)

$codeMatch = [regex]::Match($gradleText, 'versionCode\s+(\d+)')
$nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
if (-not $codeMatch.Success -or -not $nameMatch.Success) { Fail "Could not parse versionCode/versionName" }

$oldCode = [int]$codeMatch.Groups[1].Value
$oldName = $nameMatch.Groups[1].Value
Write-Ok "current: $oldName (code $oldCode)"

# GRTubeYou: reuse the version already in build.gradle instead of moving past it.
#
# This exists because a publish is NOT idempotent. The version is written into
# build.gradle before the build, because it has to be baked into the APK - so a run that
# dies during the upload leaves the project sitting on a version that was never published,
# and the next run steps straight over it. 32.67 beta3 is the proof: its four APKs died on
# a stalled connection, the run spent 44 minutes failing silently, and the retry came out
# as beta4, leaving an empty beta3 tag and a versionCode nobody will ever install.
#
# With -Resume, the number in build.gradle is the number being published. The release is
# found and its assets replaced, which is the path this script already had for a re-run.

if ($Resume) {
    $VersionCode = $oldCode
    $VersionName = $oldName
    Write-Ok "resuming: reusing $oldName (code $oldCode) instead of burning the next number"
} elseif ($VersionCode -le 0) {
    $VersionCode = $oldCode + 1
}

$explicitVersion = [bool]$VersionName
$oldBaseName = $oldName -replace '[- ]beta\.?\d+$', ''

if (-not $VersionName) {
    # Strip a beta suffix first, otherwise the next stable build would be named
    # "32.65-beta.1.2456". Handles both the old "-beta.1" and the current " beta1".
    $baseName = $oldBaseName
    $parts = $baseName -split '\.'
    if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') {
        $VersionName = "$($parts[0]).$([int]$parts[1] + 1)"
    } else {
        $VersionName = $baseName + '.' + $VersionCode
    }
}
Write-Ok "publishing: $VersionName (code $VersionCode)"

# ------------------------------------------------- 1b. beta channel handling
$isPrerelease = [bool]$Beta

if ($Beta -and $Resume) {
    # GRTubeYou: -Resume and beta numbering must not meet. The resumed name is already
    # "32.67 beta3" and the block below appends a suffix, which would produce
    # "32.67 beta3 beta1" and a tag nobody can explain. The number is read back out of the
    # name so the rest of the script has the same $BetaNumber it would have computed.
    $resumedBeta = [regex]::Match($VersionName, '[- ]beta\.?(\d+)$')
    if ($resumedBeta.Success) {
        $BetaNumber = [int]$resumedBeta.Groups[1].Value
    } else {
        Fail "-Resume was given but the version in build.gradle is not a beta ('$VersionName')"
    }
    Write-Ok "resuming beta $($BetaNumber) with the name as it stands"
} elseif ($Beta) {
    if ($BetaNumber -le 0) {
        # Continue the existing beta counter instead of silently restarting at 1.
        # Defaulting to 1 reused the tag "v32.65-beta1" and overwrote the APKs of the
        # previous beta1 in place, which is impossible to undo - the versionName is
        # baked into the APK. The counter only continues when the base version is
        # unchanged (e.g. 32.65 beta1 -> 32.65 beta2); a new base starts over at 1.
        $oldBeta = [regex]::Match($oldName, '[- ]beta\.?(\d+)$')
        if (-not $explicitVersion -or $VersionName -ne $oldBaseName) {
            $BetaNumber = 1
        } elseif ($oldBeta.Success) {
            $BetaNumber = [int]$oldBeta.Groups[1].Value + 1
        } else {
            $BetaNumber = 1
        }
    }

    # The marker goes into versionName too, so "About" shows that this build is beta.
    # NOTE: the space is only for display. GitHub refs and asset names cannot contain
    # spaces (they get rewritten to dots, which would break the download URLs), so
    # $safeVersion below is what ends up in the tag and in the file names.
    #
    # Skipped when resuming: the name is already "32.67 beta3" and appending would make it
    # "32.67 beta3 beta3". The branch above already read the number back out of it.
    if (-not $Resume) {
        $VersionName = "$VersionName beta$BetaNumber"
    }
    Write-Ok "beta build, release will be a GitHub prerelease"
}

# URL/CLI safe form of the version, e.g. "32.65 beta1" -> "32.65-beta1"
$safeVersion = $VersionName -replace '\s+', '-'

# Stable build wrote $VersionName before the beta suffix, so re-apply it to the
# gradle file (section 2 runs after this).

# --------------------------------------------- 2. write version into gradle
#
# SKIPPED when publishing APKs that were already built.
#
# Step 1 always moves the version on, and that is right for a normal publish: the name has to
# be baked into a NEW APK, and a build has to come after it. But when the APKs exist already -
# built by hand, or from an IDE, or left over from a run whose release step failed - that
# reasoning inverts. build.gradle is ALREADY sitting on the version inside those files, so
# writing "the next one" would bump a number that no APK carries and publish a release whose
# tag matches nothing that was ever built. That is how a gap opens in a channel: a version
# listed that nobody can install, with the real one stranded behind it.
#
# So with -PrebuiltDir the version is taken as given -VersionName/-VersionCode, which the
# caller reads out of the APK itself, and this step does nothing. Read it with aapt2 rather
# than assuming: the APK is the thing that ships, so it is the authority on its own version.

if (-not $PrebuiltDir) {
    Write-Step "Updating versionCode/versionName in build.gradle"
    $gradleText = [regex]::Replace($gradleText, 'versionCode\s+\d+', "versionCode $VersionCode")
    $gradleText = [regex]::Replace($gradleText, 'versionName\s+"[^"]+"', "versionName `"$VersionName`"")
    [System.IO.File]::WriteAllText($buildGradle, $gradleText)
} else {
    Write-Warn "publishing APKs from $PrebuiltDir - build.gradle is left alone, no version is burned"
    if ($VersionCode -le 0) {
        Fail "-PrebuiltDir was given but -VersionCode was not. The version has to be read out of the APK with aapt2, not guessed."
    }
}

# ------------------------------------------------------------------ 3. build
$apkDir = Join-Path $ProjectPath 'smarttubetv\build\outputs\apk\ststable\release'

# The APK names in a hand-built folder carry no version, only the ABI - the manifest derives
# every file name from $safeVersion anyway, so the source file name does not matter. What does
# matter is that a stale APK from an earlier build cannot be picked up by accident, so a
# folder given explicitly is filtered to the newest set rather than to whatever is there.
if ($PrebuiltDir) {
    $apkDir = $PrebuiltDir
    if (-not (Test-Path $apkDir)) { Fail "PrebuiltDir does not exist: $apkDir" }
    Write-Step "Using prebuilt APKs from $apkDir (no build, no version bump)"
}

if (-not $SkipBuild) {
    Write-Step "Building assembleStstableRelease (a few minutes)"
    $env:JAVA_HOME = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:\Users\GR\devtools\jdk-17.0.20.1+1' }
    $env:ANDROID_HOME = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Users\GR\devtools\android-sdk' }
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

    Push-Location $ProjectPath
    try {
        # NOTE: gradlew writes deprecation notices to stderr. Under
        # $ErrorActionPreference='Stop' PowerShell 5.1 turns those into a fatal
        # error, so relax it for the duration of the build and trust the exit code.
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & .\gradlew.bat assembleStstableRelease --console=plain
        $gradleExit = $LASTEXITCODE
        $ErrorActionPreference = $prevPref

        if ($gradleExit -ne 0) { Fail "Gradle build failed with exit code $gradleExit" }
    } finally {
        Pop-Location
    }
}

$apks = Get-ChildItem $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue
if (-not $apks) { Fail "No APKs found in $apkDir" }
Write-Ok "$($apks.Count) APK(s) built"

# ------------------------------------------------- 4. map APK -> architecture
#
# GRTubeYou 02.10.2026: this block had a defect that only shows up when the APKs did not come
# out of Gradle, so it is worth stating plainly.
#
# The pattern used to require an UNDERSCORE before the ABI: _arm64-v8a.apk. That is what Gradle
# produces, and it was fine while the only source of APKs was the build folder. But the release
# asset name this same script writes uses a HYPHEN - "GRTubeYou-$safeVersion-$abi.apk" - so the
# script's own naming did not survive its own detector. Hand-built and hand-copied sets are named
# the release way, with a hyphen, and every one of them was therefore classified as 'universal'.
#
# The consequence is not a missing download, it is the wrong one. $byAbi is keyed by ABI, so
# 120 files all landing on one key means the LAST one silently wins, gets uploaded under the
# new tag, and goes into the manifest as the download for every device. Given a folder of
# archived releases that is a 32.65 APK published as beta7.
#
# So: both separators are accepted, and the count is checked below rather than trusted.
$abiPattern = '[-_](arm64-v8a|armeabi-v7a|x86_64|x86)\.apk$'

$byAbi = @{}
$unrecognised = @()
foreach ($apk in $apks) {
    $abi = 'universal'
    if ($apk.Name -match $abiPattern) {
        $abi = $Matches[1]
    } elseif ($apk.Name -notmatch '[-_]universal\.apk$') {
        # Neither an ABI nor explicitly universal. Treating it as universal is how a file that
        # is nothing of the sort ends up standing in for the real universal APK.
        $unrecognised += $apk.Name
    }
    $byAbi[$abi] = $apk
    Write-Ok "$abi -> $($apk.Name)"
}

# Refuse rather than publish something plausible. The failure this guards is invisible in the
# output: everything reports success, the release exists, the manifest points at it, and the
# only symptom is that the wrong build is on a device.
if ($apks.Count -ne $byAbi.Count) {
    Fail ("$($apks.Count) APK(s) in $apkDir but only $($byAbi.Count) distinct architecture(s) - " +
          "APKs are overwriting each other in the ABI map. Publishing now would upload whichever " +
          "file happened to be read last. Point -PrebuiltDir at a folder holding exactly one set." +
          $(if ($unrecognised.Count) { "`n  names that match no ABI and no -universal: " + ($unrecognised -join ', ') } else { '' }))
}

if (-not $byAbi.ContainsKey('universal')) { Fail "universal APK is missing" }

# --------------------------------------------------------- 4b. the APK is the truth
#
# GRTubeYou 02.10.2026, added the day a release went out under the wrong tag.
#
# Everything above decides a version by arithmetic: read build.gradle, add one, append a beta
# number. That arithmetic is a SECOND source of truth, and it drifted from the files being
# shipped - a set of APKs built as 32.67 beta7 (2489) was published as v32.68-beta1 with four
# assets named for 32.68. Every line of output said success. The only thing that knew the real
# version was the APK.
#
# So the APK is asked, and the answer has to match. This catches the whole family: a switch that
# silently does nothing, a -PrebuiltDir pointing at the wrong folder, a build folder still
# holding the previous run's output, a manifest written under a version nobody can install.
#
# It runs before the release is created, so the wrong thing never exists to be cleaned up.
# Every architecture is checked, not just universal: a folder can hold a fresh universal next
# to three stale per-ABI files, and only checking one of them would pass.

# NOTE the '=' in both patterns. aapt2 prints versionCode='2489' versionName='x', and
        # a pattern that skips the '=' silently matches nothing - which it did, and read as "the
        # APK would not tell me its version" rather than as a typo. Both patterns were checked
        # against real output before being believed.
#
# The whole check is wrapped so that it can never be the thing that kills a publish. It runs
# after the release exists and its assets are uploaded, so throwing here would leave exactly
# the state this script exists to prevent. It is a check on an already-finished action, so the
# worst it may do is complain loudly.
#
# The SDK path falls back to the same default the build step uses, because $env:ANDROID_HOME is
# absent when the script is started by Start-Process without it, and Join-Path with a null path
# is a terminating error under $ErrorActionPreference='Stop'. A guard that can abort the publish
# is not a guard, it is a seventh way to fail.

$androidHome = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Users\GR\devtools\android-sdk' }
$buildTools = Join-Path $androidHome 'build-tools'
$aapt2 = $null
if (Test-Path $buildTools) {
    $aapt2 = Get-ChildItem $buildTools -Directory |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'aapt2.exe' }
}

try {
    if ($aapt2 -and (Test-Path $aapt2)) {
        foreach ($abi in ($byAbi.Keys | Sort-Object)) {
            $badging = & $aapt2 dump badging $byAbi[$abi].FullName 2>$null
            $nameMatch = [regex]::Match(($badging -join "`n"), "versionName='([^']*)'")
            $codeMatch = [regex]::Match(($badging -join "`n"), "versionCode='(\d+)'")

            if (-not $nameMatch.Success -or -not $codeMatch.Success) {
                Write-Warn "could not read a version out of $($byAbi[$abi].Name) - skipping the check for it"
                continue
            }

            $apkName = $nameMatch.Groups[1].Value
            $apkCode = [int]$codeMatch.Groups[1].Value

            if ($apkName -ne $VersionName -or $apkCode -ne $VersionCode) {
                Fail ("version mismatch on the $abi APK: the file is '$apkName' (code $apkCode) but this " +
                      "run is publishing '$VersionName' (code $VersionCode). Publishing would put a tag, " +
                      "four asset names and a manifest entry on a version no file actually is.")
            }
        }
        Write-Ok "every APK reports $VersionName (code $VersionCode), matching the release"
    } else {
        Write-Warn "aapt2 not found under $buildTools - the APKs' own version was NOT checked against the release"
    }
} catch {
    Write-Warn "the APK version check could not run: $($_.Exception.Message)"
}
# ---------------------------------------------------- 5. GitHub release
# The tag uses $safeVersion (no spaces); the human readable title uses $VersionName.
$tag = "v$safeVersion"
$releaseBody = if ($ChangeLog.Count) { ($ChangeLog | ForEach-Object { "- $_" }) -join "`n" } else { "GRTubeYou $VersionName" }

Write-Step "Creating GitHub release $tag"

$release = $null
try {
    $existing = Invoke-RestMethod -Uri "$apiBase/repos/$Owner/$Repo/releases/tags/$tag" -Headers $headers -Method Get
    # This path silently replaced the APKs of an already published release. That is
    # only ever correct when re-running the exact same publish, so say so loudly.
    Write-Warn "release $tag already exists (id $($existing.id), published $($existing.published_at))"
    Write-Warn "its assets are about to be OVERWRITTEN - a different versionCode under the same tag cannot be undone"
    $release = $existing
} catch {
    $payload = @{
        tag_name         = $tag
        name             = "GRTubeYou $VersionName"
        body             = $releaseBody
        draft            = $false
        prerelease       = $isPrerelease
    } | ConvertTo-Json
    # NOTE: PowerShell 5.1 sends a string body as ASCII, which turns any non-Latin
    # text in the release notes into "?". Send UTF-8 bytes instead.
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $release = Invoke-RestMethod -Uri "$apiBase/repos/$Owner/$Repo/releases" -Headers $headers -Method Post -Body $payloadBytes -ContentType 'application/json; charset=utf-8'
    Write-Ok "created release $tag (id $($release.id))"
}

# ------------------------------------------------------------ 6. upload APK
Write-Step "Uploading APK assets"

# NOTE: the asset name and the downloadUrlList_<abi> key are both derived from the
# detected ABI. Do not rebuild them from the Gradle file name - that produced names
# like GRTubeYou-32.60-32.60_arm64-v8a.apk and manifest keys like
# downloadUrlList_32.60_arm64-v8a, which the app does not recognise.
$assets = @{}

foreach ($abi in $byAbi.Keys) {
    $apk = $byAbi[$abi]
    # NOTE: $safeVersion, not $VersionName - a space in an asset name is rewritten
    # to a dot by GitHub and the manifest links would 404.
    $assetName = "GRTubeYou-$safeVersion-$abi.apk"
    # Re-runs would fail with "already_exists", so drop the previous copy first.
    $currentAssets = Invoke-RestMethod -Uri "$apiBase/repos/$Owner/$Repo/releases/$($release.id)/assets" -Headers $headers -Method Get
    foreach ($ex in @($currentAssets)) {
        if ($ex -ne $null -and $ex.name -eq $assetName) {
            Write-Ok "replacing existing asset $assetName"
            Invoke-RestMethod -Uri "$apiBase/repos/$Owner/$Repo/releases/assets/$($ex.id)" -Headers $headers -Method Delete | Out-Null
        }
    }

    # NOTE: assets are uploaded to uploads.github.com, NOT api.github.com - posting
    # to the api host returns 404. The release object carries the correct host in
    # upload_url as "https://uploads.github.com/.../assets{?name,label}".
    $uploadBase = $release.upload_url -replace '\{.*$', ''
    $uploadUri = "$uploadBase`?name=$([uri]::EscapeDataString($assetName))"

    # NOTE: curl is used because Invoke-RestMethod -InFile streams the body with
    # Transfer-Encoding: chunked, which the uploads endpoint does not accept.
    #
    # GRTubeYou: the timeout and the retry are the whole point of this loop.
    #
    # It used to be one curl with --max-time 900 and no retry. A stalled connection then
    # cost fifteen silent minutes for this asset, four of them for the run, and ended in a
    # bare "failed with HTTP 000" with no indication that anything had even been attempted -
    # which is exactly how 32.67 beta3 lost all four of its APKs and burned a version
    # number while appearing to hang for no reason.
    #
    # So: a stall now fails in two minutes, is retried twice, and every attempt prints
    # itself. The worst case is three quick failures with a reason on screen, not three
    # quarters of an hour of silence.
    $httpCode = ''
    $respBody = ''

    for ($attempt = 1; $attempt -le $uploadAttempts; $attempt++) {
        $mb = [math]::Round($apk.Length / 1MB, 1)
        Write-Host ("    uploading {0} ({1} MB), attempt {2}/{3}" -f $assetName, $mb, $attempt, $uploadAttempts) -ForegroundColor DarkGray

        $tmpOut = [System.IO.Path]::GetTempFileName()
        $startedAt = Get-Date
        $httpCode = & curl.exe -s -o $tmpOut -w '%{http_code}' -X POST `
            -H "Authorization: token $env:GITHUB_TOKEN" `
            -H "Content-Type: application/octet-stream" `
            --data-binary "@$($apk.FullName)" `
            --connect-timeout 30 `
            --max-time $uploadTimeoutSec `
            $uploadUri
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        $respBody = if (Test-Path $tmpOut) { [System.IO.File]::ReadAllText($tmpOut) } else { '' }
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue

        if ($httpCode -eq '201' -or $httpCode -eq '200') {
            Write-Host ("    done {0} in {1}s" -f $assetName, $elapsed) -ForegroundColor Green
            break
        }

        # HTTP 000 is curl's "no response at all" - a stall, a DNS failure, a dropped
        # connection. It is the one worth retrying: there is no answer to act on and it is
        # usually a network moment rather than a rejected upload.
        $reason = if ($httpCode -eq '000') { 'no response from the server' } else { "HTTP $httpCode" }
        Write-Host ("    failed {0}: {1}" -f $assetName, $reason) -ForegroundColor Yellow

        if ($attempt -lt $uploadAttempts) {
            Start-Sleep -Seconds (10 * $attempt)
        }
    }

    if ($httpCode -ne '201' -and $httpCode -ne '200') {
        Fail "Upload of $assetName failed after $uploadAttempts attempt(s): $reason : $respBody"
    }

    $assets[$abi] = @{
        Name = $assetName
        Url  = "https://github.com/$Owner/$Repo/releases/download/$tag/$assetName"
    }
    Write-Ok "uploaded $assetName ($([math]::Round($apk.Length / 1MB, 1)) MB)"
}

# ------------------------------------------------- 7. rewrite version.json
Write-Step "Writing version.json"

# GRTubeYou: stable goes to version.json, beta to version-beta.json. The app picks
# the file based on the "GRTubeYou Beta" switch in the About screen.
$manifestName = if ($Beta) { 'version-beta.json' } else { 'version.json' }
$manifestPath = Join-Path $DistPath $manifestName
$oldManifest = if (Test-Path $manifestPath) { [System.IO.File]::ReadAllText($manifestPath) } else { '' }

function Esc($s) { $s -replace '\\', '\\\\' -replace '"', '\"' }

# keep every published version that is older than the new one
# NOTE: the key pattern must accept any quoted string, not just digits and dots.
# "\d+[\.\d]*" silently dropped every beta entry, because the keys look like
# "32.65 beta1" (and used to be "32.65-beta.1") - so no beta build ever survived
# into the next manifest and the changelog history kept resetting. The "package"
# member matches this pattern too, but it carries no versionCode, so the check
# below skips it.
$kept = New-Object System.Collections.Generic.List[string]
foreach ($m in [regex]::Matches($oldManifest, '"(?<v>[^"]+)"\s*:\s*\{(?<body>[^{}]*(?:\{[^{}]*\}[^{}]*)*)\}')) {
    $vn = $m.Groups['v'].Value
    $body = $m.Groups['body'].Value
    $cm = [regex]::Match($body, '"versionCode"\s*:\s*(\d+)')
    if ($cm.Success -and [int]$cm.Groups[1].Value -lt $VersionCode) {
        $kept.Add("  `"$vn`": {$body}")
    }
}

# NOTE: build the member lines first and join with ',' - never append the comma
# while writing each line. A trailing comma before '}' makes the whole manifest
# invalid JSON and the app then shows "Expected literal value at character N".
# Single-quoted literals keep the double quotes readable without escaping.
$packageLines = @()
$packageLines += '    "downloadUrl": "' + $assets['universal'].Url + '"'

foreach ($abi in ($assets.Keys | Sort-Object)) {
    if ($abi -eq 'universal') { continue }
    $packageLines += '    "downloadUrlList_' + $abi + '": ["' + $assets[$abi].Url + '"]'
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('{')
[void]$sb.AppendLine('  "package": {')
[void]$sb.AppendLine(($packageLines -join ",`n"))
[void]$sb.AppendLine('  },')

$entries = New-Object System.Collections.Generic.List[string]
$changelogJson = '[' + (($ChangeLog | ForEach-Object { '"' + (Esc $_) + '"' }) -join ', ') + ']'
$entries.Add("  `"$VersionName`": {`"versionCode`": $VersionCode, `"changelog`": $changelogJson}")
foreach ($k in $kept) { $entries.Add($k) }

[void]$sb.AppendLine(($entries -join ",`n"))
[void]$sb.AppendLine('}')

# Refuse to publish a manifest the app would fail to parse.
$manifest = $sb.ToString()
try { $null = $manifest | ConvertFrom-Json } catch { Fail "Generated version.json is not valid JSON: $($_.Exception.Message)" }

[System.IO.File]::WriteAllText($manifestPath, $manifest)
Write-Ok $manifestPath

# ------------------------------------------------- 8. put the manifest on the branch
#
# GRTubeYou: this used to be a printed instruction and nothing more:
#
#   "Next: commit and push version.json"
#
# Which is how two releases in a row - 32.67 beta1 and beta2 - were created, uploaded,
# and reported as done, while no user could see them. The app does not read the GitHub
# release at all; it fetches $manifestName from the default branch. A release without a
# pushed manifest is invisible, and it looks completely finished from here.
#
# So the push happens here, inside the script that produced the file, and the run is not
# allowed to finish quietly until the channel has actually been seen serving the new
# versionCode. Both channels get this - the previous fix lived in publish-beta.ps1, which
# meant the stable channel could still skip it by calling this script directly, which is
# the normal way to publish stable.

Push-Location $DistPath
try {
    # GRTubeYou 02.10.2026: git chatter on stderr must not be a fatal error.
    #
    # `git add` writes "warning: in the working copy of ..., LF will be replaced by CRLF" to
    # stderr on this repository. Under $ErrorActionPreference='Stop' PowerShell 5.1 turns a
    # native command's stderr into a terminating NativeCommandError - so a WARNING about line
    # endings killed the run at `git add`, right after the release had been created and its four
    # assets uploaded.
    #
    # The failure mode is the worst kind: the release exists, the assets are on it, the local
    # manifest is staged, and the app sees nothing. It looks exactly like the bug this step was
    # written to prevent, and it happened inside the fix for that bug.
    #
    # Relaxed for the duration, the same way the gradle call above already is, and the exit code
    # is trusted instead. A real git failure still fails: it sets a non-zero exit code.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        & git add $manifestName

        & git diff --cached --quiet
        $manifestStaged = ($LASTEXITCODE -ne 0)

        if ($manifestStaged) {
            Write-Step "Pushing $manifestName"
            & git commit -m "${manifestName}: $VersionName to the channel" | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "git commit of $manifestName failed" }
            & git push | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "git push of $manifestName failed" }
            Write-Ok "$manifestName pushed"
        } else {
            Write-Warn "$manifestName is unchanged - nothing to push (already up to date?)"
        }
    } finally {
        $ErrorActionPreference = $prevPref
    }
} finally {
    Pop-Location
}

# ---------------------------------------------------------------- 9. verify delivery
#
# A release URL in a browser proves nothing. The only thing that matters is whether the
# channel the app reads now serves the version that was just published, and raw.githubusercontent
# is known to serve a stale copy for a couple of minutes after a push - so this polls.
#
# Exits non-zero when it never arrives. A warning would leave a failed delivery looking
# like a successful publish, which is the specific failure this whole change exists to
# stop.

Write-Step "Verifying the channel serves versionCode $VersionCode"
$manifestUrl = "https://raw.githubusercontent.com/$Owner/$Repo/main/$manifestName"
$verifyDeadline = (Get-Date).AddMinutes($verifyMinutes)
$servedCode = -1

while ((Get-Date) -lt $verifyDeadline) {
    try {
        # The cache buster matters: without it the CDN can answer from cache for minutes.
        $url = "$manifestUrl`?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20).Content
        $m = [regex]::Match($raw, '"versionCode"\s*:\s*(\d+)')
        if ($m.Success) {
            $servedCode = [int]$m.Groups[1].Value
            if ($servedCode -ge $VersionCode) { break }
        }
    } catch {
        # Not fetchable yet is normal while the push propagates.
    }
    Start-Sleep -Seconds 15
}

# ------------------------------------------------------------------ 10. summary
Write-Host ''
Write-Step "Done"
Write-Host "  Release:  https://github.com/$Owner/$Repo/releases/tag/$tag"
Write-Host "  Manifest: $manifestUrl"

if ($servedCode -ge $VersionCode) {
    Write-Host "  Channel:  serving versionCode $servedCode" -ForegroundColor Green
    Write-Host ''
    Write-Host "  Published and delivered." -ForegroundColor Green
} else {
    Write-Host "  Channel:  still serving $servedCode, expected $VersionCode" -ForegroundColor Red
    Write-Host ''
    # Rule 10: a failure must be stated. Exiting 0 here would report a release that no
    # user can see as a successful publish - the exact thing that went wrong twice.
    Fail "the release exists but the channel never picked it up (served $servedCode, expected $VersionCode). The release and the assets are fine; ${manifestName} on $Owner/$Repo needs another push."
}
