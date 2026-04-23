# Termux Installer — Сессионные заметки для нового чата

> Этот файл — полный технический бриф по всему, что было выяснено и сделано.
> Для нового чата: читай это первым делом, не задавай вопросов — просто работай.

---

## 1. Контекст проекта

**Claudex** — форк Claude Code (Anthropic) с поддержкой сторонних провайдеров (NVIDIA, OpenRouter).
- Репо: `https://github.com/qwerty70020/claudex.git`
- Пакет: `@letchu_pkt/claudex`, версия `1.1.0`
- Ветка с Termux-патчами: `claude/fix-termux-permissions-aSE71` (бывшая `claudex-termux`)

**Среда пользователя:**
- Android + Termux (без root в самом Termux)
- `$PREFIX` = `/data/data/com.termux/files/usr`
- `$HOME` = `/data/data/com.termux/files/home`
- Ubuntu-окружение через **VauSH/androsh** (кастомный chroot-менеджер, НЕ proot-distro!)
- Node.js v24+ доступен нативно в Termux
- bun — только внутри Ubuntu (не работает нативно в Termux из-за bionic libc)

---

## 2. Все Termux-патчи в claudex (уже применены в ветке)

### 2.1 `src/utils/permissions/filesystem.ts` (line ~334)
```diff
- process.env.CLAUDE_CODE_TMPDIR || (getPlatform() === 'windows' ? tmpdir() : '/tmp')
+ process.env.CLAUDE_CODE_TMPDIR || tmpdir()
```
**Причина:** `/tmp` не существует в Termux → EACCES при старте.

### 2.2 `src/utils/Shell.ts`
```diff
+ import { tmpdir } from 'os'

# Shell search paths — Termux first:
+ const shellPaths = process.env.PREFIX
+   ? [`${process.env.PREFIX}/bin`, '/bin', '/usr/bin', '/usr/local/bin']
+   : ['/bin', '/usr/bin', '/usr/local/bin', '/opt/homebrew/bin']

# /tmp → tmpdir() (line ~205)
- /tmp/...
+ tmpdir()/...

# /bin/sh replacement:
+ const POSIX_SH = process.env.PREFIX ? `${process.env.PREFIX}/bin/sh` : '/bin/sh'
+ const sandboxBinShell = isSandboxedPowerShell ? POSIX_SH : binShell
+ const spawnBinary = isSandboxedPowerShell ? POSIX_SH : binShell
```
**Причина:** `/bin/bash`, `/bin/sh` не существуют в Termux.

### 2.3 `src/utils/tmuxSocket.ts` (line ~381)
```diff
+ import { tmpdir } from 'os'
- process.env.TMPDIR || '/tmp'
+ process.env.TMPDIR || tmpdir()
```

### 2.4 `src/utils/ripgrep.ts` (lines 33-47)
```typescript
const getRipgrepConfig = memoize((): RipgrepConfig => {
  const isTermux = !!process.env.PREFIX && process.platform === 'linux'
  const userWantsSystemRipgrep =
    isTermux || isEnvDefinedFalsy(process.env.USE_BUILTIN_RIPGREP)
  if (userWantsSystemRipgrep) {
    return { mode: 'system', command: 'rg', args: [] }
  }
  // ...vendor binary fallback...
})
```
**Причина:** Vendor rg (glibc binary) зависает на 4+ минуты на Android bionic libc.
Vendor binary — glibc-скомпилированный, несовместим с bionic, вызывает hang (не crash!).
Системный `rg` из пакета `ripgrep` в Termux работает нормально.

### 2.5 `src/utils/terminalPanel.ts` (lines 84, 183)
```diff
- process.env.SHELL || '/bin/bash'
+ process.env.SHELL || (process.env.PREFIX ? `${process.env.PREFIX}/bin/bash` : '/bin/bash')
```

### 2.6 `src/upstreamproxy/upstreamproxy.ts` (line ~32)
```diff
- const SYSTEM_CA_BUNDLE = '/etc/ssl/certs/ca-certificates.crt'
+ const SYSTEM_CA_BUNDLE = process.env.PREFIX
+   ? `${process.env.PREFIX}/etc/ssl/certs/ca-certificates.crt`
+   : '/etc/ssl/certs/ca-certificates.crt'
```

