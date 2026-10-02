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

# GRTubeYou 03.10.2026, beta12: таймлайн перестал идти от края до края.
#
# Полоса была самым широким элементом в оверлее, который в остальном компактный: она
# доходила примерно до 2% от каждого края экрана, тогда как заголовок, аватар канала и
# блок времени стояли на browse-отступе чуть внутри неё. Из-за этого плашка читалась как
# разделитель во всю ширину экрана, а не как таймлайн, и будучи самым длинным элементом,
# задавала ширину всему блоку.
#
# Добавлено по 32dp отступа с каждой стороны самому SeekBar - поверх того browse-отступа,
# который у него уже был. Именно margin, а не padding у родителя: подложка ЭТО и есть фон,
# а фон заливает границы view, поэтому сделать плашку короче можно только сделав view
# короче. Высота 30dp, радиус 15dp и сам drawable не тронуты - просили короче, а не
# переделывать.
#
# Намеренно НЕ вшито в browsePaddingStart: этот отступ общий с заголовком, аватаром и
# временем, и расширение там сдвинуло бы их всех ради одного элемента.
#
# Отступы симметричные: превью кадров - отдельная view во всю ширину, у которой герой
# центрируется по getWidth() / 2 и вообще не позиционируется вдоль полосы. Равные отступы
# оставляют середину на месте, разные - сдвинули бы превью с ручки.
#
# Прошлый пункт (beta11) остаётся в силе и здесь: ряд 30dp, радиус 15dp.
#
# Обводка вокруг панели перемотки обросла зазором. Причина не в обводке, а в том, что ряд
# таймлайна фиксированной высоты, а SeekBar рисует дорожку по центру этого ряда толщиной
# сколько захочет: 4dp в покое, 6dp в фокусе, ручка вдвое толще - 10dp в фокусе. Отступ от
# дорожки до края обводки равняется (высота ряда - толщина) / 2, то есть он НЕ ЗАДАЁТСЯ, а
# получается остатком. При 24dp и ручке 10dp от края оставалось 7dp, и обводка переставала
# читаться как подложка и читалась как рамка, нарисованная на панели.
#
# Ряд поднят с 24dp до 30dp. Панель от этого НЕ толстеет: толщина дорожки берётся из своих
# размеров, а ряд определяет только остаток вокруг них. Радиус обводки поехал вместе с
# высотой (половина ряда), иначе концы перестали бы закрываться в круг.
$changelog = @(
    'Плеер: подложка таймлайна стала заметно короче, по краям экрана появились отступы',
    'Плеер: таймлайн больше не тянется от края до края - блок выглядит собраннее',
    'Плеер: высота и скругление подложки сохранены'
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