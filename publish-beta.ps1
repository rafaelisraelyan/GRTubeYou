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
# GRTubeYou 05.10.2026: THE DOUBLE PARENTHESES ARE LOAD-BEARING.
#
# Written as @(gh ... | ConvertFrom-Json), and in Windows PowerShell 5.1 that does NOT give a list of
# releases. It gives a list of ONE release, whose .tagName is every tag joined into one string.
# Measured on the live channel, 42 releases:
#
#     @(gh ... | ConvertFrom-Json)   ->  .Count = 1,  type of [0] = Object[]
#     @((gh ... | ConvertFrom-Json)) ->  .Count = 42
#
# ConvertFrom-Json hands back the array as one object, and @() wraps whatever came out of the
# pipeline rather than unwrapping an array that arrived intact inside it. The second pair of
# parentheses evaluates the pipeline first, so the array is expanded when it is collected.
#
# WHY IT MATTERED, and it is not cosmetic. The line below filters by regex:
#
#     $sameSeries = @($existingBetaTags | Where-Object { $_.tagName -match "^v32\.67-beta\d+$" })
#
# With one joined element, $_.tagName is the string "v32.68 v32.67-beta18 v32.67-beta17 ...", and
# PowerShell's -match on an ARRAY returns the matching elements rather than a boolean. The joined
# string then matched, the filter kept the one element it was given, and sameSeries.Count came out
# as 1 - not 16. It never raised an error and never looked wrong.
#
# Then the numbers came out of that same array:
#
#     existing beta numbers: 0, 0, 0, ... 1, 2, 3, 3, 4, 4, ..., 16, 16, 17, 18
#
# Zeros for v32.68 and v32.66, which have no beta in the name at all - [int]('') on a non-matching
# regex gives 0 - and each real beta twice. It still ended at 18 and still produced beta19, which is
# why it went unnoticed: the right answer for the wrong reason, from data that had never been
# filtered. Any series with a higher beta than this one would have had its number used instead, and
# a real difference would have shown up as a wrong number with nothing saying so.
$existingBetaTags = @((gh release list --limit 200 --json tagName,publishedAt --repo rafaelisraelyan/GRTubeYou 2>$null | ConvertFrom-Json))

if ($LASTEXITCODE -ne 0 -or -not $existingBetaTags) {
    throw ("could not list existing releases (gh exit $LASTEXITCODE). Refusing to publish: whether the " +
           "target tag is already taken is UNKNOWN, and that is not the same as it being free. " +
           "Check the network or the gh token and run again.")
}

$allTagNames = @($existingBetaTags | ForEach-Object { $_.tagName })
$sameSeries = @($existingBetaTags | Where-Object { $_.tagName -match "^v$([regex]::Escape($BetaBaseVersion))-beta\d+$" })
$seriesNames = @($sameSeries | ForEach-Object { $_.tagName })

# GRTubeYou 05.10.2026: no check that the regex matched, and the reason is the filter above.
#
# [int]('') is 0, so an unmatched regex contributes a zero to $betaNumbers rather than nothing - and
# a zero here is a lie about the channel, printed in a line the operator is reading to decide
# something. That is how v32.68 and v32.66 showed up in "existing beta numbers" as 0.
#
# A `if ($m.Success)` guard was written here first and then removed, because $seriesNames can only
# contain tags the filter above accepted, and that filter requires "beta\d+$" at the end of the
# name. The same regex below therefore always matches, and a guard against a case that cannot
# happen is code that reads as protection while being untested: removing it changed no test result,
# which is the tests correctly reporting that there was nothing behind it.
#
# THE INVARIANT IS NOT FREE, it is just held one line up. Weaken the filter to "beta.*$" and a tag
# like v32.67-betaX now reaches this cast and contributes 0. test-publish-beta-target.ps1 runs that
# case against the real patterns from this file.
#
# NOTE: no -Unique. Removing it was tried as a mutation and the tests did not notice, which is the
# tests being right: tag names are unique by construction (v32.67-beta4 is one tag), so the numbers
# cannot repeat, and -Unique only changed how the printed list looked.
$betaNumbers = @($seriesNames |
    ForEach-Object { [int]([regex]::Match($_, 'beta(\d+)$').Groups[1].Value) } |
    Sort-Object)