### 2.7 `src/components/Settings/Config.tsx`
```typescript
// Добавлена пропущенная функция (вызывала build error):
function getSubagentModelLabel(value: string | null): string {
  if (value === null) return "Default (leader's model)";
  return modelDisplayString(value);
}

// Исправлен импорт:
// Было: '../ThemePicker.js'
// Стало: '../theme/ThemePicker.js'
```

---

## 3. Переменные окружения для Termux (`~/.zshrc` / `~/.bashrc`)

```bash
# >>> claudex-termux >>>
export CLAUDE_CODE_TMPDIR=$PREFIX/tmp
export DISABLE_AUTOUPDATER=1
export SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem
export NODE_EXTRA_CA_CERTS=$PREFIX/etc/tls/cert.pem
# <<< claudex-termux <<<
```

**ВАЖНО:** Эти переменные текут в Ubuntu chroot и ломают curl/apt.
Решение: в скриптах внутри Ubuntu делать `unset SSL_CERT_FILE` перед curl.

---

## 4. Система VauSH / androsh

### Что это
- **VauSH** — Python-приложение для управления Linux-окружениями на Android
- **androsh** — CLI wrapper, устанавливается как `/data/data/com.termux/files/usr/bin/androsh`
- Два режима: **chroot** (с root через su) и **proot** (через Shizuku, без root)
- Rootfs хранится в: `/data/local/tmp/VauSH/distros/<name>/rootfs/`

### Ключевые команды
```bash
androsh envs                           # список установленных окружений
androsh setup ubuntu -d ubuntu         # установить Ubuntu
androsh launch ubuntu                  # интерактивный вход
androsh launch ubuntu --run "command"  # выполнить команду и выйти
androsh remove ubuntu                  # удалить окружение
```

### Как работает `--run`
`androsh launch ubuntu --run "bash /sdcard/build.sh"` вызывает:
```bash
# chroot mode:
chroot "$ROOTFS" /bin/sh -c "export PATH=...; bash /sdcard/build.sh"

# proot mode:
$PROOT_BIN $ARGS /bin/sh -c "bash /sdcard/build.sh"
```

### Монтирование внутри chroot
- `/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm` — всегда
- `/sdcard` → bind-mount к `/storage/emulated/0` (или `/sdcard` Android)
- В proot-режиме дополнительно: `/data`, `/data/data`, etc.

### Критически важно
- **`/sdcard` — FAT32/exFAT**: не поддерживает symlinks → нельзя запускать `npm install` прямо с sdcard
- Промежуточный файл (tarball) копировать: Ubuntu→`/sdcard`→Termux `$HOME`→`npm install`

---

## 5. Сборка claudex — полный pipeline

### Требования
- Внутри Ubuntu: `bun`, `git`, `node`, `npm`
- В Termux: `node`, `npm`

### Процесс
```bash
# Внутри Ubuntu:
git clone https://github.com/qwerty70020/claudex.git ~/claudex
# или update:
cd ~/claudex && git fetch origin && git reset --hard origin/main

bun install          # ОБЯЗАТЕЛЬНО перед build
bun run build
npm pack             # создаёт letchu_pkt-claudex-1.1.0.tgz

cp letchu_pkt-claudex-*.tgz /sdcard/

# В Termux:
cp /sdcard/letchu_pkt-claudex-*.tgz $HOME/
npm install -g $HOME/letchu_pkt-claudex-*.tgz   # НЕ npm install -g . (создаёт symlink)
rm $HOME/letchu_pkt-claudex-*.tgz
```

### Почему npm pack, а не npm install -g .
`npm install -g .` создаёт symlink на source dir. Если source удалить → установка сломана.
`npm pack` + `npm install -g tarball` — копия, работает независимо.

---

## 6. Функция `install_claudex()` для Termux_install_all.sh

