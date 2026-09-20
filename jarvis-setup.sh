#!/usr/bin/env bash
# ============================================================================
# Установка J.A.R.V.I.S (голос + HUD для Hermes Agent) на VPS с Hermes
# ============================================================================
# Проект: https://github.com/eadmin2/jarvis_ai
#
# Что делает скрипт:
#   1. Включает API-сервер Hermes на loopback и генерирует ключи.
#   2. Ставит голосовой сервер Jarvis в /opt/jarvis: распознавание речи
#      Whisper на CPU (русский язык), синтез речи ElevenLabs, веб-панель HUD.
#   3. Выпускает самоподписанный TLS-сертификат для доступа к микрофону из браузера.
#   4. Создаёт службу systemd jarvis-voice и открывает порты HUD в файрволе.
#
# Запуск на сервере (от root, Hermes уже установлен):
#   curl -fsSL https://raw.githubusercontent.com/fsimonov-ui/Claud-repo/claude/installed-plugins-m9cztw/jarvis-setup.sh | bash
#
# Переменные (можно задать заранее, тогда скрипт не спросит):
#   ELEVENLABS_API_KEY   ключ ElevenLabs (elevenlabs.io → Profile → API Keys)
#   ELEVENLABS_VOICE_ID  id голоса, по умолчанию предустановленный голос ElevenLabs
#   JARVIS_NAME          имя для приветствия при запуске, по умолчанию Fedor
#   JARVIS_LANG          язык распознавания речи, по умолчанию ru
#   JARVIS_STT_MODEL     модель Whisper, по умолчанию small (мультиязычная)
# ============================================================================

set -euo pipefail

JARVIS_REPO="https://github.com/eadmin2/jarvis_ai"
JARVIS_DIR="/opt/jarvis"
HERMES_ENV="/root/.hermes/.env"
JARVIS_LANG="${JARVIS_LANG:-ru}"
JARVIS_STT_MODEL="${JARVIS_STT_MODEL:-small}"
JARVIS_NAME="${JARVIS_NAME:-Fedor}"
ELEVENLABS_VOICE_ID="${ELEVENLABS_VOICE_ID:-21m00Tcm4TlvDq8ikWAM}"

export PATH="/usr/local/bin:/root/.hermes/bin:/root/.local/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }
have_tty() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

ask() {
    local var="$1" prompt="$2" secret="${3:-}" value=""
    [ -n "${!var:-}" ] && return 0
    have_tty || die "Переменная $var не задана, а терминала для вопроса нет."
    while [ -z "$value" ]; do
        if [ "$secret" = "secret" ]; then
            read -r -s -p "$prompt: " value < /dev/tty; printf '\n' > /dev/tty
        else
            read -r -p "$prompt: " value < /dev/tty
        fi
    done
    printf -v "$var" '%s' "$value"
}

# читает значение из ~/.hermes/.env
env_get() { grep -E "^$1=" "$HERMES_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true; }

# ---------- проверки ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Запустите скрипт от root."
command -v hermes >/dev/null 2>&1 || die "Hermes не найден. Сначала установите Hermes."
systemctl is-active --quiet hermes-gateway || warn "Служба hermes-gateway не запущена, запущу после настройки."

say "Установка J.A.R.V.I.S для Hermes Agent"

# ---------- данные -------------------------------------------------------------
if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
    ELEVENLABS_API_KEY="$(env_get ELEVENLABS_API_KEY)"
fi
printf '\nКлюч ElevenLabs берётся на elevenlabs.io: Profile → API Keys. Бесплатного тарифа хватает.\n' > /dev/tty 2>/dev/null || true
ask ELEVENLABS_API_KEY "Ключ ElevenLabs" secret

PUBLIC_IP="$(curl -4 -fsS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
[ -n "$PUBLIC_IP" ] || die "Не удалось определить IP сервера."
ok "IP сервера: $PUBLIC_IP"

# ---------- пакеты и swap ------------------------------------------------------
say "Ставлю системные пакеты"
apt-get update -qq
apt-get -y -qq install git python3 python3-venv python3-dev build-essential \
    portaudio19-dev libsndfile1 ffmpeg openssl curl
ok "Пакеты установлены"

if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ] && [ ! -f /swapfile ]; then
    say "Добавляю 2 ГБ swap, чтобы модели речи не упирались в память"
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "swap включён"
fi

