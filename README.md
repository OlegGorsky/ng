# Vibemode Codex Setup

Один репозиторий для двух сценариев:

- Codex Desktop на Ubuntu/Linux, macOS и Windows.
- Codex CLI в Termux.

Скрипты прописывают Vibemode API в Codex config, сохраняют ключ в `auth.json`, проверяют `/v1/models` и не печатают API-ключ в терминал.

## Что выбрать

Для Codex Desktop на Ubuntu/Linux или macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Для Codex Desktop на Windows открой PowerShell:

```powershell
irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex
```

Если на Windows уже установлен и инициализирован WSL, эта же команда дополнительно пропишет Vibemode в default WSL-дистрибутив.

Для Codex CLI в Termux:

```bash
pkg install -y curl bash && curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
```

Если `curl` в Termux уже установлен:

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
```

## Что будет по шагам

1. Скрипт найдёт Codex config directory.
2. Если ключа ещё нет, попросит вставить Vibemode API key маскированным вводом: одна `*` на каждый символ.
3. Если `auth.json` уже есть, скрипт покажет маскированный prompt: Enter оставляет старый ключ, `r` запускает замену, вставка нового ключа сразу заменяет старый.
4. Скрипт обновит `config.toml` на Vibemode provider.
5. Скрипт проверит ключ через `GET https://api.vibemod.pro/v1/models`.
6. Для Codex Desktop дополнительно поставит helper для генерации картинок.
7. Windows-скрипт проверит WSL и, если default distro готов, запишет туда тот же `config.toml`, `auth.json` и image helper.
8. После Desktop-настройки перезапусти Codex Desktop.

Короткие `curl ... | bash` команды тоже умеют спрашивать ключ: bash-скрипты читают ввод с терминала, а не из pipe.

## Что записывается

`config.toml`:

```toml
model = "gpt-5.4"
model_provider = "vibemode"

[model_providers.vibemode]
name = "vibemode"
base_url = "https://api.vibemod.pro/v1"
env_key = "CODEX_KEY"

[profiles.default]
model = "gpt-5.4"
model_provider = "vibemode"
reasoning_effort = "medium"
```

`auth.json`:

```json
{
  "auth_mode": "apikey",
  "CODEX_KEY": "..."
}
```

Пути:

- Ubuntu/Linux/macOS/Termux: `~/.codex/config.toml` и `~/.codex/auth.json`
- Windows: `%USERPROFILE%\.codex\config.toml` и `%USERPROFILE%\.codex\auth.json`
- WSL при запуске Windows-скрипта: `~/.codex/config.toml` и `~/.codex/auth.json` внутри default WSL-дистрибутива

Для WSL используется текущий default user выбранного дистрибутива. Если default user в WSL — `oleg`, путь будет вроде `/home/oleg/.codex`; если default user — `root`, путь будет `/root/.codex`. Скрипт выводит WSL user, `HOME` и итоговый config dir в лог.

Перед изменением существующих файлов создаются `.bak-YYYYmmdd-HHMMSS` бэкапы.

Если скрипт успел записать файлы, но упал на проверке `/v1/models`, настройки уже сохранены. `HTTP 401` почти всегда означает, что сервер не принял сохранённый API-ключ. Для принудительной замены ключа в Windows скопируй новый ключ в буфер и запусти:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_REPLACE_KEY; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD
```

Повторить запись без контрольного запроса можно опцией `-SkipApiCheck` на Windows или `--skip-api-check` на Linux/macOS/Termux. Для короткой Windows-команды:

```powershell
$env:VIBEMODE_SKIP_API_CHECK='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_SKIP_API_CHECK
```

При вставке в prompt ключ не показывается, но по количеству `*` видно, сколько символов считалось. Если в Windows вставка всё равно работает криво, скопируй ключ в буфер обмена и запусти:

```powershell
$env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD
```

## Важно про окно авторизации Codex Desktop

Скрипт не авторизует подписку ChatGPT внутри интерфейса Codex Desktop. Он настраивает API-режим: записывает Vibemode provider в `config.toml` и API-ключ в `auth.json`.

Если после установки Codex Desktop показывает экран выбора авторизации, выбирай вариант с API, а не подписку. После этого перезапусти Codex Desktop. Если приложение снова просит ключ, проверь, что файлы лежат именно в `%USERPROFILE%\.codex` на Windows или в `~/.codex` внутри выбранного WSL/default user.

## Обновление

Запусти ту же команду, что и при установке. Если ключ уже сохранён, скрипт спросит, оставить его или заменить. Для обычного обновления нажми Enter. Чтобы заменить ключ, введи `r` или сразу вставь новый ключ в этот маскированный prompt.

Desktop Ubuntu/Linux/macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Desktop Windows:

```powershell
irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex
```

Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/i | bash
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
python "$env:USERPROFILE\.local\bin\responses-image.py" --list-presets
python "$env:USERPROFILE\.local\bin\responses-image.py" generate "cinematic photo of a compact AI workstation" --size wide --quality high
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

Helper читает ключ из Codex `auth.json`, а `base_url` и модель из активного `model_provider`, поэтому картинки идут через Vibemode после настройки.

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
CODEX_KEY='...' bash setup-vibemode-codex-desktop.sh --non-interactive --model gpt-5
CODEX_KEY='...' bash setup-vibemode-codex-termux.sh --non-interactive --model gpt-5
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
