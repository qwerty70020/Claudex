# Termux Installer — Сессионные заметки для нового чата

> Этот файл — полный технический бриф по всему, что было выяснено и сделано.
> Для нового чата: читай это первым делом, не задавай вопросов — просто работай.

---

## СТАТУС СЕССИИ (обновлено 2026-04-25)

### Что сделано в последней сессии
- Создана ветка `termux-installer` в репо `qwerty70020/termux-scripts`
- Написан полный модульный установщик `Termux/setup/` (Вариант В — bash + lib/*.sh)
- Проведено 2 полных ревью кода, найдено и исправлено 9 багов
- Последний коммит: `aa993773c83370a9d12aa3382279c2bbe9fccae2`
- Старый монолитный `Termux_install_all.sh` → переименован в `.OLD.sh` (для памяти)

### Что ОСТАЛОСЬ сделать
- [ ] Протестировать установщик на реальном девайсе
- [ ] Открыть PR из `termux-installer` → `master` в termux-scripts
- [ ] (Опционально) Смержить PR #3 в claudex если ещё не смержен

### Как запустить установщик (когда будешь тестировать)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qwerty70020/termux-scripts/termux-installer/Termux/setup/install.sh)
# или клонировать и запустить локально:
git clone https://github.com/qwerty70020/termux-scripts.git -b termux-installer
bash termux-scripts/Termux/setup/install.sh
```

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

## 2. Новый модульный установщик (termux-scripts, ветка termux-installer)

### Структура файлов
```
Termux/setup/
├── install.sh                  # главный оркестратор
├── lib/
│   ├── common.sh               # общие утилиты (die, info, warn, gh_api, mktemp_dir)
│   ├── 00-system.sh            # базовые пакеты + check_versions
│   ├── 01-python.sh            # Python 3 + pip
│   ├── 02-zsh.sh               # zsh + zinit + плагины
│   ├── 03-configs.sh           # .zshrc, .bashrc, .nanorc и прочие конфиги
│   ├── 04-vaush.sh             # VauSH/androsh (sparse-checkout)
│   ├── 05-claudex.sh           # claudex (сборка через androsh→Ubuntu)
│   ├── 06-frida.sh             # Frida + frida-il2cpp-bridge
│   ├── 07-rish.sh              # rish из Shizuku APK
│   ├── 08-apktool.sh           # apktool
│   └── 09-trufflehog.sh        # trufflehog
└── ubuntu/
    └── build-claudex.sh        # скрипт сборки для запуска ВНУТРИ Ubuntu chroot

Termux/
└── Termux_install_all.OLD.sh   # старый 800-строчный монолит (сохранён для памяти)
```

### Флаги install.sh
```bash
--skip-system     # пропустить базовые пакеты
--skip-python     # пропустить Python
--skip-zsh        # пропустить zsh/zinit
--skip-configs    # пропустить конфиги
--skip-vaush      # пропустить VauSH/androsh
--skip-claudex    # пропустить claudex
--skip-frida      # пропустить Frida
--skip-rish       # пропустить rish
--skip-apktool    # пропустить apktool
--skip-trufflehog # пропустить trufflehog
```

### 9 багов исправлено (2 ревью)
| Файл | Баг → Исправление |
|------|-------------------|
| `install.sh` | `echo "\n"` → `printf '\n...'` |
| `install.sh` | Нет проверки Termux-env (`PREFIX` unset) → добавлен guard |
| `install.sh` | configs запускались ПОСЛЕ zsh → порядок: configs, потом zsh |
| `05-claudex.sh` | `build_log` создавался через `mktemp` без регистрации → `mktemp_dir` |
| `05-claudex.sh` | `androsh \| tee` → pipefail exit → добавлен `\|\| true` |
| `04-vaush.sh` | После установки androsh нет `hash -r` → bash не находил команду |
| `06-frida.sh` | `npm init -y` перезаписывал `package.json` при повторном запуске |
| `07-rish.sh` | `bin_dir` через `$BASH` → хрупко → `${PREFIX}/bin` |
| `build-claudex.sh` | Нет ERR trap; `NODE_EXTRA_CA_CERTS` течёт в Ubuntu; `ls \| head` с pipefail |
| `common.sh` | `gh_api` возвращал строку `"null"` → `// empty` в jq |
| `00-system.sh` | `check_versions` писал stderr в строку версии → новый `_ver()` helper |

---

## 3. Все Termux-патчи в claudex (уже применены в ветке)

### 3.1 `src/utils/permissions/filesystem.ts` (line ~334)
```diff
- process.env.CLAUDE_CODE_TMPDIR || (getPlatform() === 'windows' ? tmpdir() : '/tmp')
+ process.env.CLAUDE_CODE_TMPDIR || tmpdir()
```
**Причина:** `/tmp` не существует в Termux → EACCES при старте.

### 3.2 `src/utils/Shell.ts`
```diff
+ import { tmpdir } from 'os'

# Shell search paths — Termux first:
+ const shellPaths = process.env.PREFIX
+   ? [`${process.env.PREFIX}/bin`, '/bin', '/usr/bin', '/usr/local/bin']
+   : ['/bin', '/usr/bin', '/usr/local/bin', '/opt/homebrew/bin']

# /bin/sh replacement:
+ const POSIX_SH = process.env.PREFIX ? `${process.env.PREFIX}/bin/sh` : '/bin/sh'
```
**Причина:** `/bin/bash`, `/bin/sh` не существуют в Termux.

### 3.3 `src/utils/tmuxSocket.ts` (line ~381)
```diff
- process.env.TMPDIR || '/tmp'
+ process.env.TMPDIR || tmpdir()
```

### 3.4 `src/utils/ripgrep.ts` (lines 33-47)
```typescript
const isTermux = !!process.env.PREFIX && process.platform === 'linux'
const userWantsSystemRipgrep = isTermux || isEnvDefinedFalsy(process.env.USE_BUILTIN_RIPGREP)
if (userWantsSystemRipgrep) { return { mode: 'system', command: 'rg', args: [] } }
```
**Причина:** Vendor rg (glibc binary) зависает на Android bionic libc. Системный `rg` из pkg работает.

### 3.5 `src/utils/terminalPanel.ts`
```diff
- process.env.SHELL || '/bin/bash'
+ process.env.SHELL || (process.env.PREFIX ? `${process.env.PREFIX}/bin/bash` : '/bin/bash')
```

### 3.6 `src/upstreamproxy/upstreamproxy.ts`
```diff
- const SYSTEM_CA_BUNDLE = '/etc/ssl/certs/ca-certificates.crt'
+ const SYSTEM_CA_BUNDLE = process.env.PREFIX
+   ? `${process.env.PREFIX}/etc/ssl/certs/ca-certificates.crt`
+   : '/etc/ssl/certs/ca-certificates.crt'
```

### 3.7 `src/components/Settings/Config.tsx`
```typescript
// Добавлена пропущенная функция:
function getSubagentModelLabel(value: string | null): string {
  if (value === null) return "Default (leader's model)";
  return modelDisplayString(value);
}
// Исправлен импорт: '../ThemePicker.js' → '../theme/ThemePicker.js'
```

---

## 4. Переменные окружения для Termux (`~/.zshrc`)

```bash
# >>> claudex-termux >>>
export CLAUDE_CODE_TMPDIR=$PREFIX/tmp
export DISABLE_AUTOUPDATER=1
export SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem
export NODE_EXTRA_CA_CERTS=$PREFIX/etc/tls/cert.pem
# <<< claudex-termux <<<
```

**ВАЖНО:** Эти переменные текут в Ubuntu chroot и ломают curl/apt.
Решение: в `build-claudex.sh` делаем `unset SSL_CERT_FILE NODE_EXTRA_CA_CERTS` первой строкой.

---

## 5. Система VauSH / androsh

- **VauSH** — Python-приложение (`python3 main.py install`), хранится в `Termux/VauSH/` в termux-scripts репо
- **androsh** — устанавливается в `$PREFIX/bin/androsh`
- Sparse-checkout для установки: `git clone --filter=blob:none --sparse ... && git sparse-checkout set Termux/VauSH`
- После установки: **обязательно** `hash -r` чтобы bash нашёл новый бинарник

```bash
androsh launch ubuntu --run "bash /sdcard/build.sh"   # выполнить команду в chroot
```

### Критически важно
- `/sdcard` — FAT32: нет symlinks → `npm install` только из `$HOME`, не с sdcard
- Tarball путь: Ubuntu → `/sdcard` → Termux `$HOME` → `npm install -g`

---

## 6. Сборка claudex — pipeline

```bash
# Внутри Ubuntu (build-claudex.sh на /sdcard):
bun install && bun run build && npm pack
cp letchu_pkt-claudex-*.tgz /sdcard/
echo "BUILD_OK:$TARBALL"

# В Termux (05-claudex.sh):
cp /sdcard/$TARBALL $HOME/
npm install -g $HOME/$TARBALL
rm $HOME/$TARBALL
```

---

## 7. Провайдер claudex (`.claudex-profile.json`)

Профиль: `~/.claude/.claudex-profile.json`

### NVIDIA (бесплатно)
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

## 8. Диагностический тест Termux

```bash
echo "1. TMPDIR: ${CLAUDE_CODE_TMPDIR:-$(node -e 'const os=require("os");console.log(os.tmpdir())')}"
echo "2. rg: $(rg --version 2>/dev/null | head -1 || echo NOT FOUND)"
echo "3. bash: $(which bash)"
echo "4. SSL cert: ${SSL_CERT_FILE:-not set}"
echo "5. Node.js: $(node --version)"
echo "6. PREFIX: $PREFIX"
echo "7. Write test: $(touch $PREFIX/tmp/test_$$ && echo OK && rm $PREFIX/tmp/test_$$)"
```

---

## 9. Статус PR

- PR #3 в claudex: `https://github.com/qwerty70020/Claudex/pull/3`
- Ветка: `claude/fix-termux-permissions-aSE71`
- Все патчи применены
- Смержить в main перед тестированием установщика
