# Standalone check that the publisher cannot quietly publish over an occupied tag.
#
# WHY THIS IS A SOURCE-READING TEST
#
# Both damages on 05.10.2026 happened at a step no test could reach: the script builds four APKs,
# talks to GitHub and publishes. The only way to exercise the branch was to ship a release, which
# is what happened - twice. v32.67-beta1 and v32.67-beta2 were published on 02.10 and their APKs
# were replaced in place.
#
# What is asserted here is that the guard exists and is a STOP rather than a warning, that a
# lookup failure is not read as "free", and that the series is enumerated deeply enough to see
# old releases.
#
#     git show <fix>^:publish.ps1 > old-publish.ps1
#     powershell -File test-publish-overwrite-guard.ps1 -ScriptPath old-publish.ps1
#
# Usage:
#   powershell -File test-publish-overwrite-guard.ps1
#   powershell -File test-publish-overwrite-guard.ps1 -ScriptPath old-publish.ps1

param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot 'publish.ps1'),
    [string] $WrapperPath = (Join-Path $PSScriptRoot 'publish-beta.ps1')
)

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Write-Step($m) { Write-Host $m }

function Assert-Case([string] $name, [bool] $ok, [string] $detail) {
    if ($ok) {
        Write-Host ("pass {0}" -f $name) -ForegroundColor Green
        Write-Host ("       -> {0}" -f $detail) -ForegroundColor DarkGray
    } else {
        Write-Host ("FAIL {0}" -f $name) -ForegroundColor Red
        Write-Host ("     {0}" -f $detail) -ForegroundColor Red
        $script:failures++
    }
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "FAIL no such file: $ScriptPath" -ForegroundColor Red
    exit 1
}

Write-Step "overwrite guard in $([IO.Path]::GetFileName($ScriptPath))"
Write-Host ''

$src = [IO.File]::ReadAllText((Resolve-Path $ScriptPath).Path)

# --- 1. there must be an opt-in switch, and it must be off by default ----------
#
# A guard that is on by default and can be talked out of is a warning. The switch has to exist
# as a named thing, because "the operator typed a flag" is the difference between a decision and
# an oversight.

$hasSwitch = (Select-String -Path $ScriptPath -Pattern '\[switch\]\s*\$AllowOverwriteExistingRelease').Count -ge 1
Assert-Case 'theOverwriteSwitchExists' $hasSwitch `
    ("a named switch is required; found: {0}" -f $hasSwitch)

$defaultedOn = $false
$switchLine = @(Select-String -Path $ScriptPath -Pattern 'AllowOverwriteExistingRelease')
foreach ($s in $switchLine) {
    if ($s.Line -match ':\$true' -or $s.Line -match '=\s*\$true') { $defaultedOn = $true }
}
Assert-Case 'theSwitchIsOffByDefault' (-not $defaultedOn) `
    "no form of the switch turns itself on; a guard that defaults to permissive is not a guard"

# --- 2. an existing tag must STOP the run -------------------------------------
#
# Not warn. The warning existed, was printed in capitals with the tag and the original date, and
# was acted on zero times out of two.

# NOTE: no `@(...)` around Select-String before the comparison. `@(x) -ge 1` returns the MATCHES
# that satisfy it, not a boolean, and passing a MatchInfo[] into a [bool] parameter throws
# "not IComparable". This bit me while writing this file, which is the second time in this session
# a test broke on a type rather than on the thing it was testing.
$stopLines = @(Select-String -Path $ScriptPath -Pattern 'Fail\s+"refusing to overwrite existing release')
Assert-Case 'anExistingTagStopsTheRun' ($stopLines.Count -ge 1) `
    ("a Fail call on an occupied tag: {0} occurrence(s)" -f $stopLines.Count)

# --- 3. the stop must be reachable only through the switch -------------------

$guardsWithIf = @(Select-String -Path $ScriptPath -Pattern 'if\s*\(\s*-not\s+\$AllowOverwriteExistingRelease\s*\)')
Assert-Case 'theStopIsGuardedByTheSwitch' ($guardsWithIf.Count -ge 1) `
    ("the refusal sits inside `if (-not `$AllowOverwriteExistingRelease)`: {0} occurrence(s)" -f $guardsWithIf.Count)

# --- 4. "could not tell" must not be read as "free" --------------------------
#
# The pre-existing check was `$null = gh release view ...; if ($LASTEXITCODE -eq 0) { taken }
# else { free }`. A failed lookup and an absent release both arrive as non-zero, and it reported
# a published tag as free. The fix inspects the status code.

$inspects404 = @(Select-String -Path $ScriptPath -Pattern '\$status\s*-ne\s*404')
Assert-Case 'lookupFailureIsNotReadAsFree' ($inspects404.Count -ge 1) `
    ("the catch block inspects for a 404 rather than treating any failure as 'free': {0} occurrence(s)" -f $inspects404.Count)

$wrapperRefusesUnknown = $false
if (Test-Path $WrapperPath) {
    $wrapperRefusesUnknown = @(Select-String -Path $WrapperPath -Pattern 'UNKNOWN').Count -ge 1
}
Assert-Case 'theWrapperRefusesOnUnknown' $wrapperRefusesUnknown `
    "publish-beta.ps1 says that an unknown answer stops the publish"

# --- 5. the series must be enumerated deeply ---------------------------------
#
# `gh release list` sorts by published_at, not by name. The two destroyed releases date from
# 02.10 and sat at #17 and #18; at --limit 40 they fell off the end on a 43-release repo. A
# pre-flight that misses them looks exactly like one that found nothing to worry about.

$limit200 = $false
if (Test-Path $WrapperPath) {
    $limit200 = @(Select-String -Path $WrapperPath -Pattern 'release list --limit 200').Count -ge 1
}
Assert-Case 'theSeriesIsListedDeeply' $limit200 `
    "publish-beta.ps1 lists releases with --limit 200, not a page that drops old ones"

$reportsHighest = $false
if (Test-Path $WrapperPath) {
    $reportsHighest = @(Select-String -Path $WrapperPath -Pattern 'existing beta numbers').Count -ge 1
}
Assert-Case 'theExistingNumbersAreShown' $reportsHighest `
    "the pre-flight prints which beta numbers already exist, so a collision is visible before the build"

# --- 6. it must still parse --------------------------------------------------

$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Case 'publishParses' ($parseErrors.Count -eq 0) `
    ("{0} parse error(s)" -f $parseErrors.Count)

if (Test-Path $WrapperPath) {
    $t2 = $null; $e2 = $null
    [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$t2, [ref]$e2) | Out-Null
    Assert-Case 'theWrapperParses' ($e2.Count -eq 0) `
        ("{0} parse error(s)" -f $e2.Count)

    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $WrapperPath).Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-Case 'theWrapperKeepsItsBom' $hasBom `
        ("first bytes: {0}" -f (($bytes[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host 'all overwrite guard cases passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:failures) case(s) failed") -ForegroundColor Red
    exit 1
}