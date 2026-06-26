#!/usr/bin/env bash
set -euo pipefail

PROVIDER_NAME='vibemode'
BASE_URL='https://api.vibemod.pro/v1'
DEFAULT_MODEL='gpt-5.4'
DEFAULT_REASONING_EFFORT='medium'
ENV_KEY='CODEX_KEY'
OPENAI_ENV_KEY='OPENAI_API_KEY'
CODEX_API_ENV_KEY='CODEX_API_KEY'
AUTH_ENV_KEYS=("$ENV_KEY" "$OPENAI_ENV_KEY" "$CODEX_API_ENV_KEY")

NON_INTERACTIVE=0
REPLACE_KEY="${VIBEMODE_REPLACE_KEY:-0}"
MODEL="$DEFAULT_MODEL"
API_KEY="${CODEX_KEY:-${OPENAI_API_KEY:-${CODEX_API_KEY:-}}}"

usage() {
  cat <<USAGE
Vibemode API setup for Codex in Termux.

Usage:
  bash setup-vibemode-codex-termux.sh [options]

Options:
  --non-interactive     Do not prompt. Requires an env key or existing auth.json.
  --model MODEL         Codex model to write to config.toml. Default: gpt-5.4.
  --replace-key         Ask for a new key instead of reusing auth.json.
  -h, --help            Show this help.

Environment:
  CODEX_KEY             Preferred key variable for Vibemode/Codex.
  OPENAI_API_KEY        Compatible fallback for Codex CLI.
  CODEX_API_KEY         Compatible fallback for codex exec.
                         If unset, an existing key in auth.json is reused.
  VIBEMODE_REPLACE_KEY  Set to 1 to replace an existing auth.json key.
  CODEX_HOME            Optional Codex config directory. Default: ~/.codex.
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
    --replace-key)
      REPLACE_KEY=1
      shift
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
SHELL_ENV_FILE="$CODEX_DIR/vibemode.env"
SHELL_ENV_BEGIN='# >>> vibemode codex >>>'
SHELL_ENV_END='# <<< vibemode codex <<<'

is_termux() {
  [[ "${PREFIX:-}" == *'/com.termux/'* ]] && return 0
  [[ "${TERMUX_VERSION:-}" != '' ]] && return 0
  [[ "$(uname -o 2>/dev/null || true)" == 'Android' ]] && return 0
  return 1
}

maybe_install_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    die 'curl не найден. Установи его в Termux: pkg install curl'
  fi

  if ! command -v pkg >/dev/null 2>&1; then
    die 'curl не найден, а pkg недоступен. Установи curl и запусти скрипт снова'
  fi

  printf 'curl не найден. Установить через pkg install curl? [Y/n] '
  local answer
  read_line answer
  case "${answer:-Y}" in
    y|Y|yes|YES|д|Д|да|ДА)
      pkg install -y curl
      ;;
    *)
      die 'curl нужен для проверки API'
      ;;
  esac
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

shell_escape() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
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

tty_input_available() {
  [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null
}

tty_output_available() {
  [[ -w /dev/tty ]] && { : >/dev/tty; } 2>/dev/null
}

read_line() {
  local __var="$1"
  if tty_input_available; then
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
  if tty_input_available; then
    input_path='/dev/tty'
  fi
  if tty_output_available; then
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

for key in ("CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"):
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
  for (const key of ["CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"]) {
    const value = payload[key];
    if (typeof value === "string" && value.trim()) {
      process.stdout.write(value.trim());
      break;
    }
  }
} catch (_) {}
')"
  elif command -v jq >/dev/null 2>&1; then
    existing_key="$(jq -r '.CODEX_KEY // .OPENAI_API_KEY // .CODEX_API_KEY // empty' "$AUTH_FILE" 2>/dev/null || true)"
  else
    existing_key="$(sed -n \
      -e 's/^[[:space:]]*"CODEX_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      -e 's/^[[:space:]]*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      -e 's/^[[:space:]]*"CODEX_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$AUTH_FILE" | head -n 1)"
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

read_api_key() {
  API_KEY="$(trim_key "$API_KEY")"
  if [[ -n "$API_KEY" ]]; then
    return 0
  fi

  local existing_key replace_answer
  if existing_key="$(read_existing_api_key)" && ! is_truthy "$REPLACE_KEY"; then
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
      printf 'Сохранённый vibemode key найден. Enter = оставить, r = заменить, или вставь новый ключ (маска): '
      read_secret replace_answer
      printf '\n'
      replace_answer="$(trim_key "$replace_answer")"
      if [[ -z "$replace_answer" ]]; then
        API_KEY="$existing_key"
        return 0
      fi
      case "$replace_answer" in
        r|R|replace|REPLACE|new|NEW|n|N|н|Н|з|З|заменить|ЗАМЕНИТЬ)
          prompt_new_api_key
          return 0
          ;;
      esac
      API_KEY="$replace_answer"
      return 0
    fi
    API_KEY="$existing_key"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    if is_truthy "$REPLACE_KEY"; then
      die 'Запрошена замена API-ключа. Передай CODEX_KEY=sk-... или запусти без --non-interactive'
    fi
    die 'API-ключ не найден. Передай CODEX_KEY=sk-... или запусти без --non-interactive'
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
  log "Бэкап: $backup"
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
  printf 'cli_auth_credentials_store = "file"\n'
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
      in_root && /^[[:space:]]*cli_auth_credentials_store[[:space:]]*=/ { next }
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
  "OPENAI_API_KEY": "$escaped_key"
}
JSON
  write_if_changed "$AUTH_FILE" "$tmp" 600
}

