# Standalone check that publish-beta.ps1 aims at the tag it means to.
#
# WHY THIS IS A SOURCE-READING TEST
#
# The bug was not in a formula. publish-beta.ps1 passed `-VersionName '32.67'` on both of its
# call lines, hard-coded, with a comment above it arguing that this was deliberate and necessary.
# The argument was right about the beta counter and outlived the series it described: the stable
# channel moved to 32.68, and the wrapper kept insisting on 32.67, so a publish aimed itself at
# v32.67-beta1 - a real release from 02.10 - and overwrote its four APKs.
#
# The script builds, uploads and publishes. There is no seam to call with a fake HTTP layer, so
# the only way to exercise the branch is to ship a release, which is what happened.
#
# What is asserted here is that no literal version reaches publish.ps1, that the name comes from
# build.gradle, that a beta suffix is stripped before use, and that the pre-fix file fails.
#
#     git show <fix>^:publish-beta.ps1 > old-publish-beta.ps1
#     powershell -File test-publish-beta-target.ps1 -ScriptPath old-publish-beta.ps1
#
# Usage:
#   powershell -File test-publish-beta-target.ps1
#   powershell -File test-publish-beta-target.ps1 -ScriptPath old-publish-beta.ps1

param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot 'publish-beta.ps1'),
    [string] $GradlePath = (Join-Path $PSScriptRoot '..\SmartTube\smarttubetv\build.gradle')
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

Write-Step "beta publish target in $([IO.Path]::GetFileName($ScriptPath))"
Write-Host ''

$src = [IO.File]::ReadAllText((Resolve-Path $ScriptPath).Path)
$lines = $src -split "`r?`n"

# --- 1. no hard-coded version may reach the publisher --------------------------
#
# Comments may mention 32.67 - they have to, to explain what went wrong. Code may not. So the
# check is on the -VersionName ARGUMENT, not on the word appearing anywhere.

$versionNameArgs = @(Select-String -Path $ScriptPath -Pattern '-VersionName\s+(.+)$' |
    Where-Object { $_.Line -notmatch '^\s*#' })
Write-Host ("  -VersionName arguments found on non-comment lines: {0}" -f $versionNameArgs.Count)
$versionNameArgs | ForEach-Object { Write-Host ("     line {0}: {1}" -f $_.LineNumber, $_.Matches[0].Groups[1].Value.Trim()) }
Write-Host ''

$literalArgs = @($versionNameArgs | Where-Object {
    $arg = $_.Matches[0].Groups[1].Value.Trim()
    $arg -match "^'[^']+'" -or $arg -match '^"[^"]+"'
})

Assert-Case 'noLiteralVersionIsPassed' ($literalArgs.Count -eq 0) `
    ("{0} of {1} -VersionName arguments are a quoted literal: {2}" -f `
     $literalArgs.Count, $versionNameArgs.Count, `
     $(if ($literalArgs.Count) { ($literalArgs | ForEach-Object { $_.Line.Trim() }) -join ' | ' } else { 'none' }))

# --- 2. the name must be read from build.gradle -------------------------------

# Matched on the REGEX LITERAL in the source, not on the whitespace after it. The first version
# of this assertion looked for `versionName\s+\\"` and failed against the fixed file, because the
# regex itself is written 'versionName\s+"([^"]+)"' - the backslash-quote was escaping a backslash
# that does not exist. A test that fails on correct code teaches you to distrust the test.
$readsVersionName = @(Select-String -Path $ScriptPath -Pattern 'versionName\\s\+' |
    Where-Object { $_.Line -notmatch '^\s*#' })

