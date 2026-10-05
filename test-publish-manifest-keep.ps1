# Standalone check that publish.ps1 carries the right entries into the next manifest.
#
# WHAT THIS IS FOR
#
# Two defects, both found on 05.10.2026 by looking at the file rather than at the code:
#
#   1. "32.67 beta1" and "32.67 beta2" appeared TWICE each, at codes 2503/2504 and at 2483/2484.
#      Same key, two codes. ConvertFrom-Json keeps the last one, so the manifest parsed fine and
#      nothing complained - the file simply said "32.67 beta1" and meant two different builds.
#
#   2. The releases behind 2503/2504 were then deleted, and the entries stayed. The manifest
#      advertised two versions nobody can install, with changelogs describing code that no longer
#      exists. Measured: 42 entries, 40 unique names, 2 of them dead.
#
# Both survived every publish because the manifest is rewritten from the previous one each time, so
# whatever is not cleaned here comes straight back on the next release.
#
# WHY IT IS AN EXECUTED TEST AND NOT A SOURCE-READING ONE
#
# The failure in both cases is a wrong LIST. Reading publish.ps1 cannot tell you whether the entry
# that survives a duplicate is the newer one or the older one, and cannot tell you what gets dropped
# when the release list is empty. So the block is cut out of publish.ps1 and run against manifests
# and tag lists that are built to break it.
#
# Usage:
#   powershell -File test-publish-manifest-keep.ps1
#   powershell -File test-publish-manifest-keep.ps1 -ScriptPath old-publish.ps1

param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot 'publish.ps1')
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

Write-Step "manifest entry keeping in $([IO.Path]::GetFileName($ScriptPath))"
Write-Host ''

$src = [IO.File]::ReadAllText((Resolve-Path $ScriptPath).Path)

# ---------------------------------------------------------------- the block
#
# From `$keptByName = ` up to the line before the member-line building. That is the whole of
# section 7's entry selection: the regex walk over the old manifest, the duplicate handling, and the
# prune against the release list.
#
# The end marker is a comment rather than a code line on purpose - "NOTE: build the member lines
# first" is the first thing after the selection is finished, and it has been there longer than the
# code it follows.

$startIdx = $src.IndexOf('$keptByName = ')
$endIdx = $src.IndexOf('# NOTE: build the member lines first')