Write-Host ("pre-flight: {0} releases on GitHub; this series ({1} beta) already has {2}" -f `
        $allTagNames.Count, $BetaBaseVersion, $(if ($sameSeries.Count) { $seriesNames.Count } else { 'none' }))
if ($betaNumbers.Count -gt 0) {
    Write-Host ("           existing beta numbers: {0}" -f ($betaNumbers -join ', '))
}

# GRTubeYou 05.10.2026: THE NUMBER COMES FROM GITHUB, NOT FROM build.gradle.
#
# This line prints "the next free number is betaN" and then THROWS THE ANSWER AWAY, letting
# publish.ps1 derive the number from build.gradle's own beta suffix instead. Measured on the state
# this was written against, and the two disagreed:
#
#     build.gradle holds        32.67 beta3   (2505)
#     build.gradle says next    32.67 beta4   (2506)
#     GitHub says next free     32.67 beta19
#
# v32.67-beta4 is a REAL release from 02.10 with its own four APKs. So the run would have aimed at
# an occupied tag, built four APKs for two minutes, uploaded them over the top of beta4's assets,
# and reported success. publish.ps1 would have stopped it - the hard Fail on an existing release is
# why that was a two-minute waste and not a third destroyed release - but the waste is the whole
# point of the pre-flight, and the number was already sitting in $betaNumbers.
#
# WHY THE DIVERGENCE EXISTS, because it is the actual lesson. Deriving the beta number from
# build.gradle is only correct while build.gradle holds the HIGHEST number ever published in the
# series. Deleting v32.67-beta1 and beta2 on 05.10 broke that: the counter restarted at 1, so
# beta3/beta4 came out BELOW the beta5..beta18 published on 02.10-05.10, and "the last one I wrote"
# stopped meaning "the last one that exists". Nothing about deleting a release says so in
# build.gradle, which is why this has to be read from the one place that is authoritative.
#
# So: highest existing + 1, and if that tag is somehow present anyway, stop rather than pick again.
$TargetBetaNumber = 0

if ($betaNumbers.Count -gt 0) {
    $TargetBetaNumber = $betaNumbers[-1] + 1
    $targetTag = "v$($BetaBaseVersion -replace '\s+','-')-beta$TargetBetaNumber"

    if ($allTagNames -contains $targetTag) {
        throw ("computed target $targetTag is already in the release list, so 'highest + 1' is " +
               "wrong here - not something to publish over. Stopping; work out the number by hand.")
    }

    Write-Host ("           highest is beta{0} - publishing beta{1} ({2})" -f `
            $betaNumbers[-1], $TargetBetaNumber, $targetTag) -ForegroundColor Green
} else {
    Write-Host ("           no betas in this series yet - publishing beta1") -ForegroundColor Green
    $TargetBetaNumber = 1
}

Write-Host ""

# And say the number build.gradle would have produced, so a divergence is visible rather than
# silently corrected. This is the whole defect in one line of output: two sources of truth, one
# trusted, one ignored, and nothing said about the gap.
# NOTE: this branch is why the format arguments below are counted by the test rather than by eye.
#
# It prints only when build.gradle and GitHub DISAGREE - so on every publish before 05.10 it never
# ran, and a format string with two placeholders and one argument sat there unexecuted. The run that
# finally reached it died two seconds in with "Error formatting a string: Index (zero based) must be
# greater than or equal to zero and less than the size of the arguments", after printing half the
# warning.
#
# Nothing was published, so the cost was small, but the shape is the familiar one: the code that only
# runs in the interesting case is the code nobody runs until the interesting case arrives.
$gradleBeta = [regex]::Match($nameMatch.Groups[1].Value, '[- ]beta\.?(\d+)$')
if ($gradleBeta.Success) {
    $implied = [int]$gradleBeta.Groups[1].Value + 1

    if ($implied -ne $TargetBetaNumber) {
        Write-Host ("  NOTE: build.gradle says '{0}', which implies beta{1}. Publishing beta{2} instead," -f `
                $nameMatch.Groups[1].Value, $implied, $TargetBetaNumber) -ForegroundColor Yellow
        Write-Host ("        because beta{0} already exists on GitHub - beta{1} would overwrite it." -f `
                $implied, $implied) -ForegroundColor Yellow
    }
}

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