```bash
install_claudex() {
  section "Установка claudex"

  command -v androsh &>/dev/null || die "androsh не найден в PATH"
  ANDROSH_ENV="${ANDROSH_ENV:-ubuntu}"

  # Скрипт сборки (выполняется внутри Ubuntu через /sdcard)
  cat > /sdcard/claudex-build.sh << 'BUILDEOF'
#!/bin/bash
set -e

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
if ! command -v bun &>/dev/null; then
  unset SSL_CERT_FILE  # не пускаем сертификат Termux в curl
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi

if [ -d ~/claudex/.git ]; then
  cd ~/claudex
  git fetch origin
  git reset --hard origin/main
else
  git clone https://github.com/qwerty70020/claudex.git ~/claudex
  cd ~/claudex
fi

bun install
bun run build
npm pack

TARBALL=$(ls letchu_pkt-claudex-*.tgz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && { echo "BUILD_FAIL"; exit 1; }
cp "$TARBALL" /sdcard/
echo "BUILD_OK:$TARBALL"
BUILDEOF

  info "Сборка claudex внутри $ANDROSH_ENV..."
  androsh launch "$ANDROSH_ENV" --run "bash /sdcard/claudex-build.sh" \
    2>&1 | tee /tmp/claudex-build.log

  BUILD_LINE=$(grep "BUILD_OK:" /tmp/claudex-build.log | tail -1)
  [ -z "$BUILD_LINE" ] && die "Сборка не удалась. Смотри /tmp/claudex-build.log"

  TARBALL_NAME=$(echo "$BUILD_LINE" | cut -d: -f2)
  SDCARD_TARBALL="/sdcard/$TARBALL_NAME"
  [ -f "$SDCARD_TARBALL" ] || die "Tarball не найден: $SDCARD_TARBALL"

  # sdcard (FAT32) не поддерживает симлинки — копируем сначала в home
  cp "$SDCARD_TARBALL" "$HOME/"
  LOCAL_TARBALL="$HOME/$TARBALL_NAME"

  npm uninstall -g @letchu_pkt/claudex 2>/dev/null || true
  npm install -g "$LOCAL_TARBALL"
  rm -f "$LOCAL_TARBALL" "$SDCARD_TARBALL" /sdcard/claudex-build.sh

  info "claudex установлен"

  RC_FILE="$HOME/.zshrc"
  [ ! -f "$RC_FILE" ] && RC_FILE="$HOME/.bashrc"
  MARKER="# >>> claudex-termux >>>"

  if grep -q "$MARKER" "$RC_FILE" 2>/dev/null; then
    warn "Env vars уже в $RC_FILE, пропускаю"
  else
    printf '\n%s\n' "$MARKER" >> "$RC_FILE"
    printf 'export CLAUDE_CODE_TMPDIR=$PREFIX/tmp\n' >> "$RC_FILE"
    printf 'export DISABLE_AUTOUPDATER=1\n' >> "$RC_FILE"
    printf 'export SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem\n' >> "$RC_FILE"
    printf 'export NODE_EXTRA_CA_CERTS=$PREFIX/etc/tls/cert.pem\n' >> "$RC_FILE"
    printf '# <<< claudex-termux <<<\n' >> "$RC_FILE"
    info "Env vars добавлены в $RC_FILE"
  fi

  mkdir -p "$PREFIX/tmp"
  info "Готово! Запусти новую сессию Termux и выполни: claudex"
}
```

---

## 7. Провайдер claudex (`.claudex-profile.json`)

Профиль хранится в `~/.claude/.claudex-profile.json`.

### NVIDIA (бесплатно на build.nvidia.com)
```json
{
  "profile": "nvidia",
  "env": {
    "CLAUDE_CODE_USE_NVIDIA": "1",
    "NVIDIA_API_KEY": "nvapi-...",
    "NVIDIA_BASE_URL": "https://integrate.api.nvidia.com/v1",
    "NVIDIA_MODEL": "qwen/qwen3-coder-480b-a35b-instruct"
  }
}
```

### OpenRouter
```json
{
  "profile": "openrouter",
  "env": {
    "CLAUDE_CODE_USE_OPENAI": "1",
    "OPENAI_API_KEY": "sk-or-...",
    "OPENAI_BASE_URL": "https://openrouter.ai/api/v1",
    "OPENAI_MODEL": "qwen/qwen3-coder:free"
  }
}
```

