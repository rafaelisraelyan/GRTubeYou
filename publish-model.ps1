<#
.SYNOPSIS
    Publishes the offline speech model to GitHub Releases and writes the manifest
    the app reads (voice-model.json).

.DESCRIPTION
    The model is a third-party artifact (Vosk, Apache-2.0) of ~44 MB, kept out of
    the apk on purpose: bundling it would add 44 MB to every one of the four
    per-abi builds. The app downloads it in the background on first run.

    The release is NOT a prerelease and has no connection to the app versions in
    publish.ps1 - it is tagged voice-ru-<version> so a model can be replaced
    without touching the app's version numbering.

.PARAMETER ZipPath
    Path to vosk-model-small-ru-0.22.zip (or any vosk model zip).

.PARAMETER Version
    Model version, e.g. 0.22.

.EXAMPLE
    .\publish-model.ps1 -ZipPath .\model\vosk-model-small-ru-0.22.zip -Version 0.22
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $ZipPath,

    [Parameter(Mandatory = $true)]
    [string] $Version,

    [string] $Owner = 'rafaelisraelyan',

    [string] $Repo = 'GRTubeYou',

    [string] $DirName = '',

    [string] $Language = 'ru',

    [string] $DistPath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }
function Fail($msg) { throw $msg }

if (-not (Test-Path $ZipPath)) { Fail "Not found: $ZipPath" }

if (-not $env:GITHUB_TOKEN) {
    $ghExe = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghExe) {
        $ghExe = @(
            "$env:ProgramFiles\GitHub CLI\gh.exe",
            "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
            "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if ($ghExe) {
        # Get-Command returns a CommandInfo (has .Source), the fallback yields a
        # plain string (does not). Under StrictMode reading .Source off a string
        # is a hard error, so normalise first.
        $ghPath = if ($ghExe -is [string]) { $ghExe } else { $ghExe.Source }
        $token = & $ghPath auth token 2>$null | Select-Object -First 1
        if ($token) { $env:GITHUB_TOKEN = "$token".Trim() }
    }

    if (-not $env:GITHUB_TOKEN) { Fail 'No GitHub credentials. Run "gh auth login" first.' }
}

$apiBase = 'https://api.github.com'
$headers = @{
    'Authorization' = "token $env:GITHUB_TOKEN"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'GRTubeYou-model-publisher'
}

if (-not $DirName) { $DirName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath) }

Write-Step 'Reading the archive'
$size = (Get-Item $ZipPath).Length
$sha = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLower()
Write-Ok "$DirName - $([math]::Round($size/1MB,1)) MB"
Write-Ok "sha256 $sha"

# The app looks for <dirName>/am/final.mdl after unpacking, so verify the archive
# really has it before publishing a model that cannot be loaded.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath))
try {
    $hasModel = [bool]($zip.Entries | Where-Object { $_.FullName -eq "$DirName/am/final.mdl" })
    $rootDirs = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+/$' } | Select-Object -ExpandProperty FullName)
} finally {
    $zip.Dispose()
}

if (-not $hasModel) {
    Write-Warn "The archive has no $DirName/am/final.mdl - the app will not be able to load it."
    Write-Warn "Top level folders: $($rootDirs -join ', ')"
} else {
    Write-Ok 'archive layout matches dirName'
}

$assetName = [System.IO.Path]::GetFileName($ZipPath)
$tag = "voice-ru-$Version"

Write-Step "Creating release $tag"
$body = @{
    tag_name    = $tag
    name        = "Voice model $Language $Version"
    body        = "Offline speech model (`$DirName`), fetched by the app on first run.`n`nSource: https://alphacephei.com/vosk/models`nLicense: Apache-2.0`n`nNot an app release - see publish.ps1 for those."
    prerelease  = $false
} | ConvertTo-Json

$response = $null
try {
    $response = Invoke-RestMethod -Method Post -Uri "$apiBase/repos/$Owner/$Repo/releases" `
        -Headers $headers -Body $body -ContentType 'application/json'
    Write-Ok "release $tag created (id $($response.id))"
} catch {
    # -ErrorAction does not help here: $ErrorActionPreference = 'Stop' turns the
    # 422 "already exists" into a terminating error. Reuse the existing release.
    Write-Warn "release $tag already exists, reusing it"
    $response = Invoke-RestMethod -Method Get -Uri "$apiBase/repos/$Owner/$Repo/releases/tags/$tag" -Headers $headers

    foreach ($asset in @($response.assets)) {
        if ($asset.name -eq $assetName) {
            Write-Step "removing stale asset $assetName"
            Invoke-RestMethod -Method Delete -Uri "$apiBase/repos/$Owner/$Repo/releases/assets/$($asset.id)" -Headers $headers | Out-Null
        }
    }
}

# NOTE: assets go to uploads.github.com, NOT api.github.com - posting to the api
# host returns 404. The release object carries the right host in upload_url, as
# "https://uploads.github.com/.../assets{?name,label}".
$uploadBase = $response.upload_url -replace '\{.*$', ''
$assetUrl = "$uploadBase`?name=$([uri]::EscapeDataString($assetName))"

Write-Step "Uploading $assetName ($([math]::Round($size/1MB,1)) MB)"

# NOTE: curl is used because Invoke-RestMethod -InFile streams the body with
# Transfer-Encoding: chunked, which the uploads endpoint rejects, and because
# Windows PowerShell 5.1 negotiates TLS 1.0 by default and drops large transfers.
$tmpOut = [System.IO.Path]::GetTempFileName()
$httpCode = & curl.exe -s -o $tmpOut -w '%{http_code}' -X POST `
    -H "Authorization: token $env:GITHUB_TOKEN" `
    -H "Content-Type: application/octet-stream" `
    --data-binary "@$ZipPath" `
    --max-time 1800 `
    $assetUrl
$respBody = if (Test-Path $tmpOut) { [System.IO.File]::ReadAllText($tmpOut) } else { '' }
Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue

if ($httpCode -ne '201' -and $httpCode -ne '200') {
    Fail "Upload of $assetName failed with HTTP $httpCode : $respBody"
}

Write-Ok 'uploaded'

$downloadUrl = "https://github.com/$Owner/$Repo/releases/download/$tag/$assetName"

Write-Step 'Writing voice-model.json'
$manifest = [ordered]@{
    _comment = 'GRTubeYou offline speech model. Kept separate from version.json so the model can be replaced without releasing a new build of the app. Read by VoskModelStore.'
    model    = [ordered]@{
        version    = $Version
        dirName    = $DirName
        language   = $Language
        url        = $downloadUrl
        sha256     = $sha
        sizeBytes  = $size
        source     = 'https://alphacephei.com/vosk/models'
        license    = 'Apache-2.0'
    }
}

$manifestPath = Join-Path $DistPath 'voice-model.json'
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Ok $manifestPath

Write-Step 'Verifying the download url'
$head = Invoke-WebRequest -Method Head -Uri $downloadUrl -UseBasicParsing -ErrorAction SilentlyContinue
if ($head -and $head.StatusCode -eq 200) {
    Write-Ok "HTTP 200, $assetName"
} else {
    Write-Warn "unexpected answer from $downloadUrl"
}

Write-Host ''
Write-Step 'Done'
Write-Host "    Model:  $downloadUrl"
Write-Host "    Next:   commit and push voice-model.json in $DistPath"
Write-Host '    The app reads it on its next start; a model change needs no new app release.'