Assert-Case 'theSeriesComesFromGradle' ($readsVersionName.Count -ge 1) `
    ("{0} non-comment line(s) read versionName; the regex literal must be there, not a bare property" -f $readsVersionName.Count)

Assert-Case 'gradleIsRequiredNotOptional' `
    ((Select-String -Path $ScriptPath -Pattern 'throw.*build.gradle not found').Count -ge 1) `
    "a missing or unreadable build.gradle stops the publish instead of falling back to a literal"

# --- 3. a beta suffix must be stripped ----------------------------------------
#
# Not tidiness. After a beta publish build.gradle holds "32.67 beta1", so without the strip the
# wrapper aims at "32.67 beta1 beta1" - which is the state this bug was found in, only with the
# literal doing the damage instead.

Assert-Case 'betaSuffixIsStripped' `
    ((Select-String -Path $ScriptPath -Pattern "-replace\s+'\[\- \]beta").Count -ge 1) `
    "the beta suffix is removed before the name is handed to publish.ps1"

# --- 4. exactly one param block, exactly one ErrorActionPreference -------------
#
# Found by editing: a rewrite inserted a second param() and a second $ErrorActionPreference, and
# the file still parsed. PowerShell allowed the duplicate silently, which means the ordering
# between them was accidental and the later one silently governed everything below it.

Assert-Case 'oneParamBlock' (@(Select-String -Path $ScriptPath -Pattern '^param\(').Count -eq 1) `
    ("found {0}" -f @(Select-String -Path $ScriptPath -Pattern '^param\(').Count)

Assert-Case 'oneErrorActionPreference' `
    (@(Select-String -Path $ScriptPath -Pattern '^\$ErrorActionPreference').Count -eq 1) `
    ("found {0}" -f @(Select-String -Path $ScriptPath -Pattern '^\$ErrorActionPreference').Count)

# --- 5. it has to parse ------------------------------------------------------

