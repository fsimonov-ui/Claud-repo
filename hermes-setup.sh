#!/usr/bin/env bash
# ============================================================================
# Установка Hermes Agent (Nous Research) на чистый VPS с Ubuntu 24.04
# ============================================================================
# Что делает скрипт:
#   1. Спрашивает ключ модели (Anthropic или OpenRouter), токен Telegram-бота
#      и ваш Telegram user ID.
#   2. Обновляет систему, включает файрвол (ufw) и защиту SSH (fail2ban).
#   3. Ставит Hermes Agent официальным установщиком.
#   4. Записывает ключи в ~/.hermes/.env, выбирает модель.
#   5. Устанавливает шлюз мессенджеров как системную службу и запускает его.
#
# Запуск на сервере (от root):
#   curl -fsSL https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/hermes-setup.sh | bash
#
# Можно заранее задать переменные, тогда скрипт ничего не спросит:
#   ANTHROPIC_API_KEY=sk-ant-...  TELEGRAM_BOT_TOKEN=123:abc  TELEGRAM_ALLOWED_USERS=123456789 \
#     bash <(curl -fsSL .../hermes-setup.sh)
#
# Дополнительные переменные:
#   OPENROUTER_API_KEY   ключ OpenRouter вместо Anthropic
#   HERMES_MODEL         модель, по умолчанию anthropic/claude-sonnet-5
#   HERMES_TIMEZONE      часовой пояс, например Europe/Moscow
#   SKIP_BROWSER=1       не ставить Chromium (браузерные инструменты работать не будут)
# ============================================================================

set -euo pipefail

INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
DEFAULT_ANTHROPIC_MODEL="anthropic/claude-sonnet-5"
DEFAULT_OPENROUTER_MODEL="openrouter/anthropic/claude-sonnet-5"

# ---------- вспомогательные функции ----------------------------------------
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

have_tty() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

# ask VAR "Подсказка" [secret]
ask() {
    local var="$1" prompt="$2" secret="${3:-}" value=""
    if [ -n "${!var:-}" ]; then
        return 0
    fi
    have_tty || die "Переменная $var не задана, а терминала для вопроса нет. Задайте её через окружение."
    while [ -z "$value" ]; do
        if [ "$secret" = "secret" ]; then
            read -r -s -p "$prompt: " value < /dev/tty
            printf '\n' > /dev/tty
        else
            read -r -p "$prompt: " value < /dev/tty
        fi
    done
    printf -v "$var" '%s' "$value"
}

# ---------- проверки ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Запустите скрипт от пользователя root."
[ -r /etc/os-release ] || die "Не удалось определить ОС."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Скрипт рассчитан на Ubuntu или Debian, найдено: ${PRETTY_NAME:-неизвестно}." ;;
esac

say "Установка Hermes Agent на ${PRETTY_NAME}"

# ---------- сбор данных -----------------------------------------------------
PROVIDER=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    PROVIDER="anthropic"
elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
    PROVIDER="openrouter"
else
    have_tty || die "Задайте ANTHROPIC_API_KEY или OPENROUTER_API_KEY через окружение."
    printf '\nКакой ключ к модели используем?\n  1) Anthropic  (console.anthropic.com)\n  2) OpenRouter (openrouter.ai)\n' > /dev/tty
    choice=""
    while [ "$choice" != "1" ] && [ "$choice" != "2" ]; do
        read -r -p "Введите 1 или 2: " choice < /dev/tty
    done
    if [ "$choice" = "1" ]; then
        PROVIDER="anthropic"
        ask ANTHROPIC_API_KEY "Ключ Anthropic (начинается с sk-ant-)" secret
    else
        PROVIDER="openrouter"
        ask OPENROUTER_API_KEY "Ключ OpenRouter (начинается с sk-or-)" secret
    fi
fi