file_mode() {
  local path="$1"
  if [[ -f "$path" ]]; then
    stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || printf '644'
  else
    printf '644'
  fi
}

write_shell_env() {
  mkdir -p "$CODEX_DIR"
  chmod 700 "$CODEX_DIR"

  local tmp escaped_key
  tmp="$(mktemp "$CODEX_DIR/vibemode.env.tmp.XXXXXX")"
  escaped_key="$(shell_escape "$API_KEY")"
  printf 'export CODEX_HOME=%s\nexport %s=%s\nexport %s=%s\nexport %s=%s\n' "$(shell_escape "$CODEX_DIR")" "$ENV_KEY" "$escaped_key" "$OPENAI_ENV_KEY" "$escaped_key" "$CODEX_API_ENV_KEY" "$escaped_key" > "$tmp"
  write_if_changed "$SHELL_ENV_FILE" "$tmp" 600
}

update_shell_startup_file() {
  local path="$1"
  local tmp mode quoted_env
  mode="$(file_mode "$path")"
  tmp="$(mktemp "$path.tmp.XXXXXX")"
  quoted_env="$(shell_escape "$SHELL_ENV_FILE")"

  if [[ -f "$path" ]]; then
    awk -v begin="$SHELL_ENV_BEGIN" -v end="$SHELL_ENV_END" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$path" > "$tmp"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
  fi

  {
    printf '%s\n' "$SHELL_ENV_BEGIN"
    printf '[ -f %s ] && . %s\n' "$quoted_env" "$quoted_env"
    printf '%s\n' "$SHELL_ENV_END"
  } >> "$tmp"

  write_if_changed "$path" "$tmp" "$mode"
}

configure_shell_env() {
  write_shell_env
  mkdir -p "$HOME"

  local shell_name startup
  shell_name="$(basename "${SHELL:-}")"
  update_shell_startup_file "$HOME/.profile"

  for startup in "$HOME/.bashrc" "$HOME/.zshrc"; do
    case "$startup" in
      "$HOME/.bashrc")
        [[ -f "$startup" || "$shell_name" == 'bash' ]] || continue
        ;;
      "$HOME/.zshrc")
        [[ -f "$startup" || "$shell_name" == 'zsh' ]] || continue
        ;;
    esac
    update_shell_startup_file "$startup"
  done
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

test_codex_cli_auth() {
  command -v codex >/dev/null 2>&1 || return 0

  local output status
  set +e
  output="$(CODEX_HOME="$CODEX_DIR" CODEX_KEY="$API_KEY" OPENAI_API_KEY="$API_KEY" CODEX_API_KEY="$API_KEY" codex 2>&1 </dev/null)"
  status="$?"
  set -e

  output="$(sanitize_api_error "$output")"
  if [[ "$output" == *'API key auth is missing a key'* ]]; then
    die "Codex CLI всё ещё видит сломанный API-key auth. CODEX_HOME=$CODEX_DIR; auth.json=$AUTH_FILE"
  fi
  log 'Codex CLI auth smoke-check пройден'
  return "$status"
}

check_responses_api() {
  local response status curl_status response_file error_file error_text request_body
  response_file="$(mktemp)"
  error_file="$(mktemp)"
  request_body="$(printf '{"model":"%s","input":[{"role":"user","content":"ping"}],"max_output_tokens":1,"stream":true}' "$(json_escape "$MODEL")")"

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
      die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: $error_text"
    fi
    die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. curl exit code: $curl_status"
  fi

  if [[ ! "$status" =~ ^2 ]]; then
    response="$(trim_error_details "$response")"
    if [[ -n "$response" ]]; then
      die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: HTTP $status | $response"
    fi
    die "не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Детали: HTTP $status"
  fi
}

main() {
  if ! is_termux; then
    warn 'это не похоже на Termux. Скрипт продолжит работу, потому что формат Codex-конфига такой же'
  fi

  maybe_install_curl
  read_api_key

  log "Папка Codex: $CODEX_DIR"
  write_config
  write_auth
  configure_shell_env
  test_codex_cli_auth || true

  log 'Проверяю Vibemode API через /v1/responses...'
  check_responses_api

  log ''
  log 'API готов'

  local source_command
  source_command="source $(shell_escape "$SHELL_ENV_FILE")"

  if command -v codex >/dev/null 2>&1; then
    log ''
    log "Codex CLI найден: $(codex --version 2>/dev/null || printf 'version unavailable')"
    log "CODEX_KEY сохранён для новых Termux-сессий: $SHELL_ENV_FILE"
    log 'ВАЖНО: текущая вкладка Termux ещё не видит CODEX_KEY.'
    log "Сначала выполни: $source_command"
    log 'Потом запускай: codex --yolo'
    log "Одной строкой: $source_command && codex --yolo"
  else
    log ''
    warn 'codex CLI не найден в PATH. Конфиг готов, но сам Codex нужно установить отдельно'
    log "CODEX_KEY сохранён для новых Termux-сессий: $SHELL_ENV_FILE"
    log "Для текущей вкладки выполни: $source_command"
  fi
}

main "$@"
