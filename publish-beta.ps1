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

# GRTubeYou 02.10.2026, beta6: rewritten AGAIN, and this time about the crash.
#
# beta5 could not open a video at all - it crashed the instant anyone pressed one. That is
# stated in the first line below rather than left out, because a viewer who updated to beta5
# needs to know it was a fault and not something they did. The visual changes from beta5 were
# themselves fine and are still in this build; only the fault is new to say.
#
# Still absent, still not fixed: the date format remains YouTube's own, and the spacing beside
# the count-bearing vote buttons is still slightly tighter than between the others.
$changelog = @(
    'Исправлено: приложение падало при нажатии на видео - beta5 была сломана, и это была наша ошибка',
    'Причина: цвет таймлайна был задан числом вместо ссылки на цвет, и плеер не мог его прочитать',
    'Плеер: затемнение поверх видео стало одним мягким градиентом, а не двумя тёмными полосами',
    'Плеер: заголовок стал заметно компактнее и больше не занимает пол-экрана',
    'Плеер: нижняя панель легче - аватар канала уменьшен, отступы сокращены',
    'Плеер: линия таймлайна тоньше, полоса просмотренного белая, а не красная',
    'Плеер: строка метаданных короче - убрана надпись Дата публикации'
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