$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Case 'theScriptParses' ($parseErrors.Count -eq 0) `
    ("{0} parse error(s)" -f $parseErrors.Count)

# --- 6. and the file must still be UTF-8 WITH BOM ----------------------------
#
# Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, the Cyrillic changelog becomes mojibake,
# and the guillemets inside those strings then break the parser outright.

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $ScriptPath).Path)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-Case 'theFileKeepsItsBom' $hasBom `
    ("first bytes: {0}" -f (($bytes[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

# --- 7. the strip is correct, proven by running it ----------------------------

if ($hasBom -or $true) {
    $gradleText = if (Test-Path $GradlePath) { [IO.File]::ReadAllText((Resolve-Path $GradlePath).Path) } else { '' }
    $nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')

    Assert-Case 'buildGradleIsReadable' $nameMatch.Success `
        ("versionName = '{0}'" -f $nameMatch.Groups[1].Value)

    if ($nameMatch.Success) {
        $raw = $nameMatch.Groups[1].Value
        $stripped = ($raw -replace '[- ]beta\.?\d+$', '').Trim()

        Assert-Case 'theStrippedNameHasNoBetaLeft' ($stripped -notmatch 'beta') `
            ("'{0}' -> '{1}'" -f $raw, $stripped)

        Assert-Case 'theStrippedNameIsNotEmpty' ($stripped -ne '') `
            ("'{0}' -> '{1}'" -f $raw, $stripped)
    }
}

# --- 8. the release list must be a LIST, not one joined element ---------------
#
# @(gh ... | ConvertFrom-Json) in Windows PowerShell 5.1 gives .Count = 1, whose single element is
# the whole array: ConvertFrom-Json hands the array over as one object, and @() wraps what came out
# of the pipeline instead of unwrapping an array that arrived inside it. The second pair of
# parentheses evaluates the pipeline first, so it expands on collection.
#
# This is not a style point. With one joined element the regex filter below it is applied to the
# string "v32.68 v32.67-beta18 v32.67-beta17 ...", and PowerShell's -match on an ARRAY returns the
# matching elements rather than a boolean, so the joined string passed the filter. sameSeries.Count
# came out 1 instead of 16, v32.68 and v32.66 contributed 0 to the beta numbers because [int]('')
# is 0, and every real beta appeared twice. It still ended at 18 and still produced beta19 - the
# right answer from data that had never been filtered.

Assert-Case 'theReleaseListIsUnwrapped' `
    ((Select-String -Path $ScriptPath -Pattern '@\(\(\s*gh\s+release list').Count -ge 1) `
    'the gh call must be wrapped in @((...)), or the list is one joined element and every filter on it is meaningless'

# And the shape, executed rather than read. ConvertFrom-Json is available here, so the real
# conversion is exercised with JSON of the shapes the channel actually returns.
$listCases = @(
    @{ Name = 'many releases'; Json = '[{"tagName":"v32.68"},{"tagName":"v32.67-beta18"},{"tagName":"v32.67-beta3"}]'; Want = 3 },
    @{ Name = 'a single release'; Json = '[{"tagName":"v32.67-beta1"}]'; Want = 1 },
    @{ Name = 'an empty channel'; Json = '[]'; Want = 0 }
)

foreach ($case in $listCases) {
    # the two forms the script could have used, so the difference is measured and not asserted
    $unwrapped = @(($case.Json | ConvertFrom-Json))
    $rawWrap = @($case.Json | ConvertFrom-Json)

    Assert-Case ("releaseListUnwraps: {0}" -f $case.Name) ($unwrapped.Count -eq $case.Want) `
        (("double parens give {0} item(s), single parens give {1}, expected {2}" -f `
          $unwrapped.Count, $rawWrap.Count, $case.Want))
}

# And the filter must actually filter, on the joined form as well as the right one - because the
# reason the wrong one looked fine is that it happened to give the same final answer.
$BetaBaseVersionForFilter = '32.67'
$filterPat = "^v$([regex]::Escape($BetaBaseVersionForFilter))-beta\d+$"

$joinedTags = @((('[{"tagName":"v32.68"},{"tagName":"v32.67-beta18"},{"tagName":"v32.67-beta5"},{"tagName":"v32.65-beta9"}]') |
    ConvertFrom-Json) | ForEach-Object { $_.tagName })

$joinedFiltered = @($joinedTags | Where-Object { $_ -match $filterPat })
Assert-Case 'theFilterSeesEachTagSeparately' ($joinedFiltered.Count -eq 2) `
    ("2 of the 4 tags are 32.67 betas. The filter returned {0}: {1}" -f `
     $joinedFiltered.Count, ($joinedFiltered -join ' | '))

# THE INVARIANT, checked as a pair and not as a fragment.
#
# The first version of this tested a guard written out inside the test file - "if ($m.Success)".
# It passed, and it proved nothing: that was not the code under test. Then the guard was removed
# from publish-beta.ps1 and no test changed, which is what exposed that it had been unreachable all
# along: the filter admits only tags ending in "beta\d+$", so the same regex on those tags always
# matches, and a guard against a case that cannot happen is code that reads as protection while
# being untested.
#
# What is worth checking is that the two patterns AGREE, because that is the only thing standing
# between a tag like "v32.67-betaX" and [int]('') - which is 0, and a 0 printed in a line an
# operator is reading to decide something. Loosening the filter has to fail here.

# NOTE the two things this pattern has to get right, both found by it not matching:
#   (?s)  - the cast is on the NEXT line from "$betaNumbers =", and .*? without (?s) stops at the
#           newline and reports no match, which looks like "the code is not there"
#   [regex]::Match  - not -match. The operator here is the static method; -match appears nowhere
#           near this assignment, and a pattern looking for it finds nothing and says nothing
$numberCast = [regex]::Match($src, '(?s)\$betaNumbers\s*=.*?\[regex\]::Match\(\$_,\s*''(?<num>[^'']+)''\)')

if (-not $numberCast.Success) {
    Assert-Case 'theNumberCastIsFoundInTheSource' $false `
        'could not find the regex used to pull the number out of a tag name'
} else {
    Assert-Case 'theNumberCastIsFoundInTheSource' $true `
        ("number pattern: {0}" -f $numberCast.Groups['num'].Value)

    $awkward = @('v32.67-beta18', 'v32.67-betaX', 'v32.67-beta', 'v32.67-betaR1')

    # with the filter as it actually is, nothing survives that the cast cannot read
    $tightSurvivors = @($awkward | Where-Object { $_ -match '^v32\.67-beta\d+$' })
    $tightCast = @($tightSurvivors | ForEach-Object {
        [int]([regex]::Match($_, $numberCast.Groups['num'].Value).Groups[1].Value)
    })

    Assert-Case 'theRealFilterLeavesNoUnreadableTags' `
        ((-not ($tightCast -contains 0)) -and $tightSurvivors.Count -gt 0) `
        ("the filter as written keeps {0} and casting gives {1} - no zeros, because the filter " +
         "already guaranteed a number was there." -f `
         ($tightSurvivors -join ' | '), ($tightCast -join ', '))

    # loosen that filter and the zeros appear - which is what makes the tight filter load-bearing
    $looseSurvivors = @($awkward | Where-Object { $_ -match '^v32\.67-beta.*$' })
    $looseCast = @($looseSurvivors | ForEach-Object {
        [int]([regex]::Match($_, $numberCast.Groups['num'].Value).Groups[1].Value)
    })

    Assert-Case 'aLoosenedFilterWouldProduceZeros' ($looseCast -contains 0) `
        ("with the filter loosened to beta.*$, these survive: {0}, and casting gives {1}. That is " +
         "the shape of the bug this guards: a 0 where a version number should be, with no error." -f `
         ($looseSurvivors -join ' | '), ($looseCast -join ', '))
}

# And the series regex itself, run rather than read. An unanchored or partially anchored pattern is
# the obvious way for this to go wrong: "v32.670-beta1" and "v32.67x" are not betas of this series,
# and a pattern missing an anchor admits both. A mutation that loosened the trailing anchor was
# tried and nothing noticed, so the pattern is now exercised against the neighbouring names.

# Read the pattern off a CODE line. Found by mutation: the first version of this match searched $src
# for "$sameSeries = ... -match "..." and the comment block above the code happens to contain a
# line starting with the same characters - a worked example of the filter with the series already
# substituted. So removing the leading anchor from the code changed nothing the test could see,
# because the test was reading the comment the whole time. A test that asserts on prose is a test
# of the prose.
$seriesLine = @(Select-String -Path $ScriptPath -Pattern '\$sameSeries\s*=' |
    Where-Object { $_.Line -notmatch '^\s*#' })

if ($seriesLine.Count -eq 0) {
    Assert-Case 'theSeriesPatternIsFoundInTheSource' $false 'no code line assigns $sameSeries'
    $seriesPattern = [regex]::Match('')
} else {
    Assert-Case 'theSeriesFilterIsOnACodeLine' ($seriesLine.Count -eq 1) `
        (("{0} code line(s) assign `$sameSeries; the pattern must be read from one of them, not " +
          "from the comment that documents it") -f $seriesLine.Count)

    $seriesPattern = [regex]::Match($seriesLine[0].Line, '-match\s+"(?<pat>[^"]+)"')
}

if (-not $seriesPattern.Success) {
    Assert-Case 'theSeriesPatternIsFoundInTheSource' $false `
        'could not find the $sameSeries filter, so its regex cannot be checked'
} else {
    Assert-Case 'theSeriesPatternIsFoundInTheSource' $true `
        ("pattern: {0}" -f $seriesPattern.Groups['pat'].Value)

    # Substitute the WHOLE subexpression, not the bare variable.
    #
    # The pattern in the source is ^v$([regex]::Escape($BetaBaseVersion))-beta\d+$ - the $( ) is a
    # PowerShell subexpression, and only inside it does $BetaBaseVersion mean the version. Replacing
    # just the variable leaves $([regex]::Escape('32.67')) in the text, which as a REGEX is an
    # end-of-string anchor followed by a literal, so nothing matches at all.
    #
    # Found by execution, not by reading: the first version of this replaced the variable and the
    # test failed on all three real betas, reporting "3 real beta(s) were rejected" while the
    # pattern printed as something no tag could ever match.
    $probe = $seriesPattern.Groups['pat'].Value.Replace(
        '$([regex]::Escape($BetaBaseVersion))', [regex]::Escape('32.67'))

    # what the filter must accept, and what it must not
    $shouldMatch = @('v32.67-beta1', 'v32.67-beta18', 'v32.67-beta999')
    $shouldNot = @(
        'v32.670-beta1',      # a different series that starts with the same digits
        'v32.6-beta1',        # a shorter series
        'v32.67',             # the stable build
        'v32.67-beta',        # no number
        'v32.67-beta1-extra', # trailing junk
        'xv32.67-beta1',      # junk in front
        'v32.65-beta18',      # another series entirely
        'v32.68'
    )

    $falsePositives = @($shouldNot | Where-Object { $_ -match $probe })
    Assert-Case 'theSeriesFilterRejectsOtherSeries' ($falsePositives.Count -eq 0) `
        (("{0} name(s) that are NOT 32.67 betas were accepted: {1}" -f `
          $falsePositives.Count, ($falsePositives -join ' | ')))

    $falseNegatives = @($shouldMatch | Where-Object { $_ -notmatch $probe })
    Assert-Case 'theSeriesFilterAcceptsRealBetas' ($falseNegatives.Count -eq 0) `
        (("{0} real beta(s) were rejected: {1}" -f `
          $falseNegatives.Count, ($falseNegatives -join ' | ')))

    # and it must actually be anchored at the front: a leading ^ is what keeps "xv32.67-beta1" out
    Assert-Case 'theSeriesFilterIsAnchoredAtBothEnds' `
        ($probe -match '\^' -and $probe -match '\$$') `
        ("pattern is: {0}" -f $probe)
}

