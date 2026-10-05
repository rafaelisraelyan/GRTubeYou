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
# -VersionName '32.67' is deliberate and not redundant. publish.ps1 derives the beta number
# from the versionName in build.gradle, and its "continue the counter" branch is guarded by
# `-not $explicitVersion`. With no name passed that guard is always true and every beta
# resets to 1. Passing the base explicitly is what makes 32.67 beta2 -> 32.67 beta3.
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
# to reuse that number: -VersionName is deliberately NOT passed, because passing the base "32.67"
# is what makes publish.ps1 decide the beta number, and it would decide beta8 over a set of files
# that are beta7. -Resume takes the name and code as they stand.
#
# Without this the only honest option was to rebuild, which would publish an eighth APK instead
# of the seventh - and the seventh is the one on disk, already built and signed.
param(
    [string] $PrebuiltDir = '',
    [int]    $VersionCode = 0
)

$ErrorActionPreference = 'Stop'

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

# GRTubeYou 05.10.2026, beta19: оверлей больше не будит телефон каждые три секунды,
#                     пока видео на паузе; лог больше не врёт про два разных таймера.
#
# Найдено по баг репорту пользователя: он прислал лог, в котором 952 строки из 1495 -
# один и тот же таймер. Ни падений, ни исключений в логе не было. Нашлось только
# через арифметику по времени.
#
# ЧТО БЫЛО. Обработчик ухода оверлея перевзводил сам себя безусловно. Комментарий
# называл состояние - перемотку, а условие проверяло ещё и паузу. Пауза не переходная:
# она может длиться часами. Ровно каждые 3.000 секунды, 24 минуты, 475 раз.
#
# Код пришёл из upstream (969ad62, Юрий Лисков, 27.09), наш форк файл не трогал.
# Цикл старый, мы его нашли, а не внесли.
#
# ЧТО СТАЛО. Решение вынесено в чистую функцию: четыре условия на входе, одно из трёх
# действий на выходе. Пауза больше не ждёт - ей нечего ждать. Перемотка и буферизация
# ждут, потому что они кончаются. Повторов не больше 30: при трёх секундах это полторы
# минуты, а там, где сдача происходит, оверлей просто остаётся видимым - на паузе это и
# нужно. Возобновление перевзводит таймер заново, иначе после паузы оверлей не спрятался
# бы больше никогда.
#
# ЛОГИ. Оба метода логировали, а «взвести» внутри вызывал «снять», поэтому одно взведение
# печатало две строки. ScreensaverManager печатал «auto hide ui timer» - формулировка,
# скопированная из PlayerUIController, хотя это таймер выключения экрана. В баг репорте
# это читается как «таймер оверлея гонится за чем-то», и именно за этим гнался я сам,
# пока не открыл код.
$changelog = @(
    'Плеер: оверлей перестал будить систему каждые три секунды, пока видео на паузе - раньше это продолжалось всё время паузы',
    'Плеер: оверлей на паузе остаётся на экране, а не прячется сам',
    'Логи: убрана пустая болтовня о таймерах, из-за которой баг репорт был нечитаемым',
    'Логи: таймер выключения экрана больше не подписывается как таймер оверлея - это разные вещи'
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
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName '32.67' -VersionCode $VersionCode -ChangeLog $changelog
} else {
    & (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName '32.67' -ChangeLog $changelog
}

if ($LASTEXITCODE -ne 0) { throw "publish failed with $LASTEXITCODE" }
