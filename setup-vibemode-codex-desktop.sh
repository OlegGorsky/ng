#!/usr/bin/env bash
set -euo pipefail

PROVIDER_NAME='vibemode'
BASE_URL='https://api.vibemod.pro/v1'
DEFAULT_MODEL='gpt-5.4'
DEFAULT_REASONING_EFFORT='medium'
ENV_KEY='CODEX_KEY'
IMAGE_HELPER_URL="${VIBEMODE_IMAGE_HELPER_URL:-https://raw.githubusercontent.com/OlegGorsky/ng/main/scripts/responses_image.py}"

NON_INTERACTIVE=0
SKIP_API_CHECK="${VIBEMODE_SKIP_API_CHECK:-0}"
INSTALL_IMAGE_HELPER=1
REPLACE_KEY="${VIBEMODE_REPLACE_KEY:-0}"
MODEL="$DEFAULT_MODEL"
API_KEY="${CODEX_KEY:-}"
IMAGE_HELPER_PATH="${VIBEMODE_IMAGE_HELPER_PATH:-$HOME/.local/bin/responses-image}"

usage() {
  cat <<USAGE
Настройка Vibemode API для Codex Desktop на Linux и macOS.

Использование:
  bash setup-vibemode-codex-desktop.sh [options]

Опции:
  --non-interactive       Не спрашивать ввод. Нужен ключ в env или существующий auth.json.
  --model MODEL           Модель Codex для config.toml. По умолчанию: gpt-5.4.
  --skip-api-check        Записать файлы без проверки /v1/responses.
  --no-image-helper       Не ставить команду responses-image.
  --replace-key           Попросить новый ключ вместо переиспользования auth.json.
  --image-helper-path P   Куда поставить responses-image. По умолчанию: ~/.local/bin/responses-image.
  -h, --help              Показать эту справку.

Переменные окружения:
  CODEX_KEY               Основной способ передать Vibemode/Codex key в non-interactive режиме.
                          Если переменная пуста, переиспользуется CODEX_KEY из auth.json.
  VIBEMODE_REPLACE_KEY    Установи 1, чтобы заменить сохранённый ключ.
  VIBEMODE_SKIP_API_CHECK Установи 1, чтобы записать файлы без проверки /v1/responses.
  CODEX_HOME              Необязательная папка конфига Codex Desktop. По умолчанию: ~/.codex.
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Внимание: %s\n' "$*" >&2
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --model)
      [[ $# -ge 2 ]] || die '--model требует значение'
      MODEL="$2"
      shift 2
      ;;
    --skip-api-check)
      SKIP_API_CHECK=1
      shift
      ;;
    --no-image-helper)
      INSTALL_IMAGE_HELPER=0
      shift
      ;;
    --replace-key)
      REPLACE_KEY=1
      shift
      ;;
    --image-helper-path)
      [[ $# -ge 2 ]] || die '--image-helper-path требует значение'
      IMAGE_HELPER_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "неизвестный аргумент: $1"
      ;;
  esac
done

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_DIR/config.toml"
AUTH_FILE="$CODEX_DIR/auth.json"

maybe_install_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi

  die 'curl нужен для установки. Установи curl и запусти скрипт снова'
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

toml_escape() {
  json_escape "$1"
}

trim_key() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON|да|ДА|д|Д)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_line() {
  local __var="$1"
  if [[ -r /dev/tty ]]; then
    IFS= read -r "$__var" </dev/tty
  else
    IFS= read -r "$__var"
  fi
}

read_secret() {
  local __var="$1"
  local input='' char='' input_path output_path old_stty=''
  input_path='/dev/stdin'
  output_path='/dev/stderr'
  if [[ -r /dev/tty ]]; then
    input_path='/dev/tty'
  fi
  if [[ -w /dev/tty ]]; then
    output_path='/dev/tty'
  fi

  if [[ "$input_path" == '/dev/tty' ]]; then
    old_stty="$(stty -g < /dev/tty 2>/dev/null || true)"
    stty -echo < /dev/tty 2>/dev/null || true
  fi

  while IFS= read -r -s -n 1 char < "$input_path"; do
    if [[ -z "$char" || "$char" == $'\r' || "$char" == $'\n' ]]; then
      break
    fi
    if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
      if [[ -n "$input" ]]; then
        input="${input%?}"
        printf '\b \b' > "$output_path"
      fi
      continue
    fi
    input+="$char"
    printf '*' > "$output_path"
  done

  if [[ -n "$old_stty" ]]; then
    stty "$old_stty" < /dev/tty 2>/dev/null || true
  fi

  printf -v "$__var" '%s' "$input"
}

read_existing_api_key() {
  [[ -f "$AUTH_FILE" ]] || return 1

  local existing_key=''
  if command -v python3 >/dev/null 2>&1; then
    existing_key="$(AUTH_FILE_PATH="$AUTH_FILE" python3 - <<'PY'
import json
import os

try:
    with open(os.environ["AUTH_FILE_PATH"], encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    raise SystemExit(0)

for key in ("CODEX_KEY",):
    value = payload.get(key)
    if isinstance(value, str) and value.strip():
        print(value.strip())
        break
PY
)"
  elif command -v node >/dev/null 2>&1; then
    existing_key="$(AUTH_FILE_PATH="$AUTH_FILE" node -e '
const fs = require("fs");
try {
  const payload = JSON.parse(fs.readFileSync(process.env.AUTH_FILE_PATH, "utf8"));
  for (const key of ["CODEX_KEY"]) {
    const value = payload[key];
    if (typeof value === "string" && value.trim()) {
      process.stdout.write(value.trim());
      break;
    }
  }
} catch (_) {}
')"
  elif command -v jq >/dev/null 2>&1; then
    existing_key="$(jq -r '.CODEX_KEY // empty' "$AUTH_FILE" 2>/dev/null || true)"
  else
    existing_key="$(sed -n 's/^[[:space:]]*"CODEX_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AUTH_FILE" | head -n 1)"
  fi

  existing_key="$(trim_key "$existing_key")"
  [[ -n "$existing_key" ]] || return 1
  printf '%s' "$existing_key"
}

prompt_new_api_key() {
  printf 'Вставь vibemode key (одна * на символ): '
  read_secret API_KEY
  printf '\n'
  API_KEY="$(trim_key "$API_KEY")"

  [[ -n "$API_KEY" ]] || die 'API-ключ не найден'
}

choose_found_api_key() {
  local label="$1"
  local found_key="$2"
  local replace_answer
  found_key="$(trim_key "$found_key")"
  [[ -n "$found_key" ]] || return 1

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    API_KEY="$found_key"
    return 0
  fi

  if is_truthy "$REPLACE_KEY"; then
    prompt_new_api_key
    return 0
  fi

  printf '%s. Enter = использовать, r = заменить, или вставь новый ключ (маска): ' "$label"
  read_secret replace_answer
  printf '\n'
  replace_answer="$(trim_key "$replace_answer")"
  if [[ -z "$replace_answer" ]]; then
    API_KEY="$found_key"
    return 0
  fi
  case "$replace_answer" in
    r|R|replace|REPLACE|new|NEW|n|N|н|Н|з|З|заменить|ЗАМЕНИТЬ)
      prompt_new_api_key
      return 0
      ;;
  esac
  API_KEY="$replace_answer"
}

