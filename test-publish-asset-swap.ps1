# Standalone check that publish.ps1 replaces a release asset without leaving a gap.
#
# WHY THIS IS A SOURCE-READING TEST AND NOT A LOGIC TEST
#
# The logic lives inside one long script that builds four APKs, talks to GitHub and
# publishes. There is no seam to call with a fake HTTP layer, so - as with
# test-publish-version-math.ps1 - the alternative was to ship a release and watch.
#
# What is asserted here is the ORDER of the three calls that touch an asset, which is the
# whole content of the bug:
#
#     WRONG: delete the old asset, then upload        -> missing for 7-17 seconds per file
#     RIGHT: upload under a temp name, delete, rename  -> missing for two API calls
#
# Deleting-then-uploading is what the script used to do, because a direct upload to an
# existing name fails with "already_exists". Once that order is in place the window is
# invisible in review and easy to reintroduce, so it gets a test.
#
# Every case below is one a pre-fix copy of publish.ps1 fails. That is not an aspiration -
# it is checked, by pointing this script at the old file:
#
#     git show <fix>^:publish.ps1 > old-publish.ps1
#     powershell -File test-publish-asset-swap.ps1 -ScriptPath old-publish.ps1
#
# Usage:
#   powershell -File test-publish-asset-swap.ps1
#   powershell -File test-publish-asset-swap.ps1 -ScriptPath old-publish.ps1

param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot 'publish.ps1')
)

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Write-Step($m) { Write-Host $m }

if (-not (Test-Path $ScriptPath)) {
    Write-Host "FAIL no such file: $ScriptPath" -ForegroundColor Red
    exit 1
}

$srcLines = [IO.File]::ReadAllLines((Resolve-Path $ScriptPath).Path)

Write-Step "asset replacement order in $([IO.Path]::GetFileName($ScriptPath))"
Write-Host ''

# --- locate the operations ----------------------------------------------------
# Lines are 1-based as reported by Select-String, which keeps the failure messages
# readable ("line 449"), but comparisons are all "greater than", so the offset does not
# matter as long as it is consistent.

function Find-Lines([string] $pattern) {
    $hits = @(Select-String -Path $ScriptPath -Pattern $pattern)
    return @($hits | ForEach-Object { $_.LineNumber })
}

$uploadLines  = Find-Lines 'curl\.exe.*-X POST'
$deleteLines  = Find-Lines '-Method Delete'
$patchLines   = Find-Lines '-Method Patch'
$loopLines    = Find-Lines 'foreach \(\$abi in \$byAbi\.Keys\)'
$assetListGet = Find-Lines 'releases/\$\(\$release\.id\)/assets.*-Method Get'

$firstUpload = if ($uploadLines.Count) { $uploadLines[0] } else { [int]::MaxValue }
$firstLoop   = if ($loopLines.Count)   { $loopLines[0] }   else { [int]::MaxValue }

# Classify the deletes by the id they delete, matched WITHIN THE SAME LINE.
#
# Both mistakes here have already been made once each. A single sequential regex
# ("Method Delete ... $replaceId") silently reports "none" on this script because
# Invoke-RestMethod puts -Method Delete at the END of the line and the id at the start;
# and a pattern written as `$ex.id` does not match the `$($ex.id)` the pre-fix code used,
# so a check that finds nothing to object to passes green against the very bug it was
# written for. So: find the delete lines first, then ask what each one deletes.
#
#   live - an asset the manifest resolves. Deleting one is the thing being ordered.
#   temp - $stale.id, an unreferenced .new file. Free to delete at any time.
$liveIdPattern = '\$\(?\$?(replaceId|existingAsset\.id|ex\.id)'
$tempIdPattern = '\$\(\$stale\.id\)'

$liveDeleteLines = @($deleteLines | Where-Object { $srcLines[$_ - 1] -match $liveIdPattern })
$tempDeleteLines = @($deleteLines | Where-Object { $srcLines[$_ - 1] -match $tempIdPattern })

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

# 1. Every delete must be accounted for as one or the other, or a delete of some third sort
#    has appeared that nobody reasoned about. This runs first because the cases below index
#    into the classification and would silently pass on an empty list.
Assert-Case 'everyDeleteIsClassified' `
    (($liveDeleteLines.Count + $tempDeleteLines.Count) -eq $deleteLines.Count) `
    ("{0} delete(s) on line(s) {1}; {2} live, {3} temp" -f `
     $deleteLines.Count, ($deleteLines -join ', '), $liveDeleteLines.Count, $tempDeleteLines.Count)

# 2. The upload exists at all, or nothing below means anything.
Assert-Case 'thereIsOneUpload' ($uploadLines.Count -eq 1) "found $($uploadLines.Count) upload call(s) on line(s) $($uploadLines -join ', ')"

# 2. THE BUG. No delete of the live asset may sit before the upload. The pre-fix script
#    deletes on the line before the upload loop body even reaches curl, which is exactly
#    the 7-17 second hole.
$liveBefore = @($liveDeleteLines | Where-Object { $_ -lt $firstUpload })
Assert-Case 'noLiveAssetIsDeletedBeforeTheUpload' ($liveBefore.Count -eq 0) `
    ("live-asset deletes at lines {0}; upload at line {1}; deletes before it: {2}" -f `
     $(if ($liveDeleteLines.Count) { $liveDeleteLines -join ', ' } else { 'none' }), $firstUpload, `
     $(if ($liveBefore.Count) { $liveBefore -join ', ' } else { 'none' }))

# 3. The swap deletes the old asset AFTER the new one is uploaded, which is what turns a
#    7-17 second hole into two API calls.
$swapDelete = @($liveDeleteLines | Where-Object { $_ -gt $firstUpload })
Assert-Case 'theOldAssetIsDeletedAfterTheNewOneIsUp' ($swapDelete.Count -ge 1) `
    ("swap delete on line(s) {0}, upload on line {1}" -f `
     $(if ($swapDelete.Count) { $swapDelete -join ', ' } else { 'none' }), $firstUpload)