---

## 8. Диагностический тест (10/10 должны проходить)

```bash
echo "=== Claudex Termux Diagnostic ==="
echo "1. TMPDIR: ${CLAUDE_CODE_TMPDIR:-$(node -e 'const os=require("os");console.log(os.tmpdir())')}"
echo "2. rg version: $(rg --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
echo "3. bash: $(which bash)"
echo "4. sh: $(which sh)"
echo "5. SSL cert: ${SSL_CERT_FILE:-not set}"
echo "6. Node.js: $(node --version)"
echo "7. git: $(git --version)"
echo "8. PREFIX: $PREFIX"
echo "9. Write test: $(touch $PREFIX/tmp/test_$$ && echo OK && rm $PREFIX/tmp/test_$$)"
echo "10. UID: $(id -u)"
```

---

## 9. Что ещё нужно сделать (задачи для нового чата)

### 9.1 Репозитории пользователя (передать доступ)
- [ ] `qwerty70020/claudex` — уже есть, патчи применены
- [ ] VauSH репо — для интеграции install функции
- [ ] Frida репозитории (7 штук) — нужно узнать список
- [ ] `Termux_install_all.sh` — главный установочный скрипт

### 9.2 Архитектура нового единого установщика

Предлагаемая структура:
```
termux-setup/
├── install.sh              # главный скрипт, оркестратор
├── modules/
│   ├── 00-base.sh          # pkg deps, базовые пакеты
│   ├── 01-vaush.sh         # VauSH + androsh + Ubuntu
│   ├── 02-claudex.sh       # claudex (сборка внутри Ubuntu)
│   ├── 03-frida.sh         # Frida (все 7 репо)
│   └── 99-env.sh           # финальная настройка окружения
├── ubuntu/
│   └── build-claudex.sh    # скрипт сборки для запуска внутри Ubuntu
└── config/
    └── .claudex-profile.json.tpl  # шаблон профиля провайдера
```

### 9.3 Gotchas которые нужно учесть в новом установщике

| Проблема | Решение |
|----------|---------|
| `/tmp` не существует | `CLAUDE_CODE_TMPDIR=$PREFIX/tmp` |
| Vendor ripgrep зависает | `pkg install ripgrep`, USE_BUILTIN_RIPGREP=0 |
| `/bin/bash` не существует | Всё через `$PREFIX/bin/bash` |
| SSL_CERT_FILE течёт в Ubuntu | `unset SSL_CERT_FILE` перед curl внутри Ubuntu |
| sdcard FAT32 — нет symlinks | npm install только из `$HOME`, не с /sdcard |
| bun не работает в Termux | Только внутри Ubuntu chroot |
| `npm install -g .` → symlink | Всегда `npm pack` + `npm install -g tarball` |
| `androsh launch` требует androsh env name | Конфигурируемо через `$ANDROSH_ENV` |
| zsh hash cache после установки | Добавить `rehash` в конце install функции для zsh |

### 9.4 Frida — что нужно прояснить у пользователя
- Какие именно 7 репозиториев
- Нативный Termux или через Ubuntu?
- gadget, server, tools — что нужно?
- Какую версию Frida таргетить?

---

## 10. Статус PR

- PR #3 открыт: `https://github.com/qwerty70020/Claudex/pull/3`
- Ветка: `claude/fix-termux-permissions-aSE71`
- Статус: все патчи применены, claudex работает (10/10 тестов)
- PR нужно смержить в main перед тем как строить новый установщик

---

## 11. Ключевые файлы для ознакомления в новом чате

```
# В claudex репо:
src/utils/permissions/filesystem.ts   # TMPDIR fix
src/utils/Shell.ts                    # shell path + /tmp fixes
src/utils/ripgrep.ts                  # bionic rg fix
src/utils/terminalPanel.ts            # bash path fix
src/upstreamproxy/upstreamproxy.ts    # SSL cert path fix
scripts/install-termux.sh             # старый installer (заменить)

# У пользователя (передать в новый чат):
~/Termux_install_all.sh               # главный скрипт пользователя
VauSH.zip / androsh исходники         # уже изучены
```
