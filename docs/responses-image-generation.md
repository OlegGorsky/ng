# Генерация изображений через Vibemode Responses API

В репозитории есть helper-скрипт [scripts/responses_image.py](../scripts/responses_image.py). Он работает без OpenAI SDK: читает ключ из `CODEX_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY` или `OPENAI_API_KEY` в `~/.codex/auth.json`, а URL и модель берёт из `OPENAI_BASE_URL`/`OPENAI_MODEL` или из активного провайдера в `~/.codex/config.toml`.

После запуска Termux или Desktop установщика скрипт автоматически использует:

```toml
model = "gpt-5.4"
model_provider = "vibemode"
cli_auth_credentials_store = "file"

[model_providers.vibemode]
name = "vibemode"
base_url = "https://api.vibemod.pro/v1"
env_key = "CODEX_KEY"

[profiles.default]
model = "gpt-5.4"
model_provider = "vibemode"
reasoning_effort = "medium"
```

## Установка helper-команды

В Termux:

```bash
pkg install -y python
```

В Ubuntu/Linux:

```bash
sudo apt update && sudo apt install -y python3 curl
```

В macOS:

```bash
brew install python
```

В Windows нужен Python в `PATH`.

Можно скачать helper как отдельную команду:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/OlegGorsky/ng/main/scripts/responses_image.py -o ~/.local/bin/responses-image
chmod +x ~/.local/bin/responses-image
```

Если `~/.local/bin` не добавлен в `PATH`, запускай так:

```bash
python3 ~/.local/bin/responses-image --list-presets
```

Windows desktop setup ставит helper сюда:

```powershell
& "$env:USERPROFILE\.local\bin\responses-image.cmd" --list-presets
```

## Примеры

Сгенерировать изображение:

```bash
python3 scripts/responses_image.py generate "cinematic photo of a compact AI workstation" --size wide --quality high
```

Сохранить в конкретный файл:

```bash
python3 scripts/responses_image.py generate "minimal black terminal setup, realistic lighting" \
  --output output/imagegen/terminal.png \
  --size 1536x1024 \
  --quality high
```

Отредактировать изображение:

```bash
python3 scripts/responses_image.py edit "make the lighting warmer, keep composition" \
  --input input/source.png \
  --output output/imagegen/source-warm.png
```

Запустить через env-интерфейс:

```bash
IMAGE_PROMPT="clean product photo of a matte black notebook" \
IMAGE_OUTPUT="output/imagegen/notebook.png" \
IMAGE_SIZE="square" \
IMAGE_QUALITY="high" \
python3 scripts/responses_image.py
```

## Безопасность

- Скрипт не печатает API-ключ.
- HTTP-ошибки проходят через редактор, который скрывает `sk-...` и `Bearer ...`.
- В `.json`-метаданные сохраняются модель, URL, prompt и параметры генерации, но не ключ.
- Для masked edit файлы загружаются через `/files` с `purpose=vision`; обычные edit-запросы используют data URL и не требуют Files API.
