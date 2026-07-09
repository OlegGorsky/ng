# Vibemode Codex Setup

Один репозиторий для двух сценариев:

- Codex Desktop на Ubuntu/Linux, macOS и Windows.
- Codex CLI в Termux.

Основной способ установки теперь единый CLI через `npx`. Старые короткие `curl`/PowerShell команды тоже остаются: они удобны, когда Node.js/npm ещё не поставлены.

CLI и скрипты прописывают Vibemode API в Codex config, сохраняют официальный кеш API-логина Codex в `auth.json`, настраивают `CODEX_KEY`, `OPENAI_API_KEY` и `CODEX_API_KEY` в окружении, проверяют `/v1/responses` и не печатают API-ключ в терминал.

## Быстрый старт через npx

`npx` не ставит Node.js сам: нужен уже установленный Node.js/npm. В Termux это обычно:

```bash
pkg install -y nodejs
```

На Linux/macOS/Windows поставь Node.js любым привычным способом, затем запускай:

```bash
npx --yes vibemode-codex setup --install-codex
```

Команда спросит Vibemode API key скрытым вводом, установит `@openai/codex`, если Codex CLI ещё не найден, и запишет локальный Codex config для текущего пользователя. Один и тот же `~/.codex` или `%USERPROFILE%\.codex` используется Codex CLI и Codex Desktop, поэтому `--target all` является режимом по умолчанию.

По умолчанию пишется `gpt-5.6-terra`. Текущие модели VibeMode для Codex CLI: `gpt-5.4-mini`, `gpt-5.5`, `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`. Любую можно выбрать через `--model`.

Если нужен глобальный CLI:

```bash
npm uninstall -g vibemode-codex
npm install -g vibemode-codex
vibemode setup --install-codex
```

После глобальной установки доступны команды:

```bash
vibemode status
vibemode key set
vibemode key status
vibemode key remove
vibemode use vibemode
vibemode use openai
vibemode remove
vibemode install-codex
vibemode uninstall-codex --yes
vibemode run -- codex --yolo
```

То же самое можно запускать без глобальной установки:

```bash
npx --yes vibemode-codex status
npx --yes vibemode-codex key set
npx --yes vibemode-codex use openai
npx --yes vibemode-codex remove
npx --yes vibemode-codex run -- codex --yolo
```

`vibemode run -- codex --yolo` полезен в Termux: команда подставляет сохранённый ключ только в запускаемый Codex-процесс, даже если текущая вкладка ещё не перечитала `.profile`.

## Что выбрать

Рекомендуемый универсальный путь для новых пользователей:

```bash
npx --yes vibemode-codex setup --install-codex
```

Дальше запускай Codex так:

```bash
npx --yes vibemode-codex run -- codex --yolo
```

Если Node.js/npm пока нет или нужен короткий legacy-вариант, используй команды ниже.

Для Codex Desktop на Ubuntu/Linux или macOS:

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Для Codex Desktop на Windows открой PowerShell:

```powershell
$u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content
```

Windows-команда также попробует поставить или обновить Codex CLI до текущего npm-релиза: сначала через npm, а если npm не найден — через Node.js LTS через `winget` или официальный zip с `nodejs.org`.

Если на Windows уже установлен и инициализирован WSL, эта же команда дополнительно пропишет Vibemode в default WSL-дистрибутив.

Для Codex CLI в Termux:

```bash
pkg install -y curl bash && curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
```

