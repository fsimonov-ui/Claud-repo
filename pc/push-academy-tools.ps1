# ============================================================================
# Выгрузка скриптов публикации и дашборда с ПК в приватный репозиторий academy-tools
# ============================================================================
# Что делает:
#   1. Клонирует https://github.com/fsimonov-ui/academy-tools (репозиторий нужно
#      заранее создать на github.com/new как Private, можно пустой).
#   2. Копирует D:\Video\tools -> tools\ и D:\tools\academy-dashboard -> dashboard\,
#      пропуская токены, кэши, медиафайлы и папку refs с фотографиями.
#   3. Проверяет копию на похожие на токены строки и останавливается, если нашёл.
#   4. Коммитит и пушит.
#
# Запуск в PowerShell на ПК:
#   irm https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/pc/push-academy-tools.ps1 | iex
# ============================================================================

$ErrorActionPreference = "Stop"
$Repo = "https://github.com/fsimonov-ui/academy-tools.git"
$Dst  = Join-Path $env:USERPROFILE "academy-tools"
$Src  = @{
    "tools"     = "D:\Video\tools"
    "dashboard" = "D:\tools\academy-dashboard"
}

function Say($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok($t)  { Write-Host "  + $t" -ForegroundColor Green }
function Die($t) { Write-Host "`nОШИБКА: $t" -ForegroundColor Red; exit 1 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git не найден. Установите: winget install Git.Git" }
foreach ($k in $Src.Keys) { if (-not (Test-Path $Src[$k])) { Die "Папка $($Src[$k]) не найдена" } }

Say "Клонирую academy-tools в $Dst"
if (Test-Path (Join-Path $Dst ".git")) {
    git -C $Dst pull -q --ff-only 2>$null
} else {
    git clone -q $Repo $Dst
    if ($LASTEXITCODE -ne 0) { Die "Не удалось клонировать. Создан ли репозиторий fsimonov-ui/academy-tools и есть ли вход в GitHub?" }
}
Ok "Готово"

Say "Копирую папки (без токенов, кэшей и медиа)"
$xd = @("__pycache__", "node_modules", ".git", "refs", ".venv", "venv", "output", "input")
$xf = @("telegram_token.txt", "*token*.txt", "*token*.json", "*secret*.json", "*credentials*.json",
        "*.pickle", "*.pkl", ".env", "*.env", "*.key", "*.pem",
        "*.mp4", "*.mov", "*.mkv", "*.avi", "*.mp3", "*.wav", "*.m4a", "*.zip", "*.7z")
foreach ($k in $Src.Keys) {
    $to = Join-Path $Dst $k
    robocopy $Src[$k] $to /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD @xd /XF @xf | Out-Null
    if ($LASTEXITCODE -ge 8) { Die "robocopy завершился с ошибкой для $($Src[$k])" }
    Ok "$($Src[$k]) -> $k\"
}

Say "Пишу .gitignore"
@"
# секреты и токены
telegram_token.txt
*token*.txt
*token*.json
*secret*.json
*credentials*.json
*.pickle
*.pkl
.env
*.env
*.key
*.pem
# кэши и окружения
__pycache__/
node_modules/
.venv/
venv/
# медиа и личные фото
*.mp4
*.mov
*.mkv
*.avi
*.mp3
*.wav
*.m4a
refs/
output/
input/
"@ | Set-Content -Path (Join-Path $Dst ".gitignore") -Encoding UTF8
Ok ".gitignore записан"

Say "Проверяю копию на строки, похожие на токены"
$patterns = @(
    '\b\d{8,11}:[A-Za-z0-9_-]{30,}\b',   # токен Telegram-бота
    'sk-(ant|or)-[A-Za-z0-9_-]{20,}',    # Anthropic / OpenRouter
    'AIza[0-9A-Za-z_-]{30,}',            # Google API key
    'ya29\.[0-9A-Za-z_-]{30,}',          # Google OAuth access token
    '"refresh_token"\s*:\s*"[^"]{20,}"', # Google OAuth refresh token
    'vk1\.a\.[A-Za-z0-9_-]{40,}'         # VK токен
)
$hits = Get-ChildItem $Dst -Recurse -File -Include *.py,*.json,*.txt,*.md,*.cmd,*.bat,*.ps1,*.yaml,*.yml,*.ini,*.cfg |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    Select-String -Pattern $patterns -List
if ($hits) {
    Write-Host "  Найдены возможные секреты, коммит остановлен:" -ForegroundColor Yellow
    $hits | ForEach-Object { Write-Host "    $($_.Path):$($_.LineNumber)" }
    Die "Уберите секреты из этих файлов (вынесите в отдельный файл-токен) и запустите снова."
}
Ok "Секретов не найдено"

Say "Коммичу и пушу"
git -C $Dst add -A
git -C $Dst -c user.name="fsimonov-ui" -c user.email="fsimonov@gmail.com" commit -q -m "Import publishing tools and dashboard from PC" 2>$null
git -C $Dst push -u origin HEAD
if ($LASTEXITCODE -ne 0) { Die "push не прошёл. Проверьте вход в GitHub (git credential manager)." }
Ok "Запушено: https://github.com/fsimonov-ui/academy-tools"

Write-Host "`nГотово. Напишите Claude: «academy-tools запушен»." -ForegroundColor Green