if ($startIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -lt $startIdx) {
    Assert-Case 'theEntrySelectionBlockIsFound' $false `
        ("could not cut the block out: start {0}, end {1}. This test has to run the real code, not a copy." -f $startIdx, $endIdx)
    Write-Host ''
    Write-Host "$($script:failures) case(s) failed" -ForegroundColor Red
    exit 1
}

Assert-Case 'theEntrySelectionBlockIsFound' $true `
    ("{0} lines, from offset {1} to {2}" -f (($src.Substring($startIdx, $endIdx - $startIdx)) -split "`n").Count, $startIdx, $endIdx)

$block = $src.Substring($startIdx, $endIdx - $startIdx)

# ---------------------------------------------------------------- the harness
#
# $knownTags comes from an HTTP call in the real script. Here it is fed directly, which is what makes
# the fail-safe behaviour testable at all: the dangerous case is the call FAILING, and that is not
# reproducible against the network on demand.
#
# $TagFetchFails is how that is expressed. The real script assigns $null in its catch block; the same
# shape is reproduced here so the block under test cannot tell the difference.

function Invoke-EntrySelection {
    param(
        [string] $oldManifest,
        [int]    $VersionCode,
        [string[]] $knownTags,      # $null == "could not fetch the list"
        [switch] $TagFetchFails
    )

    if ($TagFetchFails) { $knownTags = $null }

    # NOTE: the shims below are FUNCTIONS, not assignments.
    #
    # The first version wrote `Write-Warn = { param($m) }`, which PowerShell reads as an attempt to
    # run a command called "Write-Warn=" - not as defining anything - and the run died with
    # "The term 'Write-Warn' is not recognized". A shim that does not install is worse than no shim:
    # it fails at the point where the behaviour under test would have been reported.
    #
    # Defined inside the scriptblock so they cover only the code under test and not this test.
    #
    # Invoke-RestMethod is shimmed too, and that shim is the point of the whole harness. The block
    # being tested FETCHES the release list itself - the fetch is inside it, deliberately, because it
    # is what decides whether entries get pruned. Injecting $knownTags from outside does nothing: the
    # block overwrites it with a real HTTP call. That is what happened on the first run - it reported
    # "release list: 42 tags known" against a live API, and every fail-safe case failed at once,
    # which looked like the production code being wrong and was the harness being ignored.
    #
    # So the fetch is intercepted. $knownTags = $null makes the shim throw, which is how "could not
    # list releases" is reproduced - not simulated by skipping the code, which would leave the catch
    # block itself untested.
    $runner = [scriptblock]::Create(@'
$ErrorActionPreference = 'Stop'
function Write-Warn { param($m) $script:suppressedWarn = $m }
function Write-Step { param($m) }
function Invoke-RestMethod {
    if ($null -eq $script:fakeTags) { throw 'list releases: simulated network failure' }
    return @($script:fakeTags | ForEach-Object { [pscustomobject]@{ tag_name = $_ } })
}
$script:fakeTags = $args[2]
$oldManifest = $args[0]
$VersionCode = $args[1]
$assets = @{}
$apiBase = 'https://api.github.com'
$Owner = 'rafaelisraelyan'
$Repo = 'GRTubeYou'
$headers = @{}
'@ + "`n" + $block + @'

foreach ($line in $kept) {
    $m = [regex]::Match($line, '^\s*"(?<n>[^"]+)"')
    if ($m.Success) { Write-Output $m.Groups['n'].Value }
}
'@)

    # NOTE the flattening. The runner emits one name per line as pipeline output, and the return
    # wraps it in @() - which is what gives a plain string[] here. An earlier version emitted
    # ",@($names)", so the caller got an array CONTAINING an array and every .Count was 1.
    $out = @()

    foreach ($item in @(& $runner $oldManifest $VersionCode $knownTags)) {
        $out += $item
    }

    return $out
}

# A manifest shaped like the real one, including the duplicate and dead pairs.
$withDuplicates = @'
{
  "package": {
    "downloadUrl": "https://example/GRTubeYou-32.67-beta3-universal.apk"
  },
  "32.67 beta3": {"versionCode": 2505, "changelog": ["newest"]},
  "32.67 beta2": {"versionCode": 2504, "changelog": ["destroyed, rewritten"]},
  "32.67 beta1": {"versionCode": 2503, "changelog": ["destroyed, rewritten"]},
  "32.67 beta18": {"versionCode": 2501, "changelog": ["older"]},
  "32.65 beta3": {"versionCode": 2459, "changelog": ["old series"]},
  "32.67 beta2": {"versionCode": 2484, "changelog": ["original"]},
  "32.67 beta1": {"versionCode": 2483, "changelog": ["original"]}
}
'@

$allTags = @('v32.67-beta3', 'v32.67-beta4', 'v32.67-beta18', 'v32.65-beta3')
$newCode = 2506

# ---------------------------------------------------------------- 1. duplicates
#
# The decisive case, and the one that says WHICH copy survives. The newer code has to win, because a
# device on 2503 should be told what 2503 changed, and 2483 is a build that no longer exists anywhere.

$names = Invoke-EntrySelection -oldManifest $withDuplicates -VersionCode $newCode -knownTags $allTags

$dups = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
Assert-Case 'noNameAppearsTwice' ($dups.Count -eq 0) `
    ("{0} duplicate name(s) survived: {1}" -f $dups.Count, (($dups | ForEach-Object { $_.Name }) -join ' | '))

# Counted off the manifest above, not guessed: 7 version entries, of which 2 are duplicates of names
# already present (2483/2484) and 2 more are dead (beta1/beta2 have no release). 7 - 2 - 2 = 3.
Assert-Case 'everyUnwantedEntryIsActuallyGone' ($names.Count -eq 3) `
    ("expected 3 - 7 entries, minus 2 duplicate copies, minus 2 dead. Got {0}: {1}" -f `
     $names.Count, ($names -join ' | '))

# ---------------------------------------------------------------- 2. dead entries
#
# The tag list omits v32.67-beta1 and v32.67-beta2 - they were deleted - so their entries must go.

Assert-Case 'aDeadEntryIsDropped' (-not ($names -contains '32.67 beta1')) `
    ("'32.67 beta1' should be gone: its release was deleted. Entries kept: {0}" -f ($names -join ' | '))

Assert-Case 'aDeadEntryIsDroppedToo' (-not ($names -contains '32.67 beta2')) `
    ("'32.67 beta2' should be gone for the same reason. Entries kept: {0}" -f ($names -join ' | '))

Assert-Case 'liveEntriesSurvive' (($names -contains '32.67 beta3') -and ($names -contains '32.67 beta18') -and ($names -contains '32.65 beta3')) `
    ("entries whose releases exist must be carried forward. Got: {0}" -f ($names -join ' | '))

# ---------------------------------------------------------------- 3. the newer copy wins
#
# Proved through the LINE, not just the name list: the surviving '32.67 beta1' must be the one whose
# versionCode is 2503. A name-only assertion cannot tell 2503 from 2483 - both are "32.67 beta1" - so
# this is checked on the text the block actually emits.

$withDuplicatesNoDead = @'
{
  "package": { "downloadUrl": "https://example/x.apk" },
  "32.67 beta1": {"versionCode": 2503, "changelog": ["the newer copy"]},
  "32.67 beta1": {"versionCode": 2483, "changelog": ["the older copy"]}
}
'@

$runnerNewer = [scriptblock]::Create(@'
$ErrorActionPreference = 'Stop'
function Write-Warn { param($m) }
function Write-Step { param($m) }
function Invoke-RestMethod {
    if ($null -eq $script:fakeTags) { throw 'list releases: simulated network failure' }
    return @($script:fakeTags | ForEach-Object { [pscustomobject]@{ tag_name = $_ } })
}
$script:fakeTags = $args[1]
$oldManifest = $args[0]
$VersionCode = 2506
'@ + "`n" + $block + "`n" + @'
foreach ($line in $kept) { Write-Output $line }
'@)

# flattened for the same reason as above: the earlier `,@($kept)` handed back one array inside another
#
# VersionCode 2506, not 2501. At 2501 the newer copy (2503) was DISCARDED by the "keep only what is
# older than the new release" rule before the duplicate logic ever saw it, so the survivor was 2483 -
# and the test reported that the production code kept the wrong one. It had kept the only one it was
# given. The case only means anything when both copies are genuinely carried forward.
$keptLines = @()
foreach ($item in @(& $runnerNewer $withDuplicatesNoDead @('v32.67-beta1'))) { $keptLines += $item }
$text = $keptLines -join "`n"

Assert-Case 'theNewerDuplicateSurvives' ($text -match '2503' -and $text -notmatch '2483') `
    ("the surviving copy must be the newer one (2503), since 2483 is a build that no longer exists. Kept: {0}" -f $text)

Assert-Case 'exactlyOneCopySurvives' ($keptLines.Count -eq 1) `
    ("expected 1 entry, got {0}: {1}" -f $keptLines.Count, $text)

# ---------------------------------------------------------------- 4. fail-safe toward keeping
#
# The dangerous direction. If the release list cannot be fetched, dropping entries would lose
# changelog history nobody can get back, while keeping a dead entry costs a misleading line in a
# list. So an unknown list must keep everything.

$namesFetchFailed = Invoke-EntrySelection -oldManifest $withDuplicates -VersionCode $newCode -TagFetchFails
$namesEmptyList = Invoke-EntrySelection -oldManifest $withDuplicates -VersionCode $newCode -knownTags @()

Assert-Case 'anUnfetchableListKeepsEntries' ($namesFetchFailed.Count -ge 5) `
    ("the release list failed to load, so nothing may be dropped: got {0} entries, {1}" -f `
     $namesFetchFailed.Count, ($namesFetchFailed -join ' | '))

Assert-Case 'anEmptyListIsNotTreatedAsKnowledge' ($namesEmptyList.Count -ge 5) `
    ("an empty list means 'could not tell', not 'nothing exists'. Kept {0}: {1}" -f `
     $namesEmptyList.Count, ($namesEmptyList -join ' | '))

# A truncated list - a full page back from the API - is the same danger with a different cause.
$tagsGuard = [regex]::Match($src, '(?s)\$tagCount = \$knownTags\.Count.*?if \(\$tagCount -ge (?<cap>\d+)\)')

Assert-Case 'aFullPageDisablesPruning' ($tagsGuard.Success) `
    ("the block must refuse to prune when the tag list came back full, because page 2 was not read. " +
     "Found: {0}" -f $(if ($tagsGuard.Success) { "cap $($tagsGuard.Groups['cap'].Value)" } else { 'nothing' }))

# The message must report the count it tested, not a variable that was just set to null.
$guardReadsLocal = ($null -ne $tagsGuard) -and $tagsGuard.Value -match '\$tagCount -ge'
Assert-Case 'theGuardCountsBeforeDiscarding' $guardReadsLocal `
    'the comparison must use the count taken first; reading $knownTags after setting it to $null prints a lie'

# ---------------------------------------------------------------- 5. entries at or above the new code
#
# A publish rewrites the manifest and adds the new version itself. Carrying an entry whose code is
# not older than the one being published would put the same code in the file twice.

$namesNewestFirst = Invoke-EntrySelection -oldManifest $withDuplicates -VersionCode 2505 -knownTags $allTags

Assert-Case 'anEntryAtTheNewCodeIsNotCarried' (-not ($namesNewestFirst -contains '32.67 beta3')) `
    ("2505 is the code being published, so the old entry for it must not be carried forward. Got: {0}" -f `
     ($namesNewestFirst -join ' | '))

# ---------------------------------------------------------------- 6. it has to parse

$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Case 'theScriptParses' ($parseErrors.Count -eq 0) `
    ("{0} parse error(s)" -f $parseErrors.Count)

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host 'all manifest keeping cases passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:failures) case(s) failed") -ForegroundColor Red
    exit 1
}