#!/usr/bin/env bash
# ============================================================================
# Переключение Hermes Agent на бесплатную модель OpenRouter
# ============================================================================
# Скрипт запрашивает каталог OpenRouter, оставляет только бесплатные модели
# (суффикс :free), умеющие вызывать инструменты, ранжирует их и записывает
# лучшую в настройки Hermes. Затем перезапускает шлюз.
#
# Запуск на сервере (от root):
#   curl -fsSL https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/hermes-free-model.sh | bash
#
# Выбрать конкретную модель вручную:
#   curl -fsSL .../hermes-free-model.sh | bash -s -- qwen/qwen3-235b-a22b:free
#
# Только показать список без изменений:
#   curl -fsSL .../hermes-free-model.sh | bash -s -- --list
# ============================================================================

set -euo pipefail

export PATH="/usr/local/bin:/root/.hermes/bin:/root/.local/bin:$PATH"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

command -v hermes >/dev/null 2>&1 || die "Команда hermes не найдена. Сначала установите Hermes."

MODE="auto"
WANTED=""
case "${1:-}" in
    "") ;;
    --list) MODE="list" ;;
    *) MODE="manual"; WANTED="$1" ;;
esac

say "Запрашиваю каталог бесплатных моделей OpenRouter (по IPv4, до 5 минут)"
CATALOG=""
if CATALOG="$(curl -4 -fsS -m 300 --retry 2 --retry-delay 5 --retry-all-errors \
        https://openrouter.ai/api/v1/models 2>/tmp/openrouter_catalog.err)"; then
    ok "Каталог загружен"
else
    printf '  ! Каталог не скачался (%s)\n' "$(tr -d '\n' </tmp/openrouter_catalog.err)"
    printf '  ! Проверяю известные бесплатные модели поштучно\n'
fi

rank_catalog() {
    python3 -c '
import sys, json

data = json.load(sys.stdin)["data"]
free = [m for m in data
        if m["id"].endswith(":free")
        and "tools" in (m.get("supported_parameters") or [])]

# Семейства моделей в порядке предпочтения для агентной работы.
pref = ["deepseek", "qwen3", "qwen", "kimi", "glm", "minimax", "llama", "gemini", "mistral", "gpt", "gemma"]

def rank(m):
    mid = m["id"].lower()
    fam = next((i for i, w in enumerate(pref) if w in mid), len(pref))
    return (fam, -(m.get("context_length") or 0), -(m.get("created") or 0))

free.sort(key=rank)
for m in free:
    ctx = m.get("context_length") or 0
    print(m["id"] + "\t" + str(ctx // 1000) + "k")
'
}

# Запасной список: проверяем каждую модель маленьким запросом к OpenRouter,
# оставляем те, что существуют и поддерживают инструменты.
CANDIDATES=(
    deepseek/deepseek-chat-v3.1:free
    deepseek/deepseek-chat-v3-0324:free
    deepseek/deepseek-r1-0528:free
    qwen/qwen3-235b-a22b:free
    qwen/qwen3-coder:free
    moonshotai/kimi-k2:free
    z-ai/glm-4.5-air:free
    meta-llama/llama-3.3-70b-instruct:free
    google/gemini-2.0-flash-exp:free
    mistralai/mistral-small-3.2-24b-instruct:free
    openai/gpt-oss-120b:free
)

probe_candidates() {
    local id info
    for id in "${CANDIDATES[@]}"; do
        info="$(curl -4 -fsS -m 25 "https://openrouter.ai/api/v1/models/${id%:free}/endpoints" 2>/dev/null || true)"
        [ -n "$info" ] || continue
        printf '%s' "$info" | python3 -c '
import sys, json
wanted = sys.argv[1]
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    sys.exit(1)
eps = d.get("endpoints") or []
free = [e for e in eps
        if float((e.get("pricing") or {}).get("prompt") or 0) == 0
        and "tools" in (e.get("supported_parameters") or [])]
if not free:
    sys.exit(1)
ctx = max((e.get("context_length") or 0) for e in free)
print(wanted + "\t" + str(ctx // 1000) + "k")
' "$id" || true
    done
}

if [ -n "$CATALOG" ]; then
    RANKED="$(printf '%s' "$CATALOG" | rank_catalog)"
else
    RANKED="$(probe_candidates)"
fi

[ -n "$RANKED" ] || die "Не нашёл ни одной бесплатной модели с поддержкой инструментов. Попробуйте позже."

printf '\n  Бесплатные модели с поддержкой инструментов (лучшие сверху):\n'
printf '%s\n' "$RANKED" | head -12 | awk -F'\t' '{ printf "    %-52s контекст %s\n", $1, $2 }'

if [ "$MODE" = "list" ]; then
    exit 0
fi

if [ "$MODE" = "manual" ]; then
    MODEL="$WANTED"
    printf '%s\n' "$RANKED" | cut -f1 | grep -qx "$MODEL" \
        || die "Модель $MODEL не найдена среди бесплатных с поддержкой инструментов."
else
    MODEL="$(printf '%s\n' "$RANKED" | head -1 | cut -f1)"
fi

say "Записываю модель $MODEL"
hermes config set model.provider openrouter >/dev/null
hermes config set model.default "$MODEL" >/dev/null
ok "model.provider = openrouter"
ok "model.default = $MODEL"

say "Перезапускаю шлюз"
systemctl restart hermes-gateway
sleep 4
hermes gateway status --system || true

cat <<EOF

  Готово. Напишите боту в Telegram.

  Ограничения бесплатных моделей OpenRouter:
    - 50 запросов в сутки на аккаунт без покупок; 1000 в сутки, если хоть раз
      пополняли баланс на 10 долларов
    - модели слабее Claude и иногда бывают перегружены (ошибка 429)

  Сменить модель на другую из списка выше:
    curl -fsSL https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/hermes-free-model.sh | bash -s -- ИМЯ_МОДЕЛИ

EOF
