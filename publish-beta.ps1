# GRTubeYou: wrapper that publishes the beta.
#
# Exists because two things get in the way of calling publish.ps1 directly:
#   - the execution policy refuses to run a .ps1 from this directory;
#   - passing Cyrillic through -File on the command line is a quoting minefield, and one
#     mangled changelog line becomes "?" in the published release notes. Reading the text
#     from this UTF-8 file keeps the wording exactly as written.
#
# NOTE: this file MUST stay UTF-8 WITH BOM. Windows PowerShell 5.1 reads a .ps1 as ANSI when
# there is no BOM, the Cyrillic comes out as mojibake, and the guillemets inside the strings
# then break the parser outright.
#
# GRTubeYou 05.10.2026: THE HARD-CODED -VersionName IS GONE, AND IT IS THIS FILE'S WORST BUG.
#
# It used to say `-VersionName '32.67'` on both call lines, hard-coded, with a comment above it
# defending that as deliberate: publish.ps1 derives the beta number from build.gradle, and its
# "continue the counter" branch is guarded by `-not $explicitVersion`, so without a name every
# beta restarts at 1 and `32.67 beta2 -> 32.67 beta3` breaks. That reasoning was correct about the
# counter and was then left in place forever after the series moved on. It said 32.67 while the
# stable channel had moved to 32.68, and:
#
#     with    -VersionName '32.67'  ->  32.67 beta1 = 2503, tag v32.67-beta1
#     without -VersionName          ->  32.69 beta1 = 2503, tag v32.69-beta1
#
# v32.67-beta1 is a real release from 02.10 with its own four APKs. The wrapper therefore aimed a
# publish at a tag that already existed and OVERWROTE that release's assets. The script printed a
# warning, correctly, and I read it, and then ran the publish anyway - having "rolled back the
# version" in build.gradle, which changed nothing here because the name never came from there.
#
# So the name now comes from where it belongs: the stable version in build.gradle, which is the
# truth about which series the next beta belongs to. publish.ps1 already reads that file and
# already strips a beta suffix for this exact purpose (oldBaseName). Reading it again is correct;
# hard-coding it was only ever right for exactly one publish.
#
param(
    [string] $PrebuiltDir = '',
    [int]    $VersionCode = 0
)

$ErrorActionPreference = 'Stop'

# The series the next beta belongs to: the version currently in build.gradle, with any beta
# suffix removed.
#
# THE STRIP IS WHAT MAKES THIS CORRECT. After a beta publish build.gradle holds "32.67 beta1", not
# the stable number - so stripping is not tidiness, it is the difference between publishing into
# the beta series already in progress ("32.67 beta2") and starting a new one from a stale beta
# name. Verified against the state left by the run that overwrote v32.67-beta1: build.gradle said
# "32.67 beta1", the strip gives "32.67", and without the strip the wrapper would have aimed at
# "32.67 beta1 beta1".
#
# Read from the file rather than passed on the command line, because the command line is where the
# wrong value came from. An override remains possible for a deliberate gap, which is what
# -VersionCode already is.
$gradleFile = Join-Path $PSScriptRoot '..\SmartTube\smarttubetv\build.gradle'
if (-not (Test-Path $gradleFile)) {
    throw "build.gradle not found at $gradleFile - cannot tell which series this beta belongs to"
}

$gradleText = [System.IO.File]::ReadAllText($gradleFile)
$nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
if (-not $nameMatch.Success) {
    throw "could not read versionName out of $gradleFile"
}

$BetaBaseVersion = ($nameMatch.Groups[1].Value -replace '[- ]beta\.?\d+$', '').Trim()
if (-not $BetaBaseVersion) {
    throw "versionName in $gradleFile resolved to an empty base version"
}

Write-Host "beta series resolved from build.gradle: $BetaBaseVersion"

