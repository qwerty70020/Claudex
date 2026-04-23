#!/bin/bash
# claudex installer for Termux
# Usage: bash install-termux.sh

set -e

REPO="https://github.com/qwerty70020/claudex.git"
TARBALL_NAME="letchu_pkt-claudex-1.1.0.tgz"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
die()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# ── 1. Зависимости ────────────────────────────────────────────────────────────
section "Установка зависимостей"
pkg install -y nodejs-lts git ripgrep proot-distro curl 2>/dev/null || \
  pkg install -y nodejs git ripgrep proot-distro curl
info "Зависимости установлены"

# ── 2. Ubuntu ─────────────────────────────────────────────────────────────────
section "Установка Ubuntu (proot-distro)"
if proot-distro list | grep -q "ubuntu.*installed"; then
  info "Ubuntu уже установлена"
else
  proot-distro install ubuntu
  info "Ubuntu установлена"
fi

# ── 3. Сборка внутри Ubuntu ───────────────────────────────────────────────────
section "Сборка claudex внутри Ubuntu"
proot-distro login ubuntu -- bash -c '
  set -e

  # bun
  if ! command -v bun &>/dev/null; then
    curl -fsSL https://bun.sh/install | bash
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
  fi
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"

  # клонируем или обновляем
  if [ -d ~/claudex/.git ]; then
    cd ~/claudex && git pull origin main
  else
    git clone '"$REPO"' ~/claudex
    cd ~/claudex
  fi

  bun install
  bun run build
  npm pack
  mv letchu_pkt-claudex-*.tgz /sdcard/
  echo "BUILD_OK"
' | grep -q "BUILD_OK" || die "Сборка не удалась"
info "Сборка успешна"

# ── 4. Установка в Termux ─────────────────────────────────────────────────────
section "Установка claudex в Termux"
TARBALL=$(ls /sdcard/letchu_pkt-claudex-*.tgz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && die "Tarball не найден в /sdcard/"

# удаляем старую версию если есть
npm uninstall -g @letchu_pkt/claudex 2>/dev/null || true
rm -f "$PREFIX/bin/claudex"

npm install -g "$TARBALL"
rm -f "$TARBALL"
info "claudex установлен"

# ── 5. Переменные окружения ───────────────────────────────────────────────────
section "Настройка окружения"

RC_FILE="$HOME/.zshrc"
[ ! -f "$RC_FILE" ] && RC_FILE="$HOME/.bashrc"

MARKER="# >>> claudex-termux >>>"
if grep -q "$MARKER" "$RC_FILE" 2>/dev/null; then
  warn "Env vars уже настроены в $RC_FILE, пропускаю"
else
  cat >> "$RC_FILE" <<EOF

$MARKER
export CLAUDE_CODE_TMPDIR=\$PREFIX/tmp
export DISABLE_AUTOUPDATER=1
export SSL_CERT_FILE=\$PREFIX/etc/tls/cert.pem
export NODE_EXTRA_CA_CERTS=\$PREFIX/etc/tls/cert.pem
# <<< claudex-termux <<<
EOF
  info "Env vars добавлены в $RC_FILE"
fi

mkdir -p "$PREFIX/tmp"

# ── 6. Провайдер ──────────────────────────────────────────────────────────────
section "Настройка провайдера"

PROFILE_FILE="$HOME/.claude/.claudex-profile.json"
if [ -f "$PROFILE_FILE" ]; then
  info "Профиль провайдера уже существует, пропускаю"
else
  echo ""
  echo "Выбери провайдера:"
  echo "  1. NVIDIA (бесплатно, build.nvidia.com)"
  echo "  2. OpenRouter (бесплатно, openrouter.ai)"
  echo "  3. Пропустить (настрою позже)"
  read -rp "Выбор [1]: " PROVIDER_CHOICE
  PROVIDER_CHOICE="${PROVIDER_CHOICE:-1}"

  mkdir -p "$HOME/.claude"

  case "$PROVIDER_CHOICE" in
    1)
      read -rp "NVIDIA API Key (nvapi-...): " NVIDIA_KEY
      read -rp "Модель [qwen/qwen3-coder-480b-a35b-instruct]: " NVIDIA_MODEL
      NVIDIA_MODEL="${NVIDIA_MODEL:-qwen/qwen3-coder-480b-a35b-instruct}"
      cat > "$PROFILE_FILE" <<EOF
{
  "profile": "nvidia",
  "env": {
    "CLAUDE_CODE_USE_NVIDIA": "1",
    "NVIDIA_API_KEY": "$NVIDIA_KEY",
    "NVIDIA_BASE_URL": "https://integrate.api.nvidia.com/v1",
    "NVIDIA_MODEL": "$NVIDIA_MODEL"
  }
}
EOF
      info "Профиль NVIDIA сохранён"
      ;;
    2)
      read -rp "OpenRouter API Key (sk-or-...): " OR_KEY
      read -rp "Модель [qwen/qwen3-coder:free]: " OR_MODEL
      OR_MODEL="${OR_MODEL:-qwen/qwen3-coder:free}"
      cat > "$PROFILE_FILE" <<EOF
{
  "profile": "openrouter",
  "env": {
    "CLAUDE_CODE_USE_OPENAI": "1",
    "OPENAI_API_KEY": "$OR_KEY",
    "OPENAI_BASE_URL": "https://openrouter.ai/api/v1",
    "OPENAI_MODEL": "$OR_MODEL"
  }
}
EOF
      info "Профиль OpenRouter сохранён"
      ;;
    *)
      warn "Провайдер не настроен. Запусти 'claudex' и настрой вручную."
      ;;
  esac
fi

# ── 7. Готово ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════╗${NC}"
echo -e "${GREEN}║   claudex установлен успешно!    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════╝${NC}"
echo ""
echo "Запусти новую сессию Termux и выполни:"
echo "  claudex"
