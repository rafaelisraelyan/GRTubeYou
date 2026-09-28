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

    [int] $BetaNumber = 0
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

if ($VersionCode -le 0) { $VersionCode = $oldCode + 1 }

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

if ($Beta) {
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
    $VersionName = "$VersionName beta$BetaNumber"
    Write-Ok "beta build, release will be a GitHub prerelease"
}

# URL/CLI safe form of the version, e.g. "32.65 beta1" -> "32.65-beta1"
$safeVersion = $VersionName -replace '\s+', '-'

# Stable build wrote $VersionName before the beta suffix, so re-apply it to the
# gradle file (section 2 runs after this).

# --------------------------------------------- 2. write version into gradle
Write-Step "Updating versionCode/versionName in build.gradle"
$gradleText = [regex]::Replace($gradleText, 'versionCode\s+\d+', "versionCode $VersionCode")
$gradleText = [regex]::Replace($gradleText, 'versionName\s+"[^"]+"', "versionName `"$VersionName`"")
[System.IO.File]::WriteAllText($buildGradle, $gradleText)

# ------------------------------------------------------------------ 3. build
$apkDir = Join-Path $ProjectPath 'smarttubetv\build\outputs\apk\ststable\release'

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
$byAbi = @{}
foreach ($apk in $apks) {
    $abi = 'universal'
    if ($apk.Name -match '_(arm64-v8a|armeabi-v7a|x86_64|x86)\.apk$') { $abi = $Matches[1] }
    $byAbi[$abi] = $apk
    Write-Ok "$abi -> $($apk.Name)"
}
if (-not $byAbi.ContainsKey('universal')) { Fail "universal APK is missing" }
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
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $httpCode = & curl.exe -s -o $tmpOut -w '%{http_code}' -X POST `
        -H "Authorization: token $env:GITHUB_TOKEN" `
        -H "Content-Type: application/octet-stream" `
        --data-binary "@$($apk.FullName)" `
        --max-time 900 `
        $uploadUri
    $respBody = if (Test-Path $tmpOut) { [System.IO.File]::ReadAllText($tmpOut) } else { '' }
    Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue

    if ($httpCode -ne '201' -and $httpCode -ne '200') {
        Fail "Upload of $assetName failed with HTTP $httpCode : $respBody"
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

# ---------------------------------------------------------------- 8. summary
Write-Host ''
Write-Step "Done"
Write-Host "  Release:  https://github.com/$Owner/$Repo/releases/tag/$tag"
# The manifest name depends on the channel - printing version.json during a beta
# publish sent me looking at the wrong file.
Write-Host "  Manifest: https://raw.githubusercontent.com/$Owner/$Repo/main/$manifestName"
Write-Host "  Next:     commit and push $manifestName in $DistPath"
Write-Host ''
Write-Host "  The app only sees a new version once $manifestName is on the default branch." -ForegroundColor Yellow