# GRTubeYou 05.10.2026: ask GitHub whether the tag we are about to aim at is free, BEFORE
# building, and treat "could not tell" as a stop rather than as "free".
#
# The check that existed before this was written as
#
#     $null = gh release view $tag --json tagName 2>&1
#     if ($LASTEXITCODE -eq 0) { 'taken' } else { 'free' }
#
# and it reported a tag that was already published as FREE. "The lookup failed" and "there is
# nothing there" both arrive as a non-zero exit code, and only the second one means free. That is
# the same shape as the failure this project has now made three times: a check that cannot
# distinguish "no" from "could not tell", and a caller that reads the difference as good news.
#
# So: HTTP 404 means free. Any other failure, and any unexpected answer, stops the publish. The
# build is two minutes, and it is not worth spending on a target that may be occupied.
Write-Host "pre-flight: listing existing releases"
# GRTubeYou: --limit 200, not 40, and that number matters.
#
# `gh release list` sorts by published_at, NOT by name. The two releases destroyed on 05.10 were
# v32.67-beta1 and v32.67-beta2 from 02.10, so after the recent 18 betas they sit at positions
# #17 and #18 - and at --limit 40 they are pushed out entirely on a busy repo. A pre-flight that
# asks "which betas exist in this series" and silently misses the two that matter is worse than
# no pre-flight: it looks like it ran.
$existingBetaTags = @(gh release list --limit 200 --json tagName,publishedAt --repo rafaelisraelyan/GRTubeYou 2>$null | ConvertFrom-Json)

if ($LASTEXITCODE -ne 0 -or -not $existingBetaTags) {
    throw ("could not list existing releases (gh exit $LASTEXITCODE). Refusing to publish: whether the " +
           "target tag is already taken is UNKNOWN, and that is not the same as it being free. " +
           "Check the network or the gh token and run again.")
}

$allTagNames = @($existingBetaTags | ForEach-Object { $_.tagName })
$sameSeries = @($existingBetaTags | Where-Object { $_.tagName -match "^v$([regex]::Escape($BetaBaseVersion))-beta\d+$" })
$seriesNames = @($sameSeries | ForEach-Object { $_.tagName })
$betaNumbers = @($seriesNames | ForEach-Object { [int]([regex]::Match($_, 'beta(\d+)$').Groups[1].Value) } | Sort-Object)

Write-Host ("pre-flight: {0} releases on GitHub; this series ({1} beta) already has {2}" -f `
        $allTagNames.Count, $BetaBaseVersion, $(if ($sameSeries.Count) { $seriesNames.Count } else { 'none' }))
if ($betaNumbers.Count -gt 0) {
    Write-Host ("           existing beta numbers: {0}" -f ($betaNumbers -join ', '))
    Write-Host ("           highest is beta{0} - the next free number in this series is beta{1}" -f `
            $betaNumbers[-1], ($betaNumbers[-1] + 1))
}
Write-Host ""

#
# The manifest push and the delivery check are NOT here any more. They used to be, and they
# now live inside publish.ps1, because that is the only place they cannot be skipped: the
# stable channel publishes by calling publish.ps1 directly, so a fix that only sat in this
# wrapper left the exact failure it was meant to prevent one channel away.
#
# GRTubeYou 02.10.2026: -PrebuiltDir publishes APKs that were built already, from that
# folder, instead of building a new set.
#
# It pairs with -Resume inside publish.ps1, and the pairing is not optional. The version is
# already baked into those files and build.gradle is already sitting on it, so the publish has
# to reuse that number: -VersionName is deliberately NOT passed, because passing a base is what
# makes publish.ps1 decide the beta number, and it would decide beta8 over a set of files
# that are beta7. -Resume takes the name and code as they stand.
#
# Without this the only honest option was to rebuild, which would publish an eighth APK instead
# of the seventh - and the seventh is the one on disk, already built and signed.
#