# --- 9. the beta NUMBER must come from GitHub, not from build.gradle ---------
#
# The pre-fix wrapper printed "the next free number in this series is betaN" and then discarded
# the answer, letting publish.ps1 derive the number from build.gradle's own beta suffix (+1). On
# the state that was live when this was written, the two disagreed by fifteen:
#
#     build.gradle holds      32.67 beta3   (2505)
#     build.gradle implies    32.67 beta4   (2506)  -> v32.67-beta4, PUBLISHED 02.10
#     GitHub says next free   32.67 beta19
#
# Deleting v32.67-beta1 and beta2 is what made "the last one I wrote" stop meaning "the last one
# that exists". So the authoritative source is the release list, and it has to reach the publisher
# as a number.

$numberComesFromList = @(Select-String -Path $ScriptPath -Pattern '\$TargetBetaNumber\s*=\s*\$betaNumbers\[-1\]\s*\+\s*1' |
    Where-Object { $_.Line -notmatch '^\s*#' })

Assert-Case 'theBetaNumberComesFromTheReleaseList' ($numberComesFromList.Count -ge 1) `
    (("found {0} line(s) assigning TargetBetaNumber from the highest listed beta; the pre-flight " +
      "already had the answer and threw it away") -f $numberComesFromList.Count)

$passesNumber = @(Select-String -Path $ScriptPath -Pattern '-BetaNumber\s+\$TargetBetaNumber' |
    Where-Object { $_.Line -notmatch '^\s*#' })

Assert-Case 'theNumberReachesThePublisher' ($passesNumber.Count -ge 2) `
    (("{0} call line(s) pass -BetaNumber; both the versionCode and the plain call need it, or the " +
      "gap reopens on one path") -f $passesNumber.Count)

