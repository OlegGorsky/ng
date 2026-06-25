# Vibemode для Codex Desktop

Этот контур настраивает Codex Desktop на Windows, macOS и Ubuntu/Linux через тот же конфиг, который использует локальный Codex:

- `~/.codex/config.toml` на macOS/Linux
- `%USERPROFILE%\.codex\config.toml` на Windows
- `auth.json` рядом с `config.toml`

Если `auth.json` уже есть, скрипт покажет маскированный prompt: Enter оставляет старый ключ, `r` запускает замену, вставка нового ключа сразу заменяет старый. При вводе ключа показывается одна `*` на каждый считанный символ.

## Ubuntu/Linux

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Если `curl` не установлен:

```bash
sudo apt update && sudo apt install -y curl python3
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

## macOS

```bash
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Если Python не установлен, поставь его через Homebrew:

```bash
brew install python
```

## Windows

Открой PowerShell:

```powershell
irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex
```

Скрипт сначала настраивает Windows-профиль Codex Desktop. Затем он проверяет `wsl.exe`; если WSL установлен и default distro уже инициализирован, туда записываются тот же `~/.codex/config.toml`, `~/.codex/auth.json` и helper `~/.local/bin/responses-image`.

Если WSL установлен, но distro ещё не готов, Windows-настройка всё равно завершается, а WSL-часть пропускается с предупреждением.

Для работы helper-команды генерации изображений нужен Python в `PATH`.

Если парольный prompt плохо принимает вставку, скопируй ключ в буфер обмена и запусти:

```powershell
$env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD
```

## Что меняется

В `config.toml` выставляется Vibemode provider:

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

В `auth.json` записывается или сохраняется:

```json
{
  "auth_mode": "apikey",
  "CODEX_KEY": "..."
}
```

После обновления перезапусти Codex Desktop, чтобы приложение перечитало provider config.

Если проверка `/v1/responses` вернула `HTTP 401`, настройки уже сохранены. Это обычно означает, что API-ключ не принят сервером. Для принудительной замены ключа в Windows скопируй новый ключ в буфер и запусти:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_REPLACE_KEY; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD
```

Для повторной записи без проверки можно запустить скрипт с `-SkipApiCheck`, но для реальной работы Codex ключ всё равно должен проходить авторизацию. Для короткой Windows-команды:

```powershell
$env:VIBEMODE_SKIP_API_CHECK='1'; irm https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1 | iex; Remove-Item Env:\VIBEMODE_SKIP_API_CHECK
```

## Окно авторизации Codex Desktop

Скрипт не авторизует подписку ChatGPT внутри UI Codex Desktop. Он включает API-режим через локальные файлы `config.toml` и `auth.json`.

Если Codex Desktop после установки показывает выбор авторизации, выбирай вариант с API, а не подписку. Если приложение снова просит ключ, проверь, что `config.toml` и `auth.json` лежат в `%USERPROFILE%\.codex` на Windows или в `~/.codex` внутри выбранного WSL/default user.

## Картинки

Linux/macOS setup скачивает helper в:

```bash
~/.local/bin/responses-image
```

Windows setup скачивает helper в:

```powershell
%USERPROFILE%\.local\bin\responses-image.py
```

Рядом создаётся wrapper:

```powershell
%USERPROFILE%\.local\bin\responses-image.cmd
```

При наличии WSL Windows setup дополнительно кладёт Linux-helper в:

```bash
~/.local/bin/responses-image
```

Проверка:

```bash
~/.local/bin/responses-image --list-presets
```

Windows:

```powershell
python "$env:USERPROFILE\.local\bin\responses-image.py" --list-presets
```

Пример генерации:

```bash
~/.local/bin/responses-image generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Helper читает `CODEX_KEY` из Codex `auth.json`, а `base_url` и модель из активного `model_provider`, поэтому после desktop setup картинки идут через Vibemode.

## Локальный запуск из клона

Linux/macOS:

```bash
bash setup-vibemode-codex-desktop.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1
```

Полезные опции:

```bash
bash setup-vibemode-codex-desktop.sh --non-interactive --model gpt-5
bash setup-vibemode-codex-desktop.sh --skip-api-check
bash setup-vibemode-codex-desktop.sh --no-image-helper
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -NonInteractive -Model gpt-5
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -SkipApiCheck
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -NoImageHelper
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -WslDistro Ubuntu
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -NoWsl
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -ReplaceKey
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1 -KeyFromClipboard
```

`-WslDistro Ubuntu` полезен, если default distro не тот. `-NoWsl` оставляет только Windows-настройку. `-ReplaceKey` принудительно просит новый ключ. `-KeyFromClipboard` берёт новый ключ из буфера обмена.
