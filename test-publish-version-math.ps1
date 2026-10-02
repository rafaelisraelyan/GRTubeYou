# Standalone check of the version arithmetic in publish.ps1.
#
# It is reproduced here rather than called from the script itself because the script
# builds, uploads and publishes - the only way to exercise a branch is to ship a release.
# The logic below is copied verbatim from publish.ps1 sections 0 and 1b, with the
# gradle values passed in instead of parsed out of build.gradle.
#
# Usage: test-version-math.ps1

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Fail($msg) { throw $msg }
function Write-Step($m) { Write-Host $m }
function Write-Ok($m) { Write-Host "  ok: $m" }

# --- verbatim from publish.ps1 ---------------------------------------------
function Get-PublishVersion {
    param(
        [string] $oldName,
        [int]    $oldCode,
        [string] $VersionName,
        [int]    $VersionCode,
        [bool]   $Beta,
        [int]    $BetaNumber,
        [bool]   $Resume
    )

    if ($Resume) {
        $VersionCode = $oldCode
        $VersionName = $oldName
    } elseif ($VersionCode -le 0) {
        $VersionCode = $oldCode + 1
    }

    $explicitVersion = [bool]$VersionName
    $oldBaseName = $oldName -replace '[- ]beta\.?\d+$', ''

    if (-not $VersionName) {
        $baseName = $oldBaseName
        $parts = $baseName -split '\.'
        if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') {
            $VersionName = "$($parts[0]).$([int]$parts[1] + 1)"
        } else {
            $VersionName = $baseName + '.' + $VersionCode
        }
    }

    if ($Beta -and $Resume) {
        $resumedBeta = [regex]::Match($VersionName, '[- ]beta\.?(\d+)$')
        if ($resumedBeta.Success) {
            $BetaNumber = [int]$resumedBeta.Groups[1].Value
        } else {
            Fail "-Resume was given but the version in build.gradle is not a beta ('$VersionName')"
        }
    } elseif ($Beta) {
        if ($BetaNumber -le 0) {
            $oldBeta = [regex]::Match($oldName, '[- ]beta\.?(\d+)$')
            if (-not $explicitVersion -or $VersionName -ne $oldBaseName) {
                $BetaNumber = 1
            } elseif ($oldBeta.Success) {
                $BetaNumber = [int]$oldBeta.Groups[1].Value + 1
            } else {
                $BetaNumber = 1
            }
        }
        if (-not $Resume) {
            $VersionName = "$VersionName beta$BetaNumber"
        }
    }

    $safeVersion = $VersionName -replace '\s+', '-'
    return [pscustomobject]@{ VersionName = $VersionName; VersionCode = $VersionCode; Tag = "v$safeVersion" }
}

# --- harness ---------------------------------------------------------------
$cases = @(
    @{ Name = 'beta, base given, continues counter'; Args = @{ oldName='32.67 beta2'; oldCode=2484; VersionName='32.67'; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$false }; Want = @{ VersionName='32.67 beta3'; VersionCode=2485; Tag='v32.67-beta3' } }
    # With no explicit name the base advances, and because the base changed the beta counter
    # deliberately restarts at 1. Restarting is safe here precisely because the tag differs -
    # the old "default to 1" bug was reusing v32.65-beta1 and overwriting a live beta.
    @{ Name = 'beta, no name, base advances so counter restarts'; Args = @{ oldName='32.67 beta2'; oldCode=2484; VersionName=''; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$false }; Want = @{ VersionName='32.68 beta1'; VersionCode=2485; Tag='v32.68-beta1' } }
    @{ Name = 'stable, no name, bumps base'; Args = @{ oldName='32.66'; oldCode=2480; VersionName=''; VersionCode=0; Beta=$false; BetaNumber=0; Resume=$false }; Want = @{ VersionName='32.67'; VersionCode=2481; Tag='v32.67' } }
    @{ Name = 'stable after beta, drops beta suffix and bumps'; Args = @{ oldName='32.66 beta3'; oldCode=2484; VersionName=''; VersionCode=0; Beta=$false; BetaNumber=0; Resume=$false }; Want = @{ VersionName='32.67'; VersionCode=2485; Tag='v32.67' } }

    # The whole point of -Resume: reuse 2485 instead of stepping to 2486, and do not
    # turn "32.67 beta3" into "32.67 beta3 beta1".
    @{ Name = 'resume beta reuses number, no double suffix'; Args = @{ oldName='32.67 beta3'; oldCode=2485; VersionName='32.67'; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$true }; Want = @{ VersionName='32.67 beta3'; VersionCode=2485; Tag='v32.67-beta3' } }
    @{ Name = 'resume beta4 keeps beta4'; Args = @{ oldName='32.67 beta4'; oldCode=2486; VersionName='32.67'; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$true }; Want = @{ VersionName='32.67 beta4'; VersionCode=2486; Tag='v32.67-beta4' } }
    @{ Name = 'resume stable keeps version'; Args = @{ oldName='32.67'; oldCode=2486; VersionName=''; VersionCode=0; Beta=$false; BetaNumber=0; Resume=$true }; Want = @{ VersionName='32.67'; VersionCode=2486; Tag='v32.67' } }

    # Regression: a fresh beta must still advance, i.e. -Resume did not break the normal path.
    @{ Name = 'fresh beta from beta4 advances to beta5'; Args = @{ oldName='32.67 beta4'; oldCode=2486; VersionName='32.67'; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$false }; Want = @{ VersionName='32.67 beta5'; VersionCode=2487; Tag='v32.67-beta5' } }
)

foreach ($c in $cases) {
    # Splatting needs a variable, not an expression: `@($c.Args)[0]` would pass the whole
    # hashtable as the first positional argument and $oldName would become a hashtable.
    $params = $c.Args
    try {
        $got = Get-PublishVersion @params
    } catch {
        Write-Host ("FAIL {0}" -f $c.Name) -ForegroundColor Red
        Write-Host ("     threw: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:failures++
        continue
    }

    $bad = @()
    foreach ($k in 'VersionName', 'VersionCode', 'Tag') {
        if ("$($got.$k)" -ne "$($c.Want.$k)") { $bad += ("{0}: got '{1}' want '{2}'" -f $k, $got.$k, $c.Want[$k]) }
    }

    if ($bad.Count -eq 0) {
        Write-Host ("pass {0}" -f $c.Name) -ForegroundColor Green
        Write-Host ("       -> {0} (code {1}, {2})" -f $got.VersionName, $got.VersionCode, $got.Tag) -ForegroundColor DarkGray
    } else {
        Write-Host ("FAIL {0}" -f $c.Name) -ForegroundColor Red
        foreach ($b in $bad) { Write-Host ("     {0}" -f $b) -ForegroundColor Red }
        $script:failures++
    }
}

# -Resume must refuse a non-beta name rather than shipping something confusing.
try {
    $resumeStableParams = @{ oldName='32.67'; oldCode=2486; VersionName='32.67'; VersionCode=0; Beta=$true; BetaNumber=0; Resume=$true }
    $null = Get-PublishVersion @resumeStableParams
    Write-Host "FAIL resume of a stable version with -Beta was allowed" -ForegroundColor Red
    $script:failures++
} catch {
    Write-Host "pass resume of a stable version with -Beta is refused" -ForegroundColor Green
    Write-Host ("       -> {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "all version arithmetic cases passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("{0} case(s) failed" -f $script:failures) -ForegroundColor Red
    exit 1
}