# ---------- Hermes API ------------------------------------------------------
say "Включаю API-сервер Hermes"
API_KEY="$(env_get API_SERVER_KEY)"
[ -n "$API_KEY" ] || API_KEY="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
HUD_TOKEN="$(env_get JARVIS_HUD_TOKEN)"
[ -n "$HUD_TOKEN" ] || HUD_TOKEN="jarvis-$(python3 -c 'import secrets;print(secrets.token_hex(3))')"

hermes config set API_SERVER_ENABLED true >/dev/null
hermes config set API_SERVER_KEY "$API_KEY" >/dev/null
hermes config set JARVIS_HUD_TOKEN "$HUD_TOKEN" >/dev/null
hermes config set ELEVENLABS_API_KEY "$ELEVENLABS_API_KEY" >/dev/null
chmod 600 "$HERMES_ENV" 2>/dev/null || true
systemctl restart hermes-gateway
sleep 8
if curl -fsS -m 10 -H "Authorization: Bearer $API_KEY" http://127.0.0.1:8642/health | grep -q ok; then
    ok "API Hermes отвечает на 127.0.0.1:8642"
else
    warn "API Hermes пока не отвечает, проверю ещё раз после установки"
fi

# ---------- код Jarvis ------------------------------------------------------
say "Скачиваю Jarvis в $JARVIS_DIR"
if [ -d "$JARVIS_DIR/.git" ]; then
    git -C "$JARVIS_DIR" pull -q --ff-only || warn "git pull не удался, оставляю текущую версию"
else
    git clone -q --depth 1 "$JARVIS_REPO" "$JARVIS_DIR"
fi
cd "$JARVIS_DIR/server"

say "Ставлю Python-зависимости (torch для CPU, Whisper, ElevenLabs). Это 5–10 минут"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q torch torchaudio --index-url https://download.pytorch.org/whl/cpu
.venv/bin/pip install -q fastapi uvicorn requests pyyaml numpy anthropic \
    RealtimeSTT faster-whisper silero-vad websockets psutil
ok "Зависимости установлены"

# Язык распознавания в оригинале зашит как английский. Берём его из конфига.
if grep -q 'language="en",' server.py; then
    sed -i 's/language="en",/language=cfg["stt"].get("language", "en"),/' server.py
    ok "server.py: язык распознавания читается из конфига"
fi

# ---------- конфиг ---------------------------------------------------------------
say "Пишу config/server.yaml"
[ -f config/server.yaml ] || cp config/server.example.yaml config/server.yaml
PUBLIC_IP="$PUBLIC_IP" VOICE_ID="$ELEVENLABS_VOICE_ID" LANG_CODE="$JARVIS_LANG" STT_MODEL="$JARVIS_STT_MODEL" \
.venv/bin/python - <<'PY'
import os, yaml
p = "config/server.yaml"
cfg = yaml.safe_load(open(p, encoding="utf-8"))
cfg.setdefault("stt", {})
cfg["stt"]["model"] = os.environ["STT_MODEL"]
cfg["stt"]["language"] = os.environ["LANG_CODE"]
cfg["machines"] = []
cfg.setdefault("server", {})
cfg["server"]["host"] = "0.0.0.0"
cfg["server"]["port"] = 8765
cfg["server"]["tls_ports"] = [443, 8766]
cfg.setdefault("security", {})
cfg["security"]["extra_origin_hosts"] = [os.environ["PUBLIC_IP"]]
cfg.setdefault("voice", {})
cfg["voice"]["voice_id"] = os.environ["VOICE_ID"]
cfg["voice"]["voice_name"] = "ElevenLabs voice"
cfg["voice"]["model"] = "eleven_flash_v2_5"
cfg.setdefault("hermes", {})
instr = (cfg["hermes"].get("instructions") or "").strip()
if "русск" not in instr.lower():
    instr += " Всегда отвечай на русском языке, если пользователь не попросил иначе."