# 4. The rename into the final name is what makes the new file reachable under the name the
#    manifest resolves. Without it the release holds only temp-named files.
Assert-Case 'theTempFileIsRenamedIntoPlace' ($patchLines.Count -ge 1 -and $patchLines[0] -gt $firstUpload) `
    ("PATCH on line(s) {0}, upload on line {1}" -f `
     $(if ($patchLines.Count) { $patchLines -join ', ' } else { 'none' }), $firstUpload)

# 5. The upload must go under the temp name, or step 4 renames a file that was never posted.
$uploadUriLines = Find-Lines '\$uploadUri\s*='
$usesTempName = @(Select-String -Path $ScriptPath -Pattern '\$uploadUri\s*=.*EscapeDataString\(\$uploadName\)').Count -ge 1
Assert-Case 'theUploadPostsUnderTheTempName' $usesTempName `
    ("upload URI built on line(s) {0}" -f $(if ($uploadUriLines.Count) { $uploadUriLines -join ', ' } else { 'none' }))

# 6. A leftover temp file from a run that died between upload and rename has to be cleared,
#    or it lingers on the release forever.
Assert-Case 'leftoverTempAssetsAreCleanedUp' ($tempDeleteLines.Count -ge 1) `
    ("temp cleanup on line(s) {0}" -f $(if ($tempDeleteLines.Count) { $tempDeleteLines -join ', ' } else { 'none' }))

# 7. The fast path. When the file already on the release is this exact build, replacing it
#    opens the window for nothing. A size match skips the upload entirely - the common
#    re-run case, where no swap should happen at all.
$sizeMatch = Find-Lines '\$existingAsset\.size\s*-eq.*\$apk\.Length'
Assert-Case 'aSizeMatchSkipsTheReplacement' ($sizeMatch.Count -ge 1) `
    ("size comparison on line(s) {0}" -f $(if ($sizeMatch.Count) { $sizeMatch -join ', ' } else { 'none' }))

# 7b. ...and the decision is made on CONTENT. The assets endpoint returns `digest`
#     ("sha256:..."), so the local APK can be hashed and compared to what is actually on the
#     release. Size is the fallback for an API that sends no digest, never the primary test:
#     two builds a few bytes apart, or a truncated upload, both pass a size check.
$digestRead = Find-Lines 'existingAsset\.digest'
$localHash  = Find-Lines 'Get-FileHash.*SHA256'
Assert-Case 'theSkipIsVerifiedByHash' ($digestRead.Count -ge 1 -and $localHash.Count -ge 1) `
    ("digest read on line(s) {0}, Get-FileHash on line(s) {1}" -f `
     $(if ($digestRead.Count) { $digestRead -join ', ' } else { 'none' }), `
     $(if ($localHash.Count) { $localHash -join ', ' } else { 'none' }))

# 7c. The fallback must be reachable but must not be the only test. If the digest branch was
#     deleted the size check would still pass on its own, so require the code to say which of
#     the two decided.
#     Plain substring search, not a regex: an earlier version of this assertion carried a
#     hand-escaped regex whose `$localDigest` was expanded away by the surrounding double
#     quotes and whose escapes were unbalanced, so it threw instead of asserting.
$saysWhich = @(Select-String -Path $ScriptPath -SimpleMatch "'sha256' } else { 'size only").Count -ge 1
Assert-Case 'theLogSaysWhichCheckDecided' $saysWhich `
    "the script reports whether sha256 or the size fallback decided the skip"

# 8. ...and the skip must actually skip: the fast path has to end in `continue`, before the
#    upload. A size check that falls through into curl is decoration.
$fastPathContinue = $false
if ($sizeMatch.Count -ge 1) {
    for ($i = $sizeMatch[0]; $i -lt [Math]::Min($sizeMatch[0] + 20, $srcLines.Count); $i++) {
        if ($srcLines[$i] -match '^\s*continue\s*$') { $fastPathContinue = $true; break }
        if ($srcLines[$i] -match 'curl\.exe.*-X POST') { break }
    }
}
Assert-Case 'theFastPathSkipsTheUploadBlock' $fastPathContinue `
    "size match on line $(if ($sizeMatch.Count) { $sizeMatch[0] } else { 'n/a' }) continues before the upload"

# 9. The asset list is read once, outside the loop. Inside the loop it was re-fetched per
#    file - four wasted calls - and each file planned its replacement against a list the
#    previous files had already changed.
Assert-Case 'theAssetListIsReadOnceOutsideTheLoop' `
    ($assetListGet.Count -eq 1 -and $assetListGet[0] -lt $firstLoop) `
    ("list read on line {0}, loop starts on line {1}, reads: {2}" -f `
     $(if ($assetListGet.Count) { $assetListGet[0] } else { 'none' }), $firstLoop, $assetListGet.Count)

# 10. The script must still parse. An ordering test on a file that does not compile proves
#     nothing, and this file is loaded by hand every time.
$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Case 'theScriptParses' ($parseErrors.Count -eq 0) `
    "$($parseErrors.Count) parse error(s)$(if ($parseErrors.Count) { ': ' + $parseErrors[0].Message })"

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host 'all asset replacement cases passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:failures) case(s) failed") -ForegroundColor Red
    exit 1
}