read_api_key() {
  API_KEY="$(trim_key "$API_KEY")"
  if [[ -n "$API_KEY" ]]; then
    choose_found_api_key 'vibemode key найден в переменной окружения' "$API_KEY"
    return 0
  fi

  local existing_key
  if existing_key="$(read_existing_api_key)"; then
    choose_found_api_key 'Сохранённый vibemode key найден' "$existing_key"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    if is_truthy "$REPLACE_KEY"; then
      die 'Запрошена замена API-ключа. Передай CODEX_KEY или запусти скрипт интерактивно'
    fi
    die 'API-ключ не найден. Передай CODEX_KEY или один раз запусти скрипт интерактивно'
  fi

  prompt_new_api_key
}

backup_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$path.bak-$stamp"
  cp "$path" "$backup"
  chmod 600 "$backup" 2>/dev/null || true
  log "Backup: $backup"
}

write_if_changed() {
  local target="$1"
  local tmp="$2"
  local mode="$3"

  if [[ -f "$target" ]] && cmp -s "$target" "$tmp"; then
    rm -f "$tmp"
    chmod "$mode" "$target"
    return 0
  fi

  backup_file "$target"
  mv "$tmp" "$target"
  chmod "$mode" "$target"
}

build_config_body() {
  local escaped_model escaped_provider escaped_url escaped_effort escaped_env_key
  escaped_model="$(toml_escape "$MODEL")"
  escaped_provider="$(toml_escape "$PROVIDER_NAME")"
  escaped_url="$(toml_escape "$BASE_URL")"
  escaped_effort="$(toml_escape "$DEFAULT_REASONING_EFFORT")"
  escaped_env_key="$(toml_escape "$ENV_KEY")"

  printf 'model = "%s"\n' "$escaped_model"
  printf 'model_provider = "%s"\n' "$escaped_provider"
  printf '\n'

  if [[ -f "$CONFIG_FILE" ]]; then
    awk -v provider="$PROVIDER_NAME" '
      BEGIN {
        in_root = 1
        skip_table = 0
        provider_header = "[model_providers." provider "]"
        quoted_provider_header = "[model_providers.\"" provider "\"]"
        old_provider_header = "[model_providers.\"NeuroGate API\"]"
        old_unquoted_provider_header = "[model_providers.NeuroGate API]"
        default_profile_header = "[profiles.default]"
      }
      /^[[:space:]]*\[/ {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        in_root = 0
        if (line == provider_header || line == quoted_provider_header || line == old_provider_header || line == old_unquoted_provider_header || line == default_profile_header) {
          skip_table = 1
          next
        }
        skip_table = 0
      }
      skip_table { next }
      in_root && /^[[:space:]]*model[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_reasoning_effort[[:space:]]*=/ { next }
      { print }
    ' "$CONFIG_FILE"
    printf '\n'
  fi

  printf '\n[model_providers.%s]\n' "$escaped_provider"
  printf 'name = "%s"\n' "$escaped_provider"
  printf 'base_url = "%s"\n' "$escaped_url"
  printf 'env_key = "%s"\n' "$escaped_env_key"
  printf '\n[profiles.default]\n'
  printf 'model = "%s"\n' "$escaped_model"
  printf 'model_provider = "%s"\n' "$escaped_provider"
  printf 'reasoning_effort = "%s"\n' "$escaped_effort"
}

write_config() {
  mkdir -p "$CODEX_DIR"
  chmod 700 "$CODEX_DIR"

  local tmp
  tmp="$(mktemp "$CODEX_DIR/config.toml.tmp.XXXXXX")"
  build_config_body > "$tmp"
  write_if_changed "$CONFIG_FILE" "$tmp" 600
}

write_auth() {
  mkdir -p "$CODEX_DIR"
  chmod 700 "$CODEX_DIR"

  local tmp escaped_key
  tmp="$(mktemp "$CODEX_DIR/auth.json.tmp.XXXXXX")"
  escaped_key="$(json_escape "$API_KEY")"
  cat > "$tmp" <<JSON
{
  "auth_mode": "apikey",
  "CODEX_KEY": "$escaped_key"
}
JSON
  write_if_changed "$AUTH_FILE" "$tmp" 600
}

sanitize_api_error() {
  local text="$1"
  if [[ -n "${API_KEY:-}" ]]; then
    text="${text//"$API_KEY"/[redacted]}"
  fi
  text="$(sed -E \
    -e 's/[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+\/=-]+/Bearer [redacted]/g' \
    -e 's/sk-[A-Za-z0-9_*.-]{8,}/sk-[redacted]/g' <<< "$text")"
  printf '%s' "$text"
}

trim_error_details() {
  local text="$1"
  text="$(sanitize_api_error "$text")"
  if [[ "${#text}" -gt 500 ]]; then
    text="${text:0:500}..."
  fi
  printf '%s' "$text"
}

api_check_failure_hint() {
  printf '%s' ' Подсказка: HTTP 401 обычно означает, что API-ключ не принят. Для короткой команды положи новый ключ в CODEX_KEY и запусти с VIBEMODE_REPLACE_KEY=1; чтобы только записать файлы без проверки, используй VIBEMODE_SKIP_API_CHECK=1.'
}

check_responses_api() {
  local response status curl_status response_file error_file error_text request_body
  response_file="$(mktemp)"
  error_file="$(mktemp)"
  request_body="$(printf '{"model":"%s","input":"ping","max_output_tokens":1}' "$(json_escape "$MODEL")")"

  set +e
  status="$(curl -sS --connect-timeout 20 --max-time 60 \
    -X POST \
    -o "$response_file" \
    -w '%{http_code}' \
    "$BASE_URL/responses" \
    -H "Authorization: Bearer $API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$request_body" 2>"$error_file")"
  curl_status="$?"
  set -e

  response="$(cat "$response_file")"
  error_text="$(cat "$error_file")"
  rm -f "$response_file" "$error_file"

  if [[ "$curl_status" -ne 0 ]]; then
    error_text="$(trim_error_details "$error_text")"
    if [[ -n "$error_text" ]]; then
      die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: $error_text$(api_check_failure_hint)"
    fi
    die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. curl exit code: $curl_status$(api_check_failure_hint)"
  fi

  if [[ ! "$status" =~ ^2 ]]; then
    response="$(trim_error_details "$response")"
    if [[ -n "$response" ]]; then
      die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: HTTP $status | $response$(api_check_failure_hint)"
    fi
    die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: HTTP $status$(api_check_failure_hint)"
  fi
}

install_image_helper() {
  [[ "$INSTALL_IMAGE_HELPER" -eq 1 ]] || return 0

  local helper_dir
  helper_dir="$(dirname "$IMAGE_HELPER_PATH")"
  mkdir -p "$helper_dir"
  curl -fsSL "$IMAGE_HELPER_URL" -o "$IMAGE_HELPER_PATH"
  chmod +x "$IMAGE_HELPER_PATH"
  log "Helper для картинок: $IMAGE_HELPER_PATH"
  if ! command -v python3 >/dev/null 2>&1; then
    warn 'python3 не найден в PATH. Установи Python перед использованием responses-image.'
  fi
}

main() {
  maybe_install_curl
  read_api_key

  log "Папка Codex Desktop: $CODEX_DIR"
  write_config
  write_auth
  install_image_helper

  if is_truthy "$SKIP_API_CHECK"; then
    log 'Проверка /v1/responses пропущена'
  else
    log 'Проверяю Vibemode API через /v1/responses...'
    check_responses_api

    log ''
    log 'API готов'
  fi

  log ''
  log 'Перезапусти Codex Desktop, чтобы он перечитал provider config.'
  log "Пример helper для генерации картинок: $IMAGE_HELPER_PATH --list-presets"
}

main "$@"
