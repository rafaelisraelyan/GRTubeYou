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
# resets to 1. Passing the base explicitly is what makes 32.67 beta1 -> 32.67 beta2.
$ErrorActionPreference = 'Stop'

$changelog = @(
    'Сообщение об ошибке работает: отчёт с логом и сведениями о приставке приходит в Telegram',
    'Голосовой ввод: кнопка микрофона больше не молчит',
    'Если системного распознавателя на приставке нет, офлайн-распознавание включается автоматически - искать настройку не нужно',
    'Разрешение на микрофон теперь действительно запрашивается: раньше его не выдавали, и кнопка оставалась мёртвой'
)

& (Join-Path $PSScriptRoot 'publish.ps1') -Beta -VersionName '32.67' -ChangeLog $changelog
exit $LASTEXITCODE