Если `curl` в Termux уже установлен:

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
```

## Быстрый ремонт Windows auth

Если Codex на Windows пишет `API key auth is missing a key`, переустанови текущий npm-пакет и перепиши активный Codex config:

```powershell
npm install -g vibemode-codex
vibemode setup --install-codex
```

Если Node.js/npm ещё нет, запусти Windows bootstrap:

```powershell
$u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u?$(Get-Random)").Content
```

Если нужно заменить ключ, сначала скопируй новый Vibemode API key в буфер:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_REPLACE_KEY, Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

Проверить, куда реально смотрит Codex, можно без вывода самого ключа:

```powershell
$d=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $HOME '.codex'}; "CODEX_HOME=$d"; Select-String -Path (Join-Path $d 'config.toml') -Pattern 'model_provider|requires_openai_auth|env_key|base_url' -ErrorAction SilentlyContinue; (Get-Content (Join-Path $d 'auth.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).PSObject.Properties.Name
```

## Терминальная диагностика Windows

Для удалённой диагностики без Web UI можно поднять Bun/Hono сервер. Он пишет события в SQLite и не сохраняет значения API-ключей: только пути, флаги и имена полей вроде `auth_mode, OPENAI_API_KEY`.

На своём сервере:

```bash
bun install
VIBEMODE_PUBLIC_BASE_URL=https://your-domain.example PORT=8787 bun run diag:server
```

Создать диагностическую сессию:

```bash
curl -s -X POST https://your-domain.example/api/sessions
```

Если задан `VIBEMODE_DIAG_ADMIN_TOKEN`, добавь заголовок:

```bash
curl -s -X POST -H "x-admin-token: $VIBEMODE_DIAG_ADMIN_TOKEN" https://your-domain.example/api/sessions
```

Ответ вернёт `command`. Её нужно отправить пользователю в PowerShell. Смотреть лог:

Короткая команда без `sid/token` в ссылке:

```powershell
irm https://your-domain.example/i|iex
```

```bash
curl -s https://your-domain.example/api/sessions/<id>/events.txt
```

Если задан `VIBEMODE_DIAG_ADMIN_TOKEN`, добавь заголовок:

```bash
curl -s -H "x-admin-token: $VIBEMODE_DIAG_ADMIN_TOKEN" https://your-domain.example/api/sessions/<id>/events.txt
```

## Что будет по шагам

1. CLI или скрипт найдёт Codex config directory.
2. Если ключа ещё нет, попросит вставить Vibemode API key маскированным вводом: одна `*` на каждый символ.
3. Если `auth.json` уже есть, можно оставить ключ, заменить его или удалить через `vibemode key remove`.
4. `config.toml` обновится на Vibemode provider.
5. Для Codex provider включится официальный API-login auth через `auth.json`.
6. Для Codex CLI `auth.json` приводится к формату `codex login --with-api-key`: `"auth_mode": "apikey"` и `OPENAI_API_KEY`. `CODEX_HOME`, `CODEX_KEY`, `OPENAI_API_KEY` и `CODEX_API_KEY` дополнительно пишутся в `.env`, `vibemode.env` или пользовательские переменные окружения для Desktop, shell-сессий, helper-скриптов и совместимости.
7. Ключ проверится через `POST https://api.vibemod.pro/v1/responses`, если проверка не отключена.
8. По команде `vibemode use openai` конфиг возвращается к стандартному OpenAI provider.
9. По команде `vibemode remove` удаляются Vibemode key material и shell startup block, а Codex config переключается на OpenAI.
10. Legacy Desktop-скрипт дополнительно ставит helper для генерации картинок, Codex CLI через npm и на Windows мягко пробует поставить Python/Node.js через `winget` или официальные установщики, если их нет.
11. Windows-скрипт проверяет WSL и, если default distro готов, записывает туда тот же `config.toml`, `auth.json`, `.env`, `vibemode.env`, shell startup block и image helper.
12. Windows-скрипт добавляет маленький PowerShell profile-блок, чтобы новые вкладки перечитывали сохранённые `CODEX_*` переменные даже если Windows Terminal ещё держит старое окружение.
13. После Desktop-настройки перезапусти Codex Desktop.

Короткие `curl ... | bash` команды тоже умеют спрашивать ключ: bash-скрипты читают ввод с терминала, а не из pipe.

## Что записывается

`config.toml`:

```toml
model = "gpt-5.6-terra"
model_provider = "vibemode"
model_reasoning_effort = "medium"
cli_auth_credentials_store = "file"

[model_providers.vibemode]
name = "vibemode"
base_url = "https://api.vibemod.pro/v1"
requires_openai_auth = true
```

`auth.json`:

```json
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "..."
}
```

`.env` для Codex Desktop и `vibemode.env`/пользовательское окружение для CLI:

```dotenv
CODEX_HOME="..."
CODEX_KEY="..."
OPENAI_API_KEY="..."
CODEX_API_KEY="..."
```

Пути:

- Ubuntu/Linux/macOS/Termux: `~/.codex/config.toml`, `~/.codex/auth.json`, `~/.codex/.env` и `~/.codex/vibemode.env`
- Windows: `%USERPROFILE%\.codex\config.toml`, `%USERPROFILE%\.codex\auth.json` и `%USERPROFILE%\.codex\.env`
- WSL при запуске Windows-скрипта: `~/.codex/config.toml`, `~/.codex/auth.json`, `~/.codex/.env` и `~/.codex/vibemode.env` внутри default WSL-дистрибутива

В Linux/macOS/Termux и WSL Codex CLI берёт ключ для Vibemode provider из API-login кеша `auth.json`. Скрипт всё равно пишет `CODEX_HOME`, `CODEX_KEY`, `OPENAI_API_KEY` и `CODEX_API_KEY` в `~/.codex/vibemode.env` и добавляет его подключение в `~/.profile`; если используются bash или zsh, также обновляются `.bashrc` или `.zshrc`. Это нужно для shell-сессий, helper-скриптов и совместимости. После запуска через `curl ... | bash` текущая вкладка Termux не может автоматически получить переменную из дочернего `bash`; выполни команду, которую скрипт покажет в конце, или открой новую вкладку Termux.

Для WSL используется текущий default user выбранного дистрибутива. Если default user в WSL — `oleg`, путь будет вроде `/home/oleg/.codex`; если default user — `root`, путь будет `/root/.codex`. Скрипт выводит WSL user, `HOME` и итоговый config dir в лог.

Перед изменением существующих файлов создаются `.bak-YYYYmmdd-HHMMSS` бэкапы.

Если проверка `/v1/responses` вернула `HTTP 401`, настройки уже сохранены. Это почти всегда означает, что сервер не принял сохранённый API-ключ. Для принудительной замены ключа в Windows скопируй новый ключ в буфер и запусти:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_REPLACE_KEY, Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

Повторить запись без контрольного запроса можно опцией `-SkipApiCheck` на Windows или `--skip-api-check` на Linux/macOS/Termux. Для короткой Windows-команды:

```powershell
$env:VIBEMODE_SKIP_API_CHECK='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_SKIP_API_CHECK -ErrorAction SilentlyContinue
```

При вставке в prompt ключ не показывается, но по количеству `*` видно, сколько символов считалось. Если в Windows вставка всё равно работает криво, скопируй ключ в буфер обмена и запусти:

```powershell
$env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

## Важно про окно авторизации Codex Desktop

Скрипт не авторизует подписку ChatGPT внутри интерфейса Codex Desktop. Он настраивает API-режим: записывает Vibemode provider в `config.toml`, официальный кеш API-логина в `auth.json` и API key в окружение для вспомогательных сценариев.

Если после установки Codex Desktop показывает экран выбора авторизации, выбирай вариант с API, а не подписку. После этого перезапусти Codex Desktop. Если приложение снова просит ключ, проверь, что файлы лежат именно в `%USERPROFILE%\.codex` на Windows или в `~/.codex` внутри выбранного WSL/default user.

## Обновление

Запусти ту же команду, что и при установке. Если ключ уже сохранён, скрипт спросит, оставить его или заменить. Для обычного обновления нажми Enter. Чтобы заменить ключ, введи `r` или сразу вставь новый ключ в этот маскированный prompt.

Desktop Ubuntu/Linux/macOS:

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Desktop Windows:

```powershell
$u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content
```

Termux:

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
```

## Генерация изображений

Desktop-setup ставит helper для `/responses` + `image_generation`.

Ubuntu/Linux/macOS:

```bash
~/.local/bin/responses-image --list-presets
~/.local/bin/responses-image generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Windows:

```powershell
& "$env:USERPROFILE\.local\bin\responses-image.cmd" --list-presets
& "$env:USERPROFILE\.local\bin\responses-image.cmd" generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

WSL после Windows-установки:

```bash
~/.local/bin/responses-image --list-presets
~/.local/bin/responses-image generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Termux или локальный запуск из репозитория:

```bash
python3 scripts/responses_image.py generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Helper читает ключ из окружения или `OPENAI_API_KEY` в Codex `auth.json`, а `base_url` и модель из активного `model_provider`, поэтому картинки идут через Vibemode после настройки.

Подробности: [docs/responses-image-generation.md](docs/responses-image-generation.md).

## Локальный запуск из клона

Desktop Ubuntu/Linux/macOS:

```bash
bash setup-vibemode-codex-desktop.sh
```

Desktop Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -WslDistro Ubuntu
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -NoWsl
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -ReplaceKey
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -KeyFromClipboard
```

Termux:

```bash
bash setup-vibemode-codex-termux.sh
```

Без интерактива с переменной окружения:

```bash
CODEX_KEY='...' bash setup-vibemode-codex-desktop.sh --non-interactive
CODEX_KEY='...' bash setup-vibemode-codex-termux.sh --non-interactive
```

Выбрать другую модель:

```bash
CODEX_KEY='...' bash setup-vibemode-codex-desktop.sh --non-interactive --model gpt-5.6-sol
CODEX_KEY='...' bash setup-vibemode-codex-termux.sh --non-interactive --model gpt-5.5
```

Заменить сохранённый ключ:

```bash
bash setup-vibemode-codex-desktop.sh --replace-key
bash setup-vibemode-codex-termux.sh --replace-key
```

Документация по Desktop: [docs/codex-desktop.md](docs/codex-desktop.md).

## Проверка

Локальные тесты:

```bash
bash tests/run.sh
```
