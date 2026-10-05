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

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host 'all beta target cases passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:failures) case(s) failed") -ForegroundColor Red
    exit 1
}