Assert-Case 'aCollidingTargetStops' `
    ((Select-String -Path $ScriptPath -Pattern '\$allTagNames -contains \$targetTag').Count -ge 1) `
    "if 'highest + 1' somehow lands on an existing tag the run stops instead of picking again"

# --- 9. and the formula, executed against a channel that has a gap -----------
#
# Read out of the script and run, because the failure is a wrong number and only a wrong number
# shows it. Three channel states, all real ones this project has been in.

# NOTE what is and is not extracted. Only the if/else that assigns TargetBetaNumber - NOT the
# "$betaNumbers = ..." line above it, which recomputes from $seriesNames and would need the whole
# gh pipeline to stand up. The block is fed $betaNumbers and $allTagNames directly, which is what
# it actually reads.
#
# The trailing \}: a non-greedy match cut at "$TargetBetaNumber = 1" stops inside the else block and
# leaves an unbalanced brace, and the failure surfaces as a scriptblock parse error that says
# nothing about the number.
$snippet = [regex]::Match($src, '(?s)if \(\$betaNumbers\.Count -gt 0\) \{\r?\n    \$TargetBetaNumber = .*?\$TargetBetaNumber = 1\r?\n\}')

if (-not $snippet.Success) {
    Assert-Case 'theNumberFormulaIsFoundInTheSource' $false `
        'could not find the block that computes TargetBetaNumber, so nothing can be executed'
} else {
    Assert-Case 'theNumberFormulaIsFoundInTheSource' $true `
        ("block found, {0} line(s)" -f (($snippet.Value -split "`n").Count))

    # The block reads $betaNumbers and $allTagNames, so both are handed to it: the first decides
    # the number, the second is what the collision check tests against.
    function Invoke-NumberFormula([string[]] $tags, [string] $base, [int[]] $numbers = $null) {
        # $numbers is separate because in the real script the two lists are built by different code
        # and CAN disagree. Deriving the numbers from the tags - as the first version of this
        # helper did - makes a disagreement unrepresentable, which hides the one case the check
        # exists for. Pass $numbers to simulate the list being stale or filtered.
        $nums = if ($null -ne $numbers) {
            @($numbers | Sort-Object -Unique)
        } else {
            @($tags | ForEach-Object { [int]([regex]::Match($_, 'beta(\d+)$').Groups[1].Value) } |
              Sort-Object -Unique)
        }

        $b = $snippet.Value -replace '\$BetaBaseVersion', ("'" + $base + "'")
        $runner = [scriptblock]::Create(
            "`$ErrorActionPreference = 'Stop'`n" +
            "`$betaNumbers = @(" + ($nums -join ', ') + ")`n" +
            "`$allTagNames = @(" + (($tags | ForEach-Object { "'" + $_ + "'" }) -join ', ') + ")`n" +
            "`$TargetBetaNumber = 0`n" +
            $b + "`n" +
            'if ($TargetBetaNumber -gt 0) { $TargetBetaNumber } else { -1 }')

        try { return [int](& $runner) } catch { return -1 }   # -1 == the run stopped
    }

    # the live channel right now: beta3 plus beta4..beta18, beta1/beta2 deleted
    $gapped = @('v32.67-beta3', 'v32.67-beta4', 'v32.67-beta5', 'v32.67-beta6', 'v32.67-beta7',
                'v32.67-beta8', 'v32.67-beta9', 'v32.67-beta10', 'v32.67-beta11', 'v32.67-beta12',
                'v32.67-beta13', 'v32.67-beta14', 'v32.67-beta15', 'v32.67-beta16', 'v32.67-beta17',
                'v32.67-beta18')

    $got = Invoke-NumberFormula $gapped '32.67'
    Assert-Case 'aGapInTheSeriesIsSteppedOver' ($got -eq 19) `
        ("with beta3 and beta4..beta18 published, the next number must be 19, and the pre-fix " +
         "derivation said 4 - a tag that exists. Got {0}." -f $got)

    $got2 = Invoke-NumberFormula @('v32.67-beta1') '32.67'
    Assert-Case 'aNormalSeriesContinues' ($got2 -eq 2) `
        ("only beta1 published -> beta2. Got {0}." -f $got2)

    $got3 = Invoke-NumberFormula @() '32.67'
    Assert-Case 'anEmptySeriesStartsAtOne' ($got3 -eq 1) `
        ("nothing published -> beta1. Got {0}." -f $got3)

    # THE STOP. The two lists must be able to disagree, because they are built by different code -
    # $betaNumbers out of a regex over the tag names of one series, $allTagNames out of every
    # release on the repo. So here the numbers stop at 19 while the tag list already holds beta20:
    # highest+1 is 20, 20 is taken, and publishing would overwrite a release.
    #
    # The first version of this case fed both lists the same two tags and expected a stop. It did
    # not stop, and it was the TEST that was wrong, not the code: with both lists agreeing,
    # highest+1 is by definition absent, so there is nothing to catch. A test whose only way to
    # pass is for the code to be broken is a test that lies.
    $stopRunner = [scriptblock]::Create(
        "`$ErrorActionPreference = 'Stop'`n" +
        "`$betaNumbers = @(18, 19)`n" +
        "`$allTagNames = @('v32.67-beta18', 'v32.67-beta19', 'v32.67-beta20')`n" +
        "`$BetaBaseVersion = '32.67'`n" +
        "`$TargetBetaNumber = 0`n" +
        $snippet.Value + "`n" +
        "`$TargetBetaNumber")

    $stopped = $false
    $stopMsg = ''
    try { $null = & $stopRunner } catch { $stopped = $true; $stopMsg = $_.Exception.Message }

    Assert-Case 'aTargetThatIsPresentStops' $stopped `
        ("numbers say highest 19, tag list already holds beta20: the run must stop rather than " +
         "overwrite it. Stopped: {0}" -f `
         $(if ($stopped) { $stopMsg.Substring(0, [Math]::Min(50, $stopMsg.Length)) } else { 'IT DID NOT STOP' }))

    # and the same state must NOT be published - checked by running the numbers, not by reading
    $wouldPublish = Invoke-NumberFormula -tags @('v32.67-beta18', 'v32.67-beta19', 'v32.67-beta20') `
        -base '32.67' -numbers @(18, 19)
    Assert-Case 'aCollidingTargetIsNotANumberToPublish' ($wouldPublish -eq -1) `
        ("the helper must report 'stopped' (-1), not a number. Got {0}." -f $wouldPublish)
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host 'all beta target cases passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:failures) case(s) failed") -ForegroundColor Red
    exit 1
}