printf '\nТокен бота выдаёт @BotFather в Telegram (команда /newbot).\n' > /dev/tty 2>/dev/null || true
ask TELEGRAM_BOT_TOKEN "Токен Telegram-бота" secret
[[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "Токен бота выглядит неверно. Формат: 123456789:AAAbbbCCC..."

printf '\nВаш числовой Telegram ID подскажет бот @userinfobot. Это НЕ @username.\n' > /dev/tty 2>/dev/null || true
ask TELEGRAM_ALLOWED_USERS "Ваш Telegram ID (несколько через запятую)"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS// /}"
[[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Telegram ID должен состоять только из цифр."

if [ "$PROVIDER" = "anthropic" ]; then
    HERMES_MODEL="${HERMES_MODEL:-$DEFAULT_ANTHROPIC_MODEL}"
else
    HERMES_MODEL="${HERMES_MODEL:-$DEFAULT_OPENROUTER_MODEL}"
fi

# ---------- система -----------------------------------------------------------
say "Обновляю систему и ставлю базовые пакеты"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y -qq install curl git ca-certificates ufw fail2ban unattended-upgrades
ok "Пакеты установлены"

if [ -n "${HERMES_TIMEZONE:-}" ]; then
    timedatectl set-timezone "$HERMES_TIMEZONE" && ok "Часовой пояс: $HERMES_TIMEZONE"
fi

say "Включаю файрвол и защиту SSH"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null
ok "ufw: открыт только SSH"

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban не запустился, продолжаю"
systemctl restart fail2ban >/dev/null 2>&1 || true
ok "fail2ban защищает SSH"

# ---------- Hermes -----------------------------------------------------------
say "Ставлю Hermes Agent (это займёт несколько минут)"
INSTALL_ARGS=(--skip-setup --non-interactive)
if [ "${SKIP_BROWSER:-0}" = "1" ]; then
    INSTALL_ARGS+=(--skip-browser)
fi
curl -fsSL "$INSTALLER_URL" | bash -s -- "${INSTALL_ARGS[@]}"

# Ищем исполняемый файл hermes
export PATH="/usr/local/bin:/root/.hermes/bin:/root/.local/bin:$PATH"
if ! command -v hermes >/dev/null 2>&1; then
    die "Команда hermes не найдена после установки. Посмотрите вывод выше."
fi
HERMES_BIN="$(command -v hermes)"
ok "Hermes установлен: $HERMES_BIN"

# ---------- конфигурация ----------------------------------------------------
say "Записываю ключи и настройки"
mkdir -p /root/.hermes
if [ "$PROVIDER" = "anthropic" ]; then
    hermes config set ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY" >/dev/null
else
    hermes config set OPENROUTER_API_KEY "$OPENROUTER_API_KEY" >/dev/null
fi
hermes config set TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN" >/dev/null
hermes config set TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS" >/dev/null
if [ -n "${HERMES_TIMEZONE:-}" ]; then
    hermes config set HERMES_TIMEZONE "$HERMES_TIMEZONE" >/dev/null || true
fi
chmod 600 /root/.hermes/.env 2>/dev/null || true
ok "Ключи сохранены в /root/.hermes/.env"

if hermes config set model "$HERMES_MODEL" >/dev/null 2>&1; then
    ok "Модель: $HERMES_MODEL"
else
    warn "Не удалось выставить модель $HERMES_MODEL автоматически."
    warn "После установки выполните: hermes model"
fi

# ---------- служба шлюза ----------------------------------------------------
say "Устанавливаю и запускаю шлюз Telegram как системную службу"
hermes gateway install --system
hermes gateway start --system
sleep 5
hermes gateway status --system || true

# ---------- итог ---------------------------------------------------------------
say "Готово"
cat <<EOF

  Напишите вашему боту в Telegram любое сообщение, он должен ответить.

  Полезные команды на сервере:
    hermes                              чат с агентом прямо в терминале
    hermes model                        сменить модель или провайдера
    hermes doctor                       диагностика
    hermes gateway status --system      состояние шлюза
    journalctl -u hermes-gateway -f     живые логи шлюза
    hermes update                       обновить Hermes

  Файлы:
    /root/.hermes/.env                  ключи и токены
    /root/.hermes/config.yaml           настройки

EOF