# GRTubeYou 05.10.2026, beta4 (и на самом деле beta19): плеер перестаёт бесконечно
# «чинить» ролик, который не грузится, и говорит почему.
#
# Жалоба (лог grtubeyou-log): сети нет совсем, и ролик перечитывается каждые ~6 секунд
# минутами подряд. Падения нет и исключения нет - стектрейса искать не по чему, на экране
# ничего нет. Зритель видит экран, который выглядит зависшим, и никакой причины.
#
# Теперь три попытки, потом сообщение. Три - потому что это три разных рычага: первая
# перечитывает видео, вторая меняет внутренний клиент, третья меняет сетевой стек. Четвёртой
# тянуть нечего, а большее число купило бы только более долгое ожидание признания поражения.
#
# Счётчик общий для обеих причин (зависание и непрочитанный формат) и обнуляется на каждом
# ролике: обрыв сети на одном видео не должен съедать запас следующего.
#
# ВНИМАНИЕ, ЧТО ДЕЛАЕТ ЭТОТ ВЫПУСК НЕОДНОЗНАЧНЫМ ПО ИМЕНИ. Номер беты теперь берётся из
# списка релизов на GitHub, а не из build.gradle: удалённые 02.10 beta1 и beta2 оставили
# в build.gradle «beta3», и вывод «+1» нацелился бы на v32.67-beta4 - реальный релиз от 02.10.
# Поэтому следующий релиз - beta19, а не beta4. Пропуск в нумерации виден и он настоящий.
#
# --- предыдущие выпуски ---
#
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
# GRTubeYou 06.10.2026, beta20: колонка каналов в разделе Каналы переработана.
#
# Жалоба: элементы каналов выглядят как набор мелких тегов, а не как навигация; названия
# прижаты к аватарам, внутренних отступов мало, по вертикали всё сжато.
#
# ЧТО БЫЛО НЕ ТАК, ИЗМЕРЕНО В КОДЕ, А НЕ НА ГЛАЗ:
#   - фон ставился ДВАЖДЫ, на контейнер и на текст: строка рисовалась двумя кусками,
#     аватаром и названием, и между ними не было ничего целого;
#   - у аватара не было размера вовсе (wrap_content + fitCenter), то есть размер задавала
#     сама загруженная картинка. Отсюда и разные размеры, и «прижатость»: отступ был ноль;
#   - у названия не было места: ellipsize=end стоял, но работать ему было не на чем.
#
# ЧТО СДЕЛАНО. Одна пилюля вместо двух, фиксированный круглый аватар 36dp, текст 18sp,
# отступ 10/12/18dp внутри, 8dp между строками, высота строки 30dp -> 46dp, ширина 200 -> 240dp.
# Цвета не тронуты: красный по-прежнему означает «есть новое содержимое», а не «выбран».
#
# ЧЕСТНО О ЦЕНЕ. Строка 46dp + 8dp отступа - это 108px на канал против 60px раньше, то есть
# видно примерно пять каналов вместо десяти. При высоте 64-70px на экране 1080p иначе не выйдет.
# Колонка стала шире на 7% экрана, и видео справа от этого стало чуть уже.
#
# ПРОВЕРЕНО НА УСТРОЙСТВЕ: нет. Всё выше прочитано из кода и посчитано по формуле ширины
# колонны на экране 1920x1080 с плотностью 2.
$changelog = @(
    'Страница канала: вкладки и шапка грузятся одним запросом вместо двух'
    'Причина: и то и другое лежит в одном ответе YouTube, а запрашивалось дважды. Второй запрос и забирал первый - на устройстве страница приходила с баннером, аватаром и пустым местом вместо названия, без вкладок и без шапки'
    'Страница канала: больше не бывает пустой шапки. Если нет ни названия, ни шапки, ряд с аватаром скрывается целиком'
    'Было: пустое место высотой с аватар, и страница выглядела сломанной, а не загружающейся. Скрывался только текст, а высоту задавал аватар - пустота оставалась'
    'Что изменилось на экране: имя канала, @handle, подписчики, число видео, описание и строка ссылок - как и было; вкладки и фильтры на месте'
    'Проверено на эмуляторе: 1920x1080 плотность 2.0, замеры границ, а не взгляд на снимок - 228..428 баннер, 388..604 шапка, 712..797 вкладки, 228..1080 видео. FATAL 0, ошибок загрузки 0'
    'ВАЖНО, ИЗВЕСТНАЯ ОШИБКА ЭТОЙ СБОРКИ: пульт может переставать доходить до сетки видео - фокус встаёт. Это от наложения шапки поверх видео, проверьте пультом'
    'ИЗВЕСТНО ОСТАЁТСЯ: зона видео всего 173px при карточке около 230dp - первую карточку видно наполовину. Шапка не помещается в экран, и это отдельный вопрос'
    'ИЗВЕСТНО ОСТАЁТСЯ: кнопок уведомлений, сообщества и прочих нет - в ответе YouTube приходит только кнопка Подписаться, остальные выдумывать мы не стали'
    'ИЗВЕСТНО ОСТАЁТСЯ: ряд Shorts строится из вертикальных карточек, а высота строки считается по обычной карточке'
    'ПРИМЕЧАНИЕ: если страница снова покажется пустой - скажите, как вы открывали канал: карточкой из поиска или переходом из видео, подписок, истории. Это единственная оставшаяся переменная'
    'ВНИМАНИЕ: beta21, beta22 и beta23 открывали страницу канала не полностью - смотрите список изменений предыдущих сборок'
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
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -BetaNumber $TargetBetaNumber `
        -VersionName $BetaBaseVersion -VersionCode $VersionCode -ChangeLog $changelog
} else {
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -BetaNumber $TargetBetaNumber `
        -VersionName $BetaBaseVersion -ChangeLog $changelog
}

if ($LASTEXITCODE -ne 0) { throw "publish failed with $LASTEXITCODE" }
