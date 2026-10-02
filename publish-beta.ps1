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

$changelog = @(
    'Голосовой ввод в поиске: кнопка микрофона больше не молчит',
    'Если системного распознавателя на приставке нет, офлайн-распознавание включается само',
    'Разрешение на микрофон теперь действительно запрашивается - раньше его не выдавали',
    'Сообщение об ошибке работает: отчёт с логом и сведениями о приставке приходит в Telegram',
    'Лог приходит файлом grtubeyou-log.txt, а не сообщениями, и стал в 10 раз больше',
    'Плеер: кнопка выбора качества видео перед настройками, открывает список форматов',
    'Плеер: качество больше не роняет приложение, если нажать слишком рано',
    'Плеер: лайки и дизлайки переехали из строки под заголовком к их кнопкам, с числами',
    'Плеер: подписчики убраны из строки видео - они по-прежнему видны на странице канала',
    'Плеер: мягкие градиенты под верхним текстом и под панелью, чётче иерархия текста',
    'Плеер: тоньше линия таймлайна, спокойнее подсветка фокуса у кнопок'
)

if ($changelog.Count -eq 0) {
    Write-Host "no changelog given, falling back to commit subjects" -ForegroundColor Yellow
    $changelog = @(
        & git -C (Join-Path $PSScriptRoot '..\SmartTube') log --pretty=format:'%s' -20 |
            Where-Object { $_ -and $_ -notmatch '^(build.gradle|record the version)' }
    )
}

& (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName '32.67' -ChangeLog $changelog
if ($LASTEXITCODE -ne 0) { throw "publish failed with $LASTEXITCODE" }