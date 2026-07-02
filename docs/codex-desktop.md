# Vibemode для Codex Desktop

Этот контур настраивает Codex Desktop на Windows, macOS и Ubuntu/Linux через тот же конфиг, который использует локальный Codex:

- `~/.codex/config.toml` на macOS/Linux
- `%USERPROFILE%\.codex\config.toml` на Windows
- `auth.json` рядом с `config.toml`

Если `auth.json` уже есть, скрипт покажет маскированный prompt: Enter оставляет старый ключ, `r` запускает замену, вставка нового ключа сразу заменяет старый. При вводе ключа показывается одна `*` на каждый считанный символ.

## Ubuntu/Linux

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Если `curl` не установлен:

```bash
sudo apt update && sudo apt install -y curl python3
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

## macOS

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/OlegGorsky/ng/main/d | bash
```

Если Python не установлен, поставь его через Homebrew:

```bash
brew install python
```

## Windows

Открой PowerShell:

```powershell
$u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content
```

Скрипт сначала настраивает Windows-профиль Codex Desktop. Затем он проверяет `wsl.exe`; если WSL установлен и default distro уже инициализирован, туда записываются тот же `~/.codex/config.toml`, `~/.codex/auth.json` и helper `~/.local/bin/responses-image`.

Если WSL установлен, но distro ещё не готов, Windows-настройка всё равно завершается, а WSL-часть пропускается с предупреждением.

Для работы helper-команды генерации изображений нужен Python. Если его нет, Windows setup попробует поставить Python через `winget`, затем через официальный installer с `python.org`, и продолжит настройку даже при неудачной установке.

Codex CLI ставится через npm. Если npm нет, Windows setup попробует поставить Node.js LTS через `winget`, затем через официальный zip с `nodejs.org`.

Если парольный prompt плохо принимает вставку, скопируй ключ в буфер обмена и запусти:

```powershell
$env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

Если Codex CLI после этого всё равно пишет `API key auth is missing a key`, обнови `vibemode-codex` из npm registry или запусти свежий bootstrap напрямую:

```powershell
npm install -g vibemode-codex
vibemode setup --install-codex
```

```powershell
$u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u?$(Get-Random)").Content
```

Для замены ключа скопируй новый ключ в буфер и запусти:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_REPLACE_KEY, Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

Диагностика без вывода значения ключа:

```powershell
$d=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $HOME '.codex'}; "CODEX_HOME=$d"; Select-String -Path (Join-Path $d 'config.toml') -Pattern 'model_provider|requires_openai_auth|env_key|base_url' -ErrorAction SilentlyContinue; (Get-Content (Join-Path $d 'auth.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).PSObject.Properties.Name
```

## Что меняется

В `config.toml` выставляется Vibemode provider:

```toml
model = "gpt-5.4"
model_provider = "vibemode"
model_reasoning_effort = "medium"
cli_auth_credentials_store = "file"

[model_providers.vibemode]
name = "vibemode"
base_url = "https://api.vibemod.pro/v1"
requires_openai_auth = true
```

В `auth.json` записывается или сохраняется:

```json
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "..."
}
```

В `.env` для Codex Desktop и пользовательское окружение для CLI записывается API key для helper-скриптов, shell-сессий и совместимости:

```dotenv
CODEX_KEY="..."
OPENAI_API_KEY="..."
CODEX_API_KEY="..."
```

После обновления перезапусти Codex Desktop, чтобы приложение перечитало provider config.

Если проверка `/v1/responses` вернула `HTTP 401`, настройки уже сохранены. Это обычно означает, что API-ключ не принят сервером. Для принудительной замены ключа в Windows скопируй новый ключ в буфер и запусти:

```powershell
$env:VIBEMODE_REPLACE_KEY='1'; $env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_REPLACE_KEY, Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue
```

Для повторной записи без проверки можно запустить скрипт с `-SkipApiCheck`, но для реальной работы Codex ключ всё равно должен проходить авторизацию. Для короткой Windows-команды:

```powershell
$env:VIBEMODE_SKIP_API_CHECK='1'; $u='https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1'; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache'} "$u?$(Get-Random)").Content; Remove-Item Env:\VIBEMODE_SKIP_API_CHECK -ErrorAction SilentlyContinue
```

## Окно авторизации Codex Desktop

Скрипт не авторизует подписку ChatGPT внутри UI Codex Desktop. Он включает API-режим через локальные файлы `config.toml`, официальный кеш API-логина `auth.json` и `.env` для вспомогательных сценариев.

Если Codex Desktop после установки показывает выбор авторизации, выбирай вариант с API, а не подписку. Если приложение снова просит ключ, проверь, что `config.toml`, `auth.json` и `.env` лежат в `%USERPROFILE%\.codex` на Windows или в `~/.codex` внутри выбранного WSL/default user.

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
& "$env:USERPROFILE\.local\bin\responses-image.cmd" --list-presets
```

Пример генерации:

```bash
~/.local/bin/responses-image generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Helper читает ключ из окружения или `OPENAI_API_KEY` в Codex `auth.json`, а `base_url` и модель из активного `model_provider`, поэтому после desktop setup картинки идут через Vibemode.

## Локальный запуск из клона

Linux/macOS:

```bash
bash setup-vibemode-codex-desktop.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-vibemode-codex-desktop.ps1
```

Windows setup также пробует поставить Codex CLI: `@openai/codex` через npm, а при отсутствии npm — Node.js LTS через `winget` или официальный zip с `nodejs.org`. После установки CLI Windows setup выполняет `codex login --with-api-key`, нормализует `auth.json` к официальному формату с `OPENAI_API_KEY`, сохраняет `CODEX_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY` в окружение и добавляет PowerShell profile-refresh для новых вкладок.

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