cfg["hermes"]["instructions"] = instr
yaml.safe_dump(cfg, open(p, "w", encoding="utf-8"), allow_unicode=True, sort_keys=False)
print("ok")
PY
ok "Конфиг записан: язык $JARVIS_LANG, модель $JARVIS_STT_MODEL, голос $ELEVENLABS_VOICE_ID"

# ---------- сертификат -----------------------------------------------------------
say "Выпускаю самоподписанный сертификат для $PUBLIC_IP"
if [ ! -f certs/cert.pem ] || ! openssl x509 -in certs/cert.pem -noout -text | grep -q "$PUBLIC_IP"; then
    bash scripts/make-certs.sh "$PUBLIC_IP" >/dev/null
fi
ok "Сертификат: certs/cert.pem"

# ---------- приветствие при запуске ------------------------------------------------
say "Синтезирую приветствие при запуске (ElevenLabs, около 110 символов)"
if bash scripts/make-boot-audio.sh "$JARVIS_NAME" >/dev/null 2>&1 && ls hud/audio/boot_morning.mp3 >/dev/null 2>&1; then
    ok "Приветствие записано"
else
    warn "Приветствие не синтезировалось. Проверьте ключ ElevenLabs и voice_id. Это не мешает работе."
fi

# ---------- служба ---------------------------------------------------------------
say "Создаю службу jarvis-voice"
cat > /etc/systemd/system/jarvis-voice.service <<EOF
[Unit]
Description=J.A.R.V.I.S voice server for Hermes Agent
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$JARVIS_DIR/server
ExecStart=$JARVIS_DIR/server/.venv/bin/python server.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now jarvis-voice >/dev/null
ok "Служба запущена. Первый старт качает модель Whisper, это 1–3 минуты"

# ---------- файрвол -----------------------------------------------------------------
say "Открываю порты HUD"
ufw allow 443/tcp >/dev/null
ufw allow 8766/tcp >/dev/null
ufw allow 9443/tcp >/dev/null
ok "Открыты 443, 8766, 9443. Порт 8765 без шифрования остаётся закрытым"

# ---------- проверка ---------------------------------------------------------------
say "Жду запуска голосового сервера"
for i in $(seq 1 36); do
    if curl -sk -m 3 "https://127.0.0.1/hud/" -o /dev/null 2>/dev/null; then break; fi
    sleep 5
done
if curl -sk -m 3 "https://127.0.0.1/hud/" -o /dev/null 2>/dev/null; then
    ok "HUD отвечает"
else
    warn "HUD ещё не поднялся. Логи: journalctl -u jarvis-voice -n 50"
fi
curl -fsS -m 10 -H "Authorization: Bearer $API_KEY" http://127.0.0.1:8642/health | grep -q ok \
    && ok "API Hermes отвечает" || warn "API Hermes не отвечает: journalctl -u hermes-gateway -n 50"

cat <<EOF

  Готово.

  Панель Jarvis:   https://$PUBLIC_IP/hud/
  Токен входа:     $HUD_TOKEN

  Как открыть в первый раз:
    1. Откройте адрес выше в Chrome или Safari.
    2. Браузер предупредит о сертификате. Нажмите «Дополнительно» → «Перейти».
       На iPhone сначала скачайте https://$PUBLIC_IP/hud/jarvis.cer, установите профиль
       и включите доверие в Настройки → Основные → Об этом устройстве → Доверие сертификатам.
    3. Введите токен входа.
    4. Нажмите на кольцо, скажите фразу, нажмите ещё раз. Ответ придёт голосом.

  Команды на сервере:
    systemctl status jarvis-voice          состояние
    journalctl -u jarvis-voice -f          логи
    systemctl restart jarvis-voice         перезапуск
    nano $JARVIS_DIR/server/config/server.yaml   настройки (голос, язык, модель)

  Сменить голос: найдите voice_id на elevenlabs.io → Voices и запишите в voice.voice_id.

EOF
