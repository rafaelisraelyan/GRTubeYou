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

# GRTubeYou 04.10.2026, beta13: главное здесь - краш на Android 14, приложение там просто
# не запускалось.
#
# VoskModelStore звал registerReceiver с двумя аргументами, а начиная с API 34 это бросает
# исключение, если не указан RECEIVER_EXPORTED или RECEIVER_NOT_EXPORTED. А MainApplication
# зовёт ensureModel из onCreate - то есть процесс умирал раньше, чем появился хоть один экран.
# Флаг NOT_EXPORTED, а не разрешающий: в фильтре одно действие ACTION_DOWNLOAD_COMPLETE, и
# приёмник сверяет id с тем, который сам же сохранил, - трансляция от другого приложения для
# него ничего не значит. Системные приходят как приходят. Через ContextCompat, потому что флаг
# есть с API 26, а minSdk 21. Так уже сделано в UhdHelper; это был единственный вызов без флага.
#
# ЗАЗОР МЕЖДУ ПОЛОВИНКАМИ ПИЛЮЛИ НЕ БЫЛ ПОЧИНЕН ВООБЩЕ. Тег, который помечает кнопку как
# половину пилюли, ставился на mFocusableView, а макет lb_control_button_secondary.xml - это
# FrameLayout-обёртка, и в ряд попадает КОРЕНЬ этого макета, а не лежащая внутри кнопка.
# Тег не совпадал никогда, отступ всегда уходил в формулу расстояний, а код соединения,
# добавленный ещё в beta10, был мёртвым с момента написания. Теперь тег ищется уровнем ниже.
#
# У правой половинки к тому же был внутренний отступ от половины переполнения: слева он держит
# короткое число по центру круга 48dp, а справа попадает ровно на шов и снова раздвигает
# половинки - тем сильнее, чем длиннее число. Поэтому трёхзначное число выглядело соединённым,
# а шестизначное нет. Обнулено только справа, и продублировано на иконку, потому что это
# соседи в одном фрейме.
#
# Плашка таймлайна - inset по 12dp с каждой стороны ряда 30dp, остаётся 6dp: высота дорожки в
# фокусе и на 1dp больше в покое. Ряд остаётся 30dp, он зона нажатия для OK и D-pad; тонкой
# сделана только плашка. Радиус поехал за ней, 15dp -> 3dp: при половине ряда был стадион во
# всю высоту.
#
# РАЗДЕЛИТЕЛЬ НАПИСАН КОДОМ, И В КОММЕНТАРИИ К НЕМУ СКАЗАНО ПОЧЕМУ. Три способа описать его
# вторым элементом layer-list пилюли дали один и тот же результат: скомпилированный XML
# корректен (gravity, высота, ширина, ссылка на drawable - всё на месте), а рисуется ноль.
# Проверялось профилем яркости по шву, а не на глаз: заливка обрывалась и начинался фон без
# единой промежуточной светлой точки. Теперь это foreground, который размещает линию сам.
#
# ЭТО НЕ ПРОВЕРЕНО. Компилируется, ставится, приложение работает, но после того как слепые
# тапы перестали попадать в плеер, линию никто не видел.
$changelog = @(
    'Исправлено: на Android 14 приложение падало при запуске и вообще не открывалось',
    'Плеер: подложка таймлайна стала намного тоньше и прилегает к дорожке',
    'Плеер: лайк и дизлайк смыкаются в одну целую пилюлю',
    'Плеер: между лайком и дизлайком тонкий вертикальный разделитель'
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
