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

# GRTubeYou 04.10.2026, beta14: три правки, все - в нижнем ряду плеера.
#
# ШЕСТЕРЁНКА НАСТРОЕК ВЕРНУЛАСЬ. В beta13 её в ряду не было: та сборка шла из рабочего дерева с
# закомментированной кнопкой, и коммит этого не зафиксировал - файл в репозитории и APK на канале
# расходились. Проверено на эмуляторе: в установленном beta13 ряд заканчивается значком качества,
# в текущей сборке после него стоит ещё и шестерёнка. Потому это первая строка изменений, а не
# мелкая правка - у кого стоит beta13, шестерёнки не видно.
#
# РАВНЫЕ ОТСТУПЫ ДО РАЗДЕЛИТЕЛЯ. Половинки пилюли имели одинаковый внутренний отступ, и разделитель
# стоял ровно на шве, но зазоры выглядели неравными: 20px слева против 25px справа при плотности 2.
# Разницу давали не раскладка, а картинки - около 4.5dp прозрачного поля внутри иконки "палец вниз"
# плюс вынос последней цифры. Поэтому лайку добавлено 2.5dp от края шва: зазоры стали по 25px,
# разница 0. Иконку не двигал и разделитель оставил на шве - он принадлежит шву.
#
# ПОЛОВИНКА ЗА ГОЛОС СВЕТЛЕЕ. Теперь видно, за что проголосовано, не уводя фокус на кнопку. Нового
# состояния не заводил: PlayerUIController уже переключает индекс действия по нажатию и сверяет его
# со статусом лайка у видео, а TwoStateAction держит половинки взаимоисключающими, - пилюля просто
# об этом не спрашивала. Флаг отдан селектору как state_selected, поэтому ни одной новой картинки не
# понадобилось. Он стоит после focused и pressed: проголосованная половинка как раз та, что под
# D-pad, и выигрыш у фокуса означал бы, что метка исчезает в момент нажатия.
$changelog = @(
    'Плеер: вернулась шестерёнка настроек - в beta13 её не было в ряду',
    'Плеер: равные отступы от числа и иконки до разделителя между лайком и дизлайком',
    'Плеер: половинка, за которую проголосовали, становится светлее'
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