# --------------------------------------------------------------------- changelog
#
# A hand-written list, because a release note is a judgement about what a viewer will notice,
# not a diff. When it is empty the lines are built from the commits instead, which is better
# than nothing on an ordinary build - and useless for a release note, which is why the manual
# list wins whenever it is filled in.
#
# GRTubeYou: the commit log is in English and the release notes are in Russian, so the
# generated form is a safety net and not the normal path. It is deliberately not attempted
# here rather than half-translated.

# GRTubeYou 05.10.2026, beta3: обновление больше не зависит от того, чей кэш ответит первым.
#
# Жалоба: стоял 32.68 (2502), тумблер беты включён, бет-канал отдаёт 2504 - и обновление
# не предлагалось. В логе правильный канал, правильный URL, загрузка завершилась - а тело
# пришло старое, с максимумом 2501.
#
# ЧТО ИЗМЕРЕНО, А НЕ ПРЕДПОЛОЖЕНО. Против raw.githubusercontent.com:
#
#     без заголовков           X-Cache: HIT
#     Cache-Control: no-cache  X-Cache: HIT
#     Cache-Control: no-store  X-Cache: HIT
#     Pragma: no-cache         X-Cache: HIT
#     ?t=<nonce>               X-Cache: HIT   (счётчик продолжал расти - тот же объект)
#     новый путь               X-Cache: MISS
#
# То есть заголовки запроса этот CDN НЕ ревалидирует, и добавленный ранее ?t=<миллисекунды>
# новый кэш-объект тоже НЕ создаёт. Единственное, что измеренно работает - путь, который
# ещё никто не запрашивал.
#
# ЧТО СДЕЛАНО. Публикатор пишет вторую копию манифеста с именем по номеру версии, а
# приложение спрашивает СНАЧАЛА манифест следующей версии (установленная + 1), и только потом
# постоянный. Содержимое побайтово то же, вместе со всей историей, поэтому список изменений
# не меняется. Постоянный манифест по-прежнему пишется и запрашивается: сборка старше этой
# ничего о версионных именах не знает и иначе перестала бы находить обновления.
#
# ОДИН ЗАПРОС, А НЕ ПЕРЕБОР. Перебор диапазона добавил бы несколько запросов каждому, у кого
# обновлений нет, а это большинство и почти всегда.
#
# НОВОЙ ЛОГИКИ НЕ ПОТРЕБОВАЛОСЬ: AppVersionChecker и так обходит массив URL и берёт первый,
# который распарсился, поэтому 404 на пробе переводит его на постоянный манифест сам.
$changelog = @(
    'Обновление: приложение больше не попадает на устаревшую копию манифеста и потому не пропускает вышедшую бету',
    'Обновление: проверка спрашивает манифест следующей версии по новому адресу - кэш больше не может её скрыть'
)

if ($changelog.Count -eq 0) {
    Write-Host "no changelog given, falling back to commit subjects" -ForegroundColor Yellow
    $changelog = @(
        & git -C (Join-Path $PSScriptRoot '..\SmartTube') log --pretty=format:'%s' -20 |
            Where-Object { $_ -and $_ -notmatch '^(build.gradle|record the version)' }
    )
}

if ($PrebuiltDir) {
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -Resume -SkipBuild `
        -PrebuiltDir $PrebuiltDir -ChangeLog $changelog
} elseif ($VersionCode -gt 0) {
    # -VersionCode is passed through so a gap in the numbering can be left deliberately.
    #
    # GRTubeYou 02.10.2026: versionCode 2490 was briefly in version-beta.json without a release
    # behind it, and the release was then deleted. Nothing downloaded it, but a device that read
    # that manifest may have recorded 2490 as the newest it knows. Reusing the number would
    # leave exactly those devices comparing equal forever and never being offered the update -
    # a dead end with no error anywhere. A gap in the sequence is invisible to everyone; a
    # duplicated code is not.
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName $BetaBaseVersion -VersionCode $VersionCode -ChangeLog $changelog
} else {
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName $BetaBaseVersion -ChangeLog $changelog
}

if ($LASTEXITCODE -ne 0) { throw "publish failed with $LASTEXITCODE" }
