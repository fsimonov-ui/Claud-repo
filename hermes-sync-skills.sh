#!/usr/bin/env bash
# ============================================================================
# Синхронизация навыков Claude Code из репозитория claude-config в Hermes на VPS
# ============================================================================
# Репозиторий fsimonov-ui/claude-config приватный, поэтому серверу нужен
# deploy-ключ. Скрипт при первом запуске создаёт ключ и показывает, что
# добавить в GitHub: Settings → Deploy keys → Add deploy key (только чтение).
#
# После добавления ключа скрипт клонирует репозиторий в /opt/claude-config,
# подключает каждую папку skills/* в ~/.hermes/skills/ символической ссылкой
# и ставит cron на обновление раз в час.
#
# Запуск на сервере (от root):
#   curl -fsSL https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/hermes-sync-skills.sh | bash
# Повторный запуск безопасен: только обновляет.
# ============================================================================

set -euo pipefail

REPO_SSH="git@github.com:fsimonov-ui/claude-config.git"
REPO_DIR="/opt/claude-config"
KEY="/root/.ssh/claude-config-deploy"
HERMES_SKILLS="/root/.hermes/skills"
BRANCH="${CLAUDE_CONFIG_BRANCH:-main}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root."
command -v git >/dev/null || apt-get -y -qq install git

# ---------- deploy-ключ ---------------------------------------------------------
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "hermes-vps claude-config deploy" -f "$KEY"
fi
# git будет ходить в GitHub именно этим ключом
if ! grep -q 'Host github.com-claude-config' /root/.ssh/config 2>/dev/null; then
    cat >> /root/.ssh/config <<EOF
Host github.com-claude-config
    HostName github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF
    chmod 600 /root/.ssh/config
fi
ssh-keyscan -t ed25519 github.com 2>/dev/null >> /root/.ssh/known_hosts.tmp || true
if [ -s /root/.ssh/known_hosts.tmp ]; then
    touch /root/.ssh/known_hosts
    grep -qF "$(cat /root/.ssh/known_hosts.tmp)" /root/.ssh/known_hosts || cat /root/.ssh/known_hosts.tmp >> /root/.ssh/known_hosts
fi
rm -f /root/.ssh/known_hosts.tmp
REPO_URL="git@github.com-claude-config:fsimonov-ui/claude-config.git"

say "Проверяю доступ к репозиторию"
if ! git ls-remote -q "$REPO_URL" HEAD >/dev/null 2>&1; then
    cat <<EOF

  Серверу ещё не выдан доступ к приватному репозиторию claude-config.

  1. Откройте https://github.com/fsimonov-ui/claude-config/settings/keys
  2. Нажмите «Add deploy key», Title: hermes-vps, галочку «Allow write access» НЕ ставьте.
  3. В поле Key вставьте эту строку целиком:

$(cat "$KEY.pub")

  4. Сохраните и запустите этот скрипт ещё раз.

EOF
    exit 2
fi
ok "Доступ есть"

# ---------- клон / обновление -------------------------------------------------------
if [ -d "$REPO_DIR/.git" ]; then
    say "Обновляю $REPO_DIR"
    git -C "$REPO_DIR" fetch -q origin "$BRANCH"
    git -C "$REPO_DIR" reset -q --hard "origin/$BRANCH"
else
    say "Клонирую claude-config в $REPO_DIR"
    git clone -q --depth 1 -b "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi
ok "Версия: $(git -C "$REPO_DIR" log -1 --format='%h %ad' --date=short)"

# ---------- подключение навыков -----------------------------------------------------
say "Подключаю навыки в $HERMES_SKILLS"
mkdir -p "$HERMES_SKILLS"
n=0
for d in "$REPO_DIR"/skills/*/; do
    name="$(basename "$d")"
    [ -f "$d/SKILL.md" ] || continue
    target="$HERMES_SKILLS/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        warn "$name: в Hermes уже есть своя папка с таким именем, пропускаю"
        continue
    fi
    ln -sfn "$d" "$target"
    n=$((n + 1))
done
ok "Подключено навыков: $n"
ls -1 "$HERMES_SKILLS" | sed 's/^/    /'

# ---------- автообновление -----------------------------------------------------------
SELF="/usr/local/bin/hermes-sync-skills"
if [ "${BASH_SOURCE[0]:-}" != "$SELF" ]; then
    curl -fsSL "https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/hermes-sync-skills.sh" -o "$SELF" 2>/dev/null \
        && chmod +x "$SELF" || warn "Не удалось сохранить копию скрипта для cron"
fi
if [ -x "$SELF" ]; then
    echo "17 * * * * root $SELF >/var/log/hermes-sync-skills.log 2>&1" > /etc/cron.d/hermes-sync-skills
    ok "cron: обновление каждый час в :17, лог /var/log/hermes-sync-skills.log"
fi

echo
echo "  Готово. Hermes увидит новые навыки при следующем разговоре (или после /new в Telegram)."
echo
