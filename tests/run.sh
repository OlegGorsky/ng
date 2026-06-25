#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/setup-vibemode-codex-termux.sh"
DESKTOP_SCRIPT="$ROOT_DIR/setup-vibemode-codex-desktop.sh"
DESKTOP_PS="$ROOT_DIR/setup-vibemode-codex-desktop.ps1"
BOOTSTRAP="$ROOT_DIR/i"
DESKTOP_BOOTSTRAP="$ROOT_DIR/d"
DESKTOP_BOOTSTRAP_PS="$ROOT_DIR/d.ps1"
PACKAGE_JSON="$ROOT_DIR/package.json"
CLI="$ROOT_DIR/bin/vibemode.js"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf 'ok - %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$path"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_not_contains_text() {
  local text="$1"
  local needle="$2"
  local label="$3"
  if [[ "$text" == *"$needle"* ]]; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_not_contains_file() {
  local path="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$path"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_count() {
  local path="$1"
  local needle="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(grep -F -- "$needle" "$path" | wc -l | tr -d ' ')"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    printf 'expected %s occurrences, got %s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

assert_utf8_bom() {
  local path="$1"
  local label="$2"
  local prefix
  prefix="$(od -An -N3 -tx1 "$path" | tr -d ' \n')"
  if [[ "$prefix" == 'efbbbf' ]]; then
    pass "$label"
  else
    printf 'expected UTF-8 BOM, got prefix %s\n' "$prefix" >&2
    fail "$label"
  fi
}

assert_ascii_file() {
  local path="$1"
  local label="$2"
  if LC_ALL=C grep -n '[^ -~[:space:]]' "$path" >/tmp/vibemode-ascii-check.$$ 2>/dev/null; then
    cat /tmp/vibemode-ascii-check.$$ >&2
    rm -f /tmp/vibemode-ascii-check.$$
    fail "$label"
  else
    rm -f /tmp/vibemode-ascii-check.$$
    pass "$label"
  fi
}

make_fake_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
output_path=''
write_out=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_path="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

body='{
  "object": "list",
  "data": [
    { "id": "gpt-5.4" },
    { "id": "gpt-5" },
    { "id": "gpt-4.1" }
  ]
}'

if [[ -n "$output_path" ]]; then
  printf '%s\n' "$body" > "$output_path"
else
  printf '%s\n' "$body"
fi

if [[ -n "$write_out" ]]; then
  printf '200'
fi
FAKE_CURL
  chmod +x "$bin_dir/curl"
}

make_fake_legacy_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'FAKE_LEGACY_CURL'
#!/usr/bin/env bash
cat <<'JSON'
{
  "object": "list",
  "data": [
    { "id": "gpt-5.4" },
    { "id": "gpt-5" },
    { "id": "gpt-4.1" }
  ]
}
JSON
FAKE_LEGACY_CURL
  chmod +x "$bin_dir/curl"
}

make_fake_bootstrap_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'FAKE_BOOTSTRAP_CURL'
#!/usr/bin/env bash
output_path=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output_path" ]]; then
  printf 'missing -o\n' >&2
  exit 2
fi

cat > "$output_path" <<'DOWNLOADED_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'downloaded setup ran'
for arg in "$@"; do
  printf ' [%s]' "$arg"
done
printf '\n'
DOWNLOADED_SCRIPT
FAKE_BOOTSTRAP_CURL
  chmod +x "$bin_dir/curl"
}

make_fake_desktop_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'FAKE_DESKTOP_CURL'
#!/usr/bin/env bash
output_path=''
write_out=''
url=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_path="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    *)
      if [[ "$1" == http://* || "$1" == https://* ]]; then
        url="$1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$output_path" && "$url" == *'responses_image.py' ]]; then
  cat > "$output_path" <<'PY'
#!/usr/bin/env python3
print("responses-image helper")
PY
  exit 0
fi

body='{
  "object": "list",
  "data": [
    { "id": "gpt-5.4" },
    { "id": "gpt-5" },
    { "id": "gpt-4.1" }
  ]
}'

if [[ -n "$output_path" ]]; then
  printf '%s\n' "$body" > "$output_path"
else
  printf '%s\n' "$body"
fi

if [[ -n "$write_out" ]]; then
  printf '200'
fi
FAKE_DESKTOP_CURL
  chmod +x "$bin_dir/curl"
}

make_fake_api_error_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'FAKE_API_ERROR_CURL'
#!/usr/bin/env bash
output_path=''
write_out=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_path="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

bearer_token='abcdefgh'"ijklmnop"
sk_token='sk-abcdefgh'"ijkl"
body="{\"error\":{\"message\":\"bad key Bearer $bearer_token $sk_token\",\"type\":\"authentication_error\",\"code\":\"unauthorized\"}}"

if [[ -n "$output_path" ]]; then
  printf '%s' "$body" > "$output_path"
else
  printf '%s' "$body"
fi

if [[ -n "$write_out" ]]; then
  printf '401'
fi
FAKE_API_ERROR_CURL
  chmod +x "$bin_dir/curl"
}

run_setup() {
  local home_dir="$1"
  local bin_dir="$2"
  CODEX_KEY='test-api-key' \
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$bin_dir:$PATH" \
    bash "$SCRIPT" --non-interactive 2>&1
}

run_desktop_setup() {
  local home_dir="$1"
  local bin_dir="$2"
  CODEX_KEY='test-api-key' \
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$bin_dir:$PATH" \
    bash "$DESKTOP_SCRIPT" --non-interactive 2>&1
}

run_cli() {
  local home_dir="$1"
  shift
  HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    node "$CLI" "$@" 2>&1
}

test_npm_cli_package_metadata() {
  assert_file "$PACKAGE_JSON" 'npm CLI package.json exists'
  assert_file "$CLI" 'npm CLI executable exists'
  assert_contains "$PACKAGE_JSON" '"name": "vibemode-codex"' 'package uses publishable npm package name'
  assert_contains "$PACKAGE_JSON" '"vibemode-codex": "bin/vibemode.js"' 'package exposes npx package-name bin'
  assert_contains "$PACKAGE_JSON" '"vibemode": "bin/vibemode.js"' 'package exposes vibemode bin'
  assert_contains "$PACKAGE_JSON" '"@openai/codex"' 'package documents Codex CLI peer tool'
  assert_contains "$PACKAGE_JSON" '"scripts/responses_image.py"' 'package ships image helper source without Python cache directories'
  assert_not_contains_file "$PACKAGE_JSON" '"scripts",' 'package does not include whole scripts directory'
  if node "$CLI" --help >/dev/null 2>&1; then
    pass 'npm CLI supports global help flag'
  else
    fail 'npm CLI supports global help flag'
  fi
  if [[ -x "$CLI" ]]; then
    pass 'npm CLI executable bit is set'
  else
    fail 'npm CLI executable bit is set'
  fi
}

test_npm_cli_setup_status_openai_and_run() {
  local tmp bin output status_output run_output config capture
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  config="$tmp/home/.codex/config.toml"
  capture="$tmp/run-env.txt"
  mkdir -p "$bin"

  cat > "$bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
printf 'CODEX_KEY=%s\n' "${CODEX_KEY:-missing}" > "$VIBEMODE_RUN_CAPTURE"
printf 'fake codex %s\n' "$*"
FAKE_CODEX
  chmod +x "$bin/codex"

  if ! output="$(CODEX_KEY='test-api-key' PATH="$bin:$PATH" run_cli "$tmp/home" setup --non-interactive --skip-api-check --target all)"; then
    printf '%s\n' "$output" >&2
    fail 'npm CLI setup writes Vibemode config'
    rm -rf "$tmp"
    return
  fi
  pass 'npm CLI setup writes Vibemode config'

  assert_file "$config" 'npm CLI creates config.toml'
  assert_file "$tmp/home/.codex/auth.json" 'npm CLI creates auth.json'
  assert_file "$tmp/home/.codex/vibemode.env" 'npm CLI creates shell env file'
  assert_contains "$config" 'model = "gpt-5.4"' 'npm CLI writes default model'
  assert_contains "$config" 'model_provider = "vibemode"' 'npm CLI selects Vibemode provider'
  assert_contains "$config" '[model_providers.vibemode]' 'npm CLI writes Vibemode provider table'
  assert_contains "$config" 'base_url = "https://api.vibemod.pro/v1"' 'npm CLI writes Vibemode base URL'
  assert_contains "$config" 'env_key = "CODEX_KEY"' 'npm CLI writes Codex env key'
  assert_contains "$config" '[profiles.default]' 'npm CLI writes default profile'
  assert_contains "$config" 'reasoning_effort = "medium"' 'npm CLI writes reasoning effort'
  assert_contains "$tmp/home/.codex/auth.json" '"CODEX_KEY": "test-api-key"' 'npm CLI writes auth key'
  assert_contains "$tmp/home/.codex/vibemode.env" "export CODEX_KEY='test-api-key'" 'npm CLI writes shell CODEX_KEY export'
  assert_contains "$tmp/home/.profile" '.codex/vibemode.env' 'npm CLI wires shell startup'
  assert_not_contains_text "$output" 'test-api-key' 'npm CLI setup does not print API key'

  if ! status_output="$(PATH="$bin:$PATH" run_cli "$tmp/home" status)"; then
    printf '%s\n' "$status_output" >&2
    fail 'npm CLI status exits successfully'
    rm -rf "$tmp"
    return
  fi
  pass 'npm CLI status exits successfully'
  if [[ "$status_output" == *'provider: vibemode'* && "$status_output" == *'key: saved'* ]]; then
    pass 'npm CLI status reports Vibemode and saved key'
  else
    printf '%s\n' "$status_output" >&2
    fail 'npm CLI status reports Vibemode and saved key'
  fi
  assert_not_contains_text "$status_output" 'test-api-key' 'npm CLI status does not print API key'

  if ! run_output="$(VIBEMODE_RUN_CAPTURE="$capture" PATH="$bin:$PATH" run_cli "$tmp/home" run -- codex --yolo)"; then
    printf '%s\n' "$run_output" >&2
    fail 'npm CLI run launches command with saved key'
    rm -rf "$tmp"
    return
  fi
  pass 'npm CLI run launches command with saved key'
  assert_contains "$capture" 'CODEX_KEY=test-api-key' 'npm CLI run injects saved CODEX_KEY'
  assert_not_contains_text "$run_output" 'test-api-key' 'npm CLI run does not print API key'

  if ! output="$(PATH="$bin:$PATH" run_cli "$tmp/home" use openai --non-interactive)"; then
    printf '%s\n' "$output" >&2
    fail 'npm CLI switches back to OpenAI config'
    rm -rf "$tmp"
    return
  fi
  pass 'npm CLI switches back to OpenAI config'
  assert_contains "$config" 'model_provider = "openai"' 'npm CLI writes OpenAI provider'
  assert_not_contains_file "$config" 'api.vibemod.pro' 'npm CLI removes Vibemode URL'
  assert_not_contains_file "$config" 'NeuroGate' 'npm CLI removes old NeuroGate provider'
  assert_not_contains_file "$config" 'wire_api' 'npm CLI removes legacy wire_api'

  if ! output="$(PATH="$bin:$PATH" run_cli "$tmp/home" remove --non-interactive)"; then
    printf '%s\n' "$output" >&2
    fail 'npm CLI removes Vibemode key material'
    rm -rf "$tmp"
    return
  fi
  pass 'npm CLI removes Vibemode key material'
  if [[ ! -f "$tmp/home/.codex/vibemode.env" ]]; then
    pass 'npm CLI removes shell env file'
  else
    fail 'npm CLI removes shell env file'
  fi
  assert_not_contains_file "$tmp/home/.profile" 'vibemode codex' 'npm CLI removes shell startup block'

  rm -rf "$tmp"
}

test_creates_files_and_reports_models() {
  local tmp bin output
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_curl "$bin"
  cat > "$bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
printf 'codex-cli 0.140.0\n'
FAKE_CODEX
  chmod +x "$bin/codex"

  if ! output="$(run_setup "$tmp/home" "$bin")"; then
    printf '%s\n' "$output" >&2
    fail 'script exits successfully with env API key'
    rm -rf "$tmp"
    return
  fi
  pass 'script exits successfully with env API key'

  assert_file "$tmp/home/.codex/config.toml" 'creates config.toml'
  assert_file "$tmp/home/.codex/auth.json" 'creates auth.json'
  assert_file "$tmp/home/.codex/vibemode.env" 'creates shell env file'
  assert_contains "$tmp/home/.codex/config.toml" 'model = "gpt-5.4"' 'writes default model'
  assert_contains "$tmp/home/.codex/config.toml" 'model_provider = "vibemode"' 'selects Vibemode provider'
  assert_contains "$tmp/home/.codex/config.toml" '[model_providers.vibemode]' 'writes Vibemode provider table'
  assert_contains "$tmp/home/.codex/config.toml" 'base_url = "https://api.vibemod.pro/v1"' 'writes Vibemode base URL'
  assert_contains "$tmp/home/.codex/config.toml" 'env_key = "CODEX_KEY"' 'writes Vibemode env key'
  assert_contains "$tmp/home/.codex/config.toml" '[profiles.default]' 'writes default profile'
  assert_contains "$tmp/home/.codex/config.toml" 'reasoning_effort = "medium"' 'writes profile reasoning effort'
  assert_not_contains_file "$tmp/home/.codex/config.toml" 'model_reasoning_effort' 'does not write legacy root reasoning key'
  assert_not_contains_file "$tmp/home/.codex/config.toml" 'wire_api = "responses"' 'does not write legacy wire_api'
  assert_contains "$tmp/home/.codex/auth.json" '"CODEX_KEY": "test-api-key"' 'writes API key to auth.json'
  assert_contains "$tmp/home/.codex/vibemode.env" "export CODEX_KEY='test-api-key'" 'writes shell CODEX_KEY export'
  assert_contains "$tmp/home/.profile" '.codex/vibemode.env' 'profile sources shell env file'
  assert_not_contains_text "$output" 'test-api-key' 'does not print API key'
  assert_not_contains_text "$output" 'Authorization: Bearer' 'does not print bearer header'
  assert_not_contains_text "$output" 'gho_' 'does not print unrelated tokens'
  if [[ "$output" == *'Одной строкой:'* && "$output" == *'source '* && "$output" == *'&& codex --yolo'* ]]; then
    pass 'prints current Termux tab activation one-liner'
  else
    printf '%s\n' "$output" >&2
    fail 'prints current Termux tab activation one-liner'
  fi

  if [[ "$output" == *'API готов'* && "$output" == *'gpt-5.4'* && "$output" == *'gpt-5'* ]]; then
    pass 'prints ready message and available models'
  else
    printf '%s\n' "$output" >&2
    fail 'prints ready message and available models'
  fi

  rm -rf "$tmp"
}

test_repairs_config_idempotently() {
  local tmp bin config output
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  config="$tmp/home/.codex/config.toml"
  mkdir -p "$bin" "$(dirname "$config")"
  make_fake_curl "$bin"

cat > "$config" <<'TOML'
model = "old-model"
model_provider = "Old Provider"
model_reasoning_effort = "high"
approval_policy = "never"

[model_providers."NeuroGate API"]
name = "old"
base_url = "https://api.neurogate.space/v1"
wire_api = "responses"

[model_providers."vibemode"]
name = "broken"
base_url = "https://wrong.example/v1"
wire_api = "chat"

[profiles.default]
model = "old-profile-model"
model_provider = "Old Provider"
reasoning_effort = "high"

[profiles.termux]
sandbox_mode = "workspace-write"
TOML

  if ! output="$(run_setup "$tmp/home" "$bin")"; then
    printf '%s\n' "$output" >&2
    fail 'script repairs existing config'
    rm -rf "$tmp"
    return
  fi
  pass 'script repairs existing config'

  if ! output="$(run_setup "$tmp/home" "$bin")"; then
    printf '%s\n' "$output" >&2
    fail 'script is idempotent on second run'
    rm -rf "$tmp"
    return
  fi
  pass 'script is idempotent on second run'

  assert_contains "$config" 'approval_policy = "never"' 'preserves unrelated root settings'
  assert_contains "$config" '[profiles.termux]' 'preserves unrelated tables'
  assert_contains "$config" 'sandbox_mode = "workspace-write"' 'preserves unrelated table content'
  assert_count "$config" 'model = "gpt-5.4"' '2' 'keeps root and profile model keys'
  assert_count "$config" 'model_provider = "vibemode"' '2' 'keeps root and profile provider keys'
  assert_count "$config" '[model_providers.vibemode]' '1' 'keeps one Vibemode provider table'
  assert_count "$config" '[profiles.default]' '1' 'keeps one default profile'
  assert_count "$config" 'base_url = "https://api.vibemod.pro/v1"' '1' 'keeps one correct base URL'
  assert_contains "$config" 'env_key = "CODEX_KEY"' 'keeps one env key'
  assert_contains "$config" 'reasoning_effort = "medium"' 'keeps profile reasoning effort'
  assert_count "$tmp/home/.profile" '# >>> vibemode codex >>>' '1' 'keeps one shell env source block'
  assert_not_contains_file "$config" 'api.neurogate.space' 'removes old NeuroGate URL'
  assert_not_contains_file "$config" 'NeuroGate API' 'removes old NeuroGate provider'
  assert_not_contains_file "$config" 'wire_api' 'removes legacy wire_api'
  assert_not_contains_file "$config" 'model_reasoning_effort' 'removes legacy root reasoning key'

  rm -rf "$tmp"
}

test_reuses_existing_auth_key_non_interactive() {
  local tmp bin output auth
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  auth="$tmp/home/.codex/auth.json"
  mkdir -p "$bin" "$(dirname "$auth")"
  make_fake_curl "$bin"

  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "existing-test-api-key"
}
JSON

  if ! output="$(env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" bash "$SCRIPT" --non-interactive 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail 'non-interactive mode reuses existing auth.json key'
    rm -rf "$tmp"
    return
  fi
  pass 'non-interactive mode reuses existing auth.json key'

  assert_contains "$auth" '"CODEX_KEY": "existing-test-api-key"' 'keeps existing API key'
  assert_contains "$tmp/home/.codex/vibemode.env" "export CODEX_KEY='existing-test-api-key'" 'writes reused key to shell env'
  assert_not_contains_text "$output" 'existing-test-api-key' 'does not print reused API key'

  rm -rf "$tmp"
}

test_desktop_setup_creates_config_and_image_helper() {
  local tmp bin output helper
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  helper="$tmp/home/.local/bin/responses-image"
  mkdir -p "$bin"
  make_fake_desktop_curl "$bin"

  if ! output="$(run_desktop_setup "$tmp/home" "$bin")"; then
    printf '%s\n' "$output" >&2
    fail 'desktop setup exits successfully with env API key'
    rm -rf "$tmp"
    return
  fi
  pass 'desktop setup exits successfully with env API key'

  assert_file "$tmp/home/.codex/config.toml" 'desktop setup creates config.toml'
  assert_file "$tmp/home/.codex/auth.json" 'desktop setup creates auth.json'
  assert_file "$helper" 'desktop setup installs image helper'
  if [[ -x "$helper" ]]; then
    pass 'desktop image helper is executable'
  else
    fail 'desktop image helper is executable'
  fi
  assert_contains "$tmp/home/.codex/config.toml" 'base_url = "https://api.vibemod.pro/v1"' 'desktop setup writes Vibemode base URL'
  assert_contains "$tmp/home/.codex/auth.json" '"CODEX_KEY": "test-api-key"' 'desktop setup writes API key'
  assert_not_contains_text "$output" 'test-api-key' 'desktop setup does not print API key'

  rm -rf "$tmp"
}

test_desktop_setup_reuses_existing_auth_key() {
  local tmp bin output auth helper
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  auth="$tmp/home/.codex/auth.json"
  helper="$tmp/home/.local/bin/responses-image"
  mkdir -p "$bin" "$(dirname "$auth")"
  make_fake_desktop_curl "$bin"

  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "existing-test-api-key"
}
JSON

  if ! output="$(env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" bash "$DESKTOP_SCRIPT" --non-interactive 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail 'desktop setup reuses existing auth.json key'
    rm -rf "$tmp"
    return
  fi
  pass 'desktop setup reuses existing auth.json key'

  assert_file "$helper" 'desktop setup installs image helper while reusing key'
  assert_contains "$auth" '"CODEX_KEY": "existing-test-api-key"' 'desktop setup keeps existing API key'
  assert_not_contains_text "$output" 'existing-test-api-key' 'desktop setup does not print reused API key'

  rm -rf "$tmp"
}

test_desktop_setup_can_replace_existing_auth_key() {
  local tmp auth output
  if ! command -v script >/dev/null 2>&1; then
    pass 'desktop replace key prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  auth="$tmp/home/.codex/auth.json"
  mkdir -p "$(dirname "$auth")"
  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "old-test-api-key"
}
JSON

  if output="$(printf 'r\nnew-test-api-key\n' | env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" \
    script -qfec "bash \"$DESKTOP_SCRIPT\" --skip-api-check --no-image-helper" /dev/null 2>&1)"; then
    pass 'desktop setup can replace existing auth.json key'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup can replace existing auth.json key'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$auth" '"CODEX_KEY": "new-test-api-key"' 'desktop setup writes replacement API key'
  if [[ "$output" == *'****************'* ]]; then
    pass 'desktop replacement prompt prints one mask star per new key character'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop replacement prompt prints one mask star per new key character'
  fi

  rm -rf "$tmp"
}

test_desktop_setup_can_replace_env_key_interactively() {
  local tmp auth output
  if ! command -v script >/dev/null 2>&1; then
    pass 'desktop env key replacement prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  auth="$tmp/home/.codex/auth.json"

  if output="$(printf 'r\nnew-env-test-key\n' | CODEX_KEY='env-test-api-key' HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" \
    script -qfec "bash \"$DESKTOP_SCRIPT\" --skip-api-check --no-image-helper" /dev/null 2>&1)"; then
    pass 'desktop setup can replace env API key interactively'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup can replace env API key interactively'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$auth" '"CODEX_KEY": "new-env-test-key"' 'desktop env key prompt writes replacement API key'
  if [[ "$output" == *'vibemode key найден в переменной окружения'* && "$output" == *'****************'* ]]; then
    pass 'desktop env key prompt asks before reusing env key'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop env key prompt asks before reusing env key'
  fi
  assert_not_contains_text "$output" 'env-test-api-key' 'desktop env key prompt does not print env key'

  rm -rf "$tmp"
}

test_desktop_setup_masks_direct_key_paste_over_existing_auth() {
  local tmp auth output
  if ! command -v script >/dev/null 2>&1; then
    pass 'desktop direct key paste prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  auth="$tmp/home/.codex/auth.json"
  mkdir -p "$(dirname "$auth")"
  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "old-test-api-key"
}
JSON

  if output="$(printf 'direct-test-api-key\n' | env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" \
    script -qfec "bash \"$DESKTOP_SCRIPT\" --skip-api-check --no-image-helper" /dev/null 2>&1)"; then
    pass 'desktop setup accepts direct masked key paste over existing auth'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup accepts direct masked key paste over existing auth'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$auth" '"CODEX_KEY": "direct-test-api-key"' 'desktop direct paste writes replacement API key'
  if [[ "$output" == *'*******************'* ]]; then
    pass 'desktop direct paste prints one mask star per key character'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop direct paste prints one mask star per key character'
  fi

  rm -rf "$tmp"
}

test_desktop_api_check_reports_safe_details() {
  local tmp bin output status
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_api_error_curl "$bin"

  set +e
  output="$(CODEX_KEY='test-api-key' HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" \
    bash "$DESKTOP_SCRIPT" --non-interactive --no-image-helper 2>&1)"
  status="$?"
  set -e

  if [[ "$status" != '0' ]]; then
    pass 'desktop setup fails when API check returns 401'
  else
    fail 'desktop setup fails when API check returns 401'
  fi

  assert_file "$tmp/home/.codex/config.toml" 'desktop setup writes config before failed API check'
  assert_file "$tmp/home/.codex/auth.json" 'desktop setup writes auth before failed API check'

  if [[ "$output" == *'HTTP 401'* && "$output" == *'Настройки записаны'* ]]; then
    pass 'desktop setup reports safe API check details'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup reports safe API check details'
  fi
  if [[ "$output" == *'VIBEMODE_REPLACE_KEY'* && "$output" == *'VIBEMODE_SKIP_API_CHECK'* ]]; then
    pass 'desktop setup explains how to replace key or skip API check'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup explains how to replace key or skip API check'
  fi
  assert_not_contains_text "$output" 'test-api-key' 'desktop API check error does not print API key'
  assert_not_contains_text "$output" 'Bearer abcdefgh' 'desktop API check error redacts bearer token'
  assert_not_contains_text "$output" 'sk-abcdefgh' 'desktop API check error redacts sk token'

  rm -rf "$tmp"
}

test_desktop_setup_can_skip_api_check_from_env() {
  local tmp bin output
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_api_error_curl "$bin"

  if output="$(CODEX_KEY='test-api-key' VIBEMODE_SKIP_API_CHECK='1' HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" \
    bash "$DESKTOP_SCRIPT" --non-interactive --no-image-helper 2>&1)"; then
    pass 'desktop setup can skip API check from env'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop setup can skip API check from env'
    rm -rf "$tmp"
    return
  fi

  if [[ "$output" == *'Проверка /v1/models пропущена'* && "$output" != *'HTTP 401'* ]]; then
    pass 'desktop env skip avoids failing API check'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop env skip avoids failing API check'
  fi

  rm -rf "$tmp"
}

test_desktop_bootstrap_downloads_and_runs_setup() {
  local tmp bin output
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_bootstrap_curl "$bin"

  if ! output="$(HOME="$tmp/home" PATH="$bin:$PATH" bash "$DESKTOP_BOOTSTRAP" --skip-api-check 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail 'desktop short bootstrap exits successfully'
    rm -rf "$tmp"
    return
  fi
  pass 'desktop short bootstrap exits successfully'

  if [[ "$output" == 'downloaded setup ran [--skip-api-check]' ]]; then
    pass 'desktop short bootstrap runs downloaded setup with arguments'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop short bootstrap runs downloaded setup with arguments'
  fi

  rm -rf "$tmp"
}

test_desktop_powershell_static_checks() {
  local invalid_var_colon adjacent_vars
  assert_utf8_bom "$DESKTOP_PS" 'PowerShell setup is stored with UTF-8 BOM for Windows PowerShell 5'
  assert_ascii_file "$DESKTOP_BOOTSTRAP_PS" 'PowerShell bootstrap stays ASCII-only for pipe execution'
  assert_contains "$DESKTOP_PS" 'https://api.vibemod.pro/v1' 'PowerShell setup uses Vibemode base URL'
  assert_contains "$DESKTOP_PS" 'responses_image.py' 'PowerShell setup installs image helper script'
  assert_contains "$DESKTOP_PS" '[switch]$NoWsl' 'PowerShell setup can skip WSL setup'
  assert_contains "$DESKTOP_PS" '[string]$WslDistro' 'PowerShell setup can target a WSL distro'
  assert_contains "$DESKTOP_PS" '[switch]$ReplaceKey' 'PowerShell setup can replace an existing key'
  assert_contains "$DESKTOP_PS" '[switch]$KeyFromClipboard' 'PowerShell setup can read key from clipboard'
  assert_contains "$DESKTOP_PS" 'VIBEMODE_KEY_FROM_CLIPBOARD' 'PowerShell setup supports clipboard env flag'
  assert_contains "$DESKTOP_PS" 'VIBEMODE_SKIP_API_CHECK' 'PowerShell setup supports env API check skip'
  assert_contains "$DESKTOP_PS" 'vibemode key найден в переменной окружения' 'PowerShell setup asks before reusing env key interactively'
  assert_contains "$DESKTOP_PS" '$EnvKey = "CODEX_KEY"' 'PowerShell setup defaults to CODEX_KEY env key'
  assert_contains "$DESKTOP_PS" '$lines.Add("env_key = `"$escapedEnvKey`"")' 'PowerShell setup writes Vibemode env key'
  assert_contains "$DESKTOP_PS" '[profiles.default]' 'PowerShell setup writes default profile'
  assert_contains "$DESKTOP_PS" '$DefaultReasoningEffort = "medium"' 'PowerShell setup defaults profile reasoning effort to medium'
  assert_contains "$DESKTOP_PS" '$lines.Add("reasoning_effort = `"$escapedEffort`"")' 'PowerShell setup writes profile reasoning effort'
  assert_not_contains_file "$DESKTOP_PS" 'wire_api = "responses"' 'PowerShell setup does not write legacy wire_api'
  assert_not_contains_file "$DESKTOP_PS" '$lines.Add("model_reasoning_effort' 'PowerShell setup does not write legacy root reasoning key'
  assert_contains "$DESKTOP_PS" 'Get-Clipboard' 'PowerShell setup reads clipboard when requested'
  assert_contains "$DESKTOP_PS" '$DefaultImageHelperUrl' 'PowerShell setup has a default image helper URL'
  assert_contains "$DESKTOP_PS" 'Resolve-DownloadSource $ImageHelperSourceCandidate $DefaultImageHelperUrl "VIBEMODE_IMAGE_HELPER_URL"' 'PowerShell setup resolves image helper source before download'
  assert_contains "$DESKTOP_PS" 'Save-DownloadedTextFile $imageHelperSource $ImageHelperPath "image helper"' 'PowerShell setup downloads image helper through hardened downloader'
  assert_contains "$DESKTOP_PS" 'Ignoring invalid " + $Name + " value' 'PowerShell setup ignores invalid download source overrides'
  assert_contains "$DESKTOP_PS" '$Url + "?cb=" + $cacheBust' 'PowerShell setup appends cache-bust query by concatenation'
  assert_not_contains_file "$DESKTOP_PS" '$Url?cb=$cacheBust' 'PowerShell setup does not interpolate URL before ?cb'
  assert_contains "$DESKTOP_PS" 'DefaultNetworkCredentials' 'PowerShell setup supports default proxy credentials for downloads'
  assert_contains "$DESKTOP_PS" 'download looks like HTML, not a script' 'PowerShell setup rejects HTML helper downloads'
  assert_contains "$DESKTOP_PS" 'Enable-Tls12' 'PowerShell setup can enable TLS 1.2'
  assert_contains "$DESKTOP_PS" '[System.Net.SecurityProtocolType]::Tls12' 'PowerShell setup requests TLS 1.2 when available'
  assert_contains "$DESKTOP_PS" 'Invoke-RestMethod -Method Get' 'PowerShell setup still uses REST API for model check'
  assert_not_contains_file "$DESKTOP_PS" 'Invoke-WebRequest -UseBasicParsing -Uri $ImageHelperUrl -OutFile $ImageHelperPath' 'PowerShell setup does not use raw Invoke-WebRequest for image helper'
  assert_contains "$DESKTOP_PS" 'Read-MaskedInput "Вставь vibemode key"' 'PowerShell setup uses masked key input'
  assert_contains "$DESKTOP_PS" 'Confirm-FoundApiKey "Сохранённый vibemode key найден" $existingKey' 'PowerShell setup masks existing-key choice prompt'
  assert_not_contains_file "$DESKTOP_PS" 'Saved vibemode key found' 'PowerShell setup does not show English saved-key prompt'
  assert_not_contains_file "$DESKTOP_SCRIPT" 'Saved vibemode key found' 'Desktop bash setup does not show English saved-key prompt'
  assert_not_contains_file "$DESKTOP_SCRIPT" 'Paste vibemode key' 'Desktop bash setup does not show English key prompt'
  assert_contains "$DESKTOP_PS" 'Write-Host -NoNewline "*"' 'PowerShell setup prints one mask star per key character'
  assert_contains "$DESKTOP_PS" '[ConsoleKey]::Backspace' 'PowerShell masked key input supports backspace'
  assert_not_contains_file "$DESKTOP_PS" 'Read-Host -Prompt "Saved vibemode key found' 'PowerShell setup does not use visible input for existing-key prompt'
  assert_contains "$DESKTOP_PS" 'Get-Command wsl.exe' 'PowerShell setup detects WSL'
  assert_contains "$DESKTOP_PS" 'Install-WslConfig $apiKey' 'PowerShell setup configures WSL after Windows'
  assert_contains "$DESKTOP_PS" '$wslScript | & $wsl.Source @wslArgs 2>&1' 'PowerShell setup sends WSL script through stdin'
  assert_not_contains_file "$DESKTOP_PS" '@("--", "bash", "-s", $ApiKey)' 'PowerShell setup does not pass API key as WSL argument'
  assert_contains "$DESKTOP_PS" 'Format-ApiCheckError $_ $ApiKey' 'PowerShell setup reports API check details'
  assert_contains "$DESKTOP_PS" 'Warn (Format-ApiCheckError $_ $ApiKey)' 'PowerShell setup warns on API check failure'
  assert_not_contains_file "$DESKTOP_PS" 'Die (Format-ApiCheckError $_ $ApiKey)' 'PowerShell setup does not fail after writing config when API check fails'
  assert_contains "$DESKTOP_PS" 'Настройки записаны, но контрольный запрос к API не прошёл' 'PowerShell setup explains files stay written after API check failure'
  assert_contains "$DESKTOP_PS" 'VIBEMODE_REPLACE_KEY' 'PowerShell setup explains key replacement on API check failure'
  assert_contains "$DESKTOP_PS" 'VIBEMODE_SKIP_API_CHECK' 'PowerShell setup explains env API check skip on API check failure'
  assert_contains "$DESKTOP_PS" 'Bearer [redacted]' 'PowerShell setup redacts bearer tokens in errors'
  assert_not_contains_file "$DESKTOP_PS" '"sk-[A-Za-z0-9_*.-]{8,}"' 'PowerShell setup avoids PS5-sensitive regex quantifier in expandable string'
  assert_not_contains_file "$DESKTOP_PS" '"Bearer\s+[A-Za-z0-9._~+/=-]+"' 'PowerShell setup avoids regex pattern in expandable string'
  assert_not_contains_file "$DESKTOP_PS" '|| whoami' 'PowerShell setup avoids fragile shell fallback in embedded WSL script'
  assert_not_contains_file "$DESKTOP_PS" '$WslDistro$userLabel' 'PowerShell setup avoids adjacent variables in WSL log string'
  assert_not_contains_file "$DESKTOP_PS" 'Log "Пример helper для генерации картинок: python `"$ImageHelperPath`" --list-presets"' 'PowerShell setup avoids fragile escaped quotes in final helper log'
  assert_not_contains_file "$DESKTOP_PS" '{0}{1}' 'PowerShell setup avoids format placeholders in WSL log string'
  assert_not_contains_file "$DESKTOP_PS" '-f $WslDistro' 'PowerShell setup avoids format operator in WSL log string'
  assert_not_contains_file "$DESKTOP_PS" '-f $ImageHelperPath' 'PowerShell setup avoids format operator in final helper log'
  assert_contains "$DESKTOP_PS" '[char]34 + $ImageHelperPath + [char]34' 'PowerShell setup builds quoted helper example without escaped quotes or format placeholders'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'setup-vibemode-codex-desktop.ps1' 'PowerShell bootstrap points to desktop setup'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Add-CacheBust' 'PowerShell bootstrap cache-busts downloaded setup'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '.Contains("?")' 'PowerShell bootstrap detects existing query strings literally'
  assert_not_contains_file "$DESKTOP_BOOTSTRAP_PS" '-like "*?*"' 'PowerShell bootstrap does not use wildcard query detection'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '$Url + "?cb=" + $cacheBust' 'PowerShell bootstrap appends cache-bust query by concatenation'
  assert_not_contains_file "$DESKTOP_BOOTSTRAP_PS" '$Url?cb=$cacheBust' 'PowerShell bootstrap does not interpolate URL before ?cb'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Resolve-SetupSource $setupUrlCandidate $defaultSetupUrl' 'PowerShell bootstrap resolves setup source before download'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Ignoring invalid VIBEMODE_CODEX_DESKTOP_SETUP_URL value' 'PowerShell bootstrap ignores invalid setup URL overrides'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Vibemode setup source is neither an http(s) URL nor an existing file' 'PowerShell bootstrap rejects non-URL non-file setup sources'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Test-Path -LiteralPath $value -PathType Leaf' 'PowerShell bootstrap accepts existing local setup override files'
  assert_not_contains_file "$DESKTOP_BOOTSTRAP_PS" 'if (Test-Path -LiteralPath $Url) {' 'PowerShell bootstrap does not test URL as a local path before URL validation'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '[System.Net.SecurityProtocolType]::Tls12' 'PowerShell bootstrap enables TLS 1.2 when available'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Test-Path -LiteralPath $Url' 'PowerShell bootstrap supports local setup override paths'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'User-Agent' 'PowerShell bootstrap sends a stable user agent'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'DefaultNetworkCredentials' 'PowerShell bootstrap supports default proxy credentials'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '$webClient.DownloadData($downloadUrl)' 'PowerShell bootstrap downloads setup as bytes'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'New-Object System.Text.UTF8Encoding -ArgumentList $false, $true' 'PowerShell bootstrap strictly decodes setup as UTF-8'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '$strictUtf8.GetString($Bytes)' 'PowerShell bootstrap decodes setup as strict UTF-8'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'New-Object System.Text.UTF8Encoding -ArgumentList $true' 'PowerShell bootstrap writes temporary setup with UTF-8 BOM'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Downloaded Vibemode setup looks like HTML' 'PowerShell bootstrap rejects HTML error pages'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Test-SetupScriptSyntax $tmp' 'PowerShell bootstrap validates setup syntax before execution'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '[System.Management.Automation.PSParser]::Tokenize' 'PowerShell bootstrap uses parser preflight'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'Get-Command pwsh.exe' 'PowerShell bootstrap prefers PowerShell 7 when available'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '"PowerShell\" + $version + "\pwsh.exe"' 'PowerShell bootstrap checks Program Files PowerShell paths'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" 'ProgramW6432' 'PowerShell bootstrap checks 64-bit Program Files from 32-bit hosts'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '7-preview' 'PowerShell bootstrap can use PowerShell 7 preview if that is the only pwsh'
  assert_contains "$DESKTOP_BOOTSTRAP_PS" '-ExecutionPolicy Bypass -File $tmp' 'PowerShell bootstrap runs downloaded setup with execution policy bypass'
  assert_not_contains_file "$DESKTOP_BOOTSTRAP_PS" 'Invoke-WebRequest -UseBasicParsing -Uri $setupUrl -OutFile $tmp' 'PowerShell bootstrap does not save raw UTF-8 without BOM'
  assert_not_contains_file "$DESKTOP_BOOTSTRAP_PS" '& $tmp @args' 'PowerShell bootstrap does not execute downloaded ps1 directly'

  invalid_var_colon="$(grep -Pn '\$[A-Za-z_][A-Za-z0-9_]*:' "$DESKTOP_PS" | grep -Pv '\$(env|global|script|local|private|using|variable|function):' || true)"
  if [[ -z "$invalid_var_colon" ]]; then
    pass 'PowerShell setup has no unbraced variable before colon'
  else
    printf '%s\n' "$invalid_var_colon" >&2
    fail 'PowerShell setup has no unbraced variable before colon'
  fi

  adjacent_vars="$(grep -Pn '\$[A-Za-z_][A-Za-z0-9_]*\$[A-Za-z_][A-Za-z0-9_]*' "$DESKTOP_PS" || true)"
  if [[ -z "$adjacent_vars" ]]; then
    pass 'PowerShell setup has no adjacent expandable variables'
  else
    printf '%s\n' "$adjacent_vars" >&2
    fail 'PowerShell setup has no adjacent expandable variables'
  fi

  if command -v pwsh >/dev/null 2>&1; then
    if PS_TEST_PATH="$DESKTOP_PS" pwsh -NoProfile -Command '
      $path = $env:PS_TEST_PATH
      $errors = $null
      [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $path), [ref]$errors) | Out-Null
      if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
    '; then
      pass 'PowerShell setup parses with pwsh'
    else
      fail 'PowerShell setup parses with pwsh'
    fi
  else
    pass 'PowerShell parse check skipped without pwsh'
  fi
}

test_desktop_powershell_wsl_ready_failure_is_nonfatal() {
  local body
  body="$(sed -n '/^function Test-WslReady {$/,/^}$/p' "$DESKTOP_PS")"
  if [[ -z "$body" ]]; then
    fail 'PowerShell WSL readiness function exists'
    return
  fi
  pass 'PowerShell WSL readiness function exists'

  if [[ "$body" == *'try {'* && "$body" == *'catch {'* && "$body" == *'return $false'* ]]; then
    pass 'PowerShell WSL readiness handles wsl.exe errors as not ready'
  else
    printf '%s\n' "$body" >&2
    fail 'PowerShell WSL readiness handles wsl.exe errors as not ready'
  fi
}

test_desktop_powershell_wsl_embedded_script() {
  local tmp script provider_b64 base_url_b64 model_b64 effort_b64 auth_b64 helper_b64 output
  if ! command -v base64 >/dev/null 2>&1; then
    pass 'PowerShell WSL embedded script check skipped without base64'
    return
  fi

  script="$(sed -n "/^[[:space:]]*\\\$wslScript = @'$/,/^'@$/p" "$DESKTOP_PS" | sed '1d;$d')"
  if [[ -n "$script" ]]; then
    pass 'PowerShell WSL embedded script can be extracted'
  else
    fail 'PowerShell WSL embedded script can be extracted'
    return
  fi

  provider_b64="$(printf '%s' 'vibemode' | base64 | tr -d '\n')"
  base_url_b64="$(printf '%s' 'https://api.vibemod.pro/v1' | base64 | tr -d '\n')"
  model_b64="$(printf '%s' 'gpt-5.4' | base64 | tr -d '\n')"
  effort_b64="$(printf '%s' 'medium' | base64 | tr -d '\n')"
  auth_b64="$(printf '{\n  "auth_mode": "apikey",\n  "CODEX_KEY": "test-api-key"\n}\n' | base64 | tr -d '\n')"
  helper_b64="$(printf '#!/usr/bin/env python3\nprint("helper")\n' | base64 | tr -d '\n')"

  script="${script//__PROVIDER_B64__/$provider_b64}"
  script="${script//__BASE_URL_B64__/$base_url_b64}"
  script="${script//__MODEL_B64__/$model_b64}"
  script="${script//__EFFORT_B64__/$effort_b64}"
  script="${script//__AUTH_B64__/$auth_b64}"
  script="${script//__HELPER_B64__/$helper_b64}"

  tmp="$(mktemp -d)"
  if output="$(HOME="$tmp/home" bash -s <<< "$script" 2>&1)"; then
    pass 'PowerShell WSL embedded script runs under bash'
  else
    printf '%s\n' "$output" >&2
    fail 'PowerShell WSL embedded script runs under bash'
    rm -rf "$tmp"
    return
  fi

  assert_file "$tmp/home/.codex/config.toml" 'PowerShell WSL script creates config.toml'
  assert_file "$tmp/home/.codex/auth.json" 'PowerShell WSL script creates auth.json'
  assert_file "$tmp/home/.local/bin/responses-image" 'PowerShell WSL script installs image helper'
  if [[ -x "$tmp/home/.local/bin/responses-image" ]]; then
    pass 'PowerShell WSL image helper is executable'
  else
    fail 'PowerShell WSL image helper is executable'
  fi
  assert_contains "$tmp/home/.codex/config.toml" 'base_url = "https://api.vibemod.pro/v1"' 'PowerShell WSL script writes Vibemode base URL'
  assert_contains "$tmp/home/.codex/config.toml" 'env_key = "CODEX_KEY"' 'PowerShell WSL script writes Vibemode env key'
  assert_contains "$tmp/home/.codex/config.toml" '[profiles.default]' 'PowerShell WSL script writes default profile'
  assert_contains "$tmp/home/.codex/config.toml" 'reasoning_effort = "medium"' 'PowerShell WSL script writes profile reasoning effort'
  assert_not_contains_file "$tmp/home/.codex/config.toml" 'wire_api = "responses"' 'PowerShell WSL script does not write legacy wire_api'
  assert_contains "$tmp/home/.codex/auth.json" '"CODEX_KEY": "test-api-key"' 'PowerShell WSL script writes API key'
  if [[ "$output" == *"codex_dir=$tmp/home/.codex"* && "$output" == *"home=$tmp/home"* && "$output" == *'user='* ]]; then
    pass 'PowerShell WSL script reports user home and config dir'
  else
    printf '%s\n' "$output" >&2
    fail 'PowerShell WSL script reports user home and config dir'
  fi
  assert_not_contains_text "$output" 'test-api-key' 'PowerShell WSL script does not print API key'

  rm -rf "$tmp"
}

test_desktop_powershell_bootstrap_url_resolution() {
  local output
  if ! command -v pwsh >/dev/null 2>&1; then
    pass 'PowerShell bootstrap URL resolution check skipped without pwsh'
    return
  fi

  if output="$(PS_BOOTSTRAP_PATH="$DESKTOP_BOOTSTRAP_PS" pwsh -NoProfile -Command '
    $script = Get-Content -Raw $env:PS_BOOTSTRAP_PATH
    $marker = "try {`n    `$setupUrl = Resolve-SetupSource"
    $idx = $script.IndexOf($marker)
    if ($idx -lt 0) { throw "bootstrap execution marker not found" }
    Invoke-Expression $script.Substring(0, $idx)

    $default = "https://example.test/setup.ps1"
    $bad = Resolve-SetupSource "=85270456b1154ba39fb139bf7d8bcfdf" $default
    $remote = Resolve-SetupSource "https://example.test/setup.ps1" $default
    $noQuery = Add-CacheBust "https://example.test/setup.ps1"
    $withQuery = Add-CacheBust "https://example.test/setup.ps1?x=1"

    if ($bad -ne $default) { throw "bad override did not fall back: $bad" }
    if ($remote -ne "https://example.test/setup.ps1") { throw "remote URL changed: $remote" }
    if ($noQuery -notmatch "\?cb=") { throw "URL without query did not use ?cb=: $noQuery" }
    if ($noQuery -match "\.ps1&cb=") { throw "URL without query used &cb=: $noQuery" }
    if ($withQuery -notmatch "\?x=1&cb=") { throw "URL with query did not use &cb=: $withQuery" }
    "ok"
  ' 2>&1)"; then
    pass 'PowerShell bootstrap URL resolution handles invalid overrides and cache-busts'
  else
    printf '%s\n' "$output" >&2
    fail 'PowerShell bootstrap URL resolution handles invalid overrides and cache-busts'
  fi
}

test_desktop_powershell_setup_download_resolution() {
  local output
  if ! command -v pwsh >/dev/null 2>&1; then
    pass 'PowerShell setup download resolution check skipped without pwsh'
    return
  fi

  if output="$(PS_SETUP_PATH="$DESKTOP_PS" pwsh -NoProfile -Command '
    $script = Get-Content -Raw $env:PS_SETUP_PATH
    $marker = "`n`$apiKey = Read-ApiKey"
    $idx = $script.IndexOf($marker)
    if ($idx -lt 0) { throw "setup execution marker not found" }
    Invoke-Expression $script.Substring(0, $idx)

    $default = "https://example.test/helper.py"
    $bad = Resolve-DownloadSource "=85270456b1154ba39fb139bf7d8bcfdf" $default "VIBEMODE_IMAGE_HELPER_URL"
    $remote = Resolve-DownloadSource "https://example.test/helper.py" $default "VIBEMODE_IMAGE_HELPER_URL"
    $noQuery = Add-CacheBust "https://example.test/helper.py"
    $withQuery = Add-CacheBust "https://example.test/helper.py?x=1"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      $local = Resolve-DownloadSource $tmp $default "VIBEMODE_IMAGE_HELPER_URL"
      if ($local -ne (Resolve-Path -LiteralPath $tmp).Path) { throw "local override changed: $local" }
    } finally {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    if ($bad -ne $default) { throw "bad helper override did not fall back: $bad" }
    if ($remote -ne "https://example.test/helper.py") { throw "remote helper URL changed: $remote" }
    if ($noQuery -notmatch "\?cb=") { throw "helper URL without query did not use ?cb=: $noQuery" }
    if ($noQuery -match "\.py&cb=") { throw "helper URL without query used &cb=: $noQuery" }
    if ($withQuery -notmatch "\?x=1&cb=") { throw "helper URL with query did not use &cb=: $withQuery" }
    "ok"
  ' 2>&1)"; then
    pass 'PowerShell setup download resolution handles invalid overrides and cache-busts'
  else
    printf '%s\n' "$output" >&2
    fail 'PowerShell setup download resolution handles invalid overrides and cache-busts'
  fi
}

test_pipe_safe_prompt_static_checks() {
  assert_contains "$SCRIPT" 'read_secret()' 'Termux setup has hidden prompt helper'
  assert_contains "$SCRIPT" '</dev/tty' 'Termux setup reads prompts from terminal'
  assert_contains "$DESKTOP_SCRIPT" 'read_secret()' 'Desktop setup has hidden prompt helper'
  assert_contains "$DESKTOP_SCRIPT" '</dev/tty' 'Desktop setup reads prompts from terminal'
  assert_contains "$ROOT_DIR/README.md" 'Короткие `curl ... | bash` команды тоже умеют спрашивать ключ' 'README documents pipe-safe key prompt'
}

test_desktop_interactive_prompt_reads_from_tty() {
  local tmp output
  if ! command -v script >/dev/null 2>&1; then
    pass 'desktop tty prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  if output="$(printf 'tty-test-key\n' | env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/codex" \
    script -qfec "bash \"$DESKTOP_SCRIPT\" --skip-api-check --no-image-helper" /dev/null 2>&1)"; then
    pass 'desktop interactive prompt reads key from tty'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop interactive prompt reads key from tty'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$tmp/codex/auth.json" '"CODEX_KEY": "tty-test-key"' 'desktop tty prompt writes API key'
  if [[ "$output" == *'************'* ]]; then
    pass 'desktop tty prompt prints one mask star per key character'
  else
    printf '%s\n' "$output" >&2
    fail 'desktop tty prompt prints one mask star per key character'
  fi
  rm -rf "$tmp"
}

test_image_helper_static_checks() {
  local output
  if ! command -v python3 >/dev/null 2>&1; then
    pass 'image helper checks skipped without python3'
    return
  fi

  if python3 -m py_compile "$ROOT_DIR/scripts/responses_image.py"; then
    pass 'image helper compiles'
  else
    fail 'image helper compiles'
  fi

  if output="$(python3 "$ROOT_DIR/scripts/responses_image.py" --list-presets 2>&1)" \
    && [[ "$output" == *$'wide\t1536x1024'* ]]; then
    pass 'image helper CLI lists presets without API key'
  else
    printf '%s\n' "$output" >&2
    fail 'image helper CLI lists presets without API key'
  fi
}

test_image_helper_reads_selected_codex_provider() {
  local tmp codex output
  if ! command -v python3 >/dev/null 2>&1; then
    pass 'image helper Codex config check skipped without python3'
    return
  fi
  if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    pass 'image helper Codex config check skipped without tomllib'
    return
  fi

  tmp="$(mktemp -d)"
  codex="$tmp/home/.codex"
  mkdir -p "$codex"
  cat > "$codex/auth.json" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "existing-test-api-key"
}
JSON
  cat > "$codex/config.toml" <<'TOML'
model = "wrong-root"
model_provider = "Wrong Provider"

[model_providers."Wrong Provider"]
base_url = "https://wrong.example/v1"

[profiles.default]
model = "gpt-5.4"
model_provider = "vibemode"
reasoning_effort = "medium"

[model_providers.vibemode]
base_url = "https://api.vibemod.pro/v1"
env_key = "CODEX_KEY"
TOML

  if output="$(env -u CODEX_KEY CODEX_HOME="$codex" python3 - "$ROOT_DIR/scripts/responses_image.py" <<'PY' 2>&1
import importlib.util
import sys

script_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("responses_image", script_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
config = module.resolve_config()
assert config.api_key == "existing-test-api-key"
assert config.base_url == "https://api.vibemod.pro/v1"
assert config.model == "gpt-5.4"
tool = module.build_tool(module.ImageJob(prompt="p", output="out.png", compression="80"))
assert tool["output_compression"] == 80
try:
    module.build_tool(module.ImageJob(prompt="p", output="out.png", compression="bad"))
except module.ImageGenerationError:
    pass
else:
    raise AssertionError("bad compression should fail")
print("config-ok")
PY
)"; then
    pass 'image helper reads selected Codex provider'
  else
    printf '%s\n' "$output" >&2
    fail 'image helper reads selected Codex provider'
  fi

  assert_not_contains_text "$output" 'existing-test-api-key' 'image helper config check does not print API key'
  rm -rf "$tmp"
}

test_requires_key_when_non_interactive() {
  local tmp bin output status
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_curl "$bin"

  set +e
  output="$(env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" bash "$SCRIPT" --non-interactive 2>&1)"
  status="$?"
  set -e

  if [[ "$status" != '0' ]]; then
    pass 'non-interactive mode fails without API key'
  else
    fail 'non-interactive mode fails without API key'
  fi

  if [[ "$output" == *'API-ключ не найден'* ]]; then
    pass 'explains missing API key'
  else
    printf '%s\n' "$output" >&2
    fail 'explains missing API key'
  fi

  rm -rf "$tmp"
}

test_termux_setup_can_replace_existing_auth_key() {
  local tmp auth output bin
  if ! command -v script >/dev/null 2>&1; then
    pass 'Termux replace key prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  auth="$tmp/home/.codex/auth.json"
  mkdir -p "$bin" "$(dirname "$auth")"
  make_fake_curl "$bin"
  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "old-test-api-key"
}
JSON

  if output="$(printf 'new-test-api-key\n' | env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" \
    script -qfec "bash \"$SCRIPT\" --model gpt-5 --replace-key" /dev/null 2>&1)"; then
    pass 'Termux setup can replace existing auth.json key'
  else
    printf '%s\n' "$output" >&2
    fail 'Termux setup can replace existing auth.json key'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$auth" '"CODEX_KEY": "new-test-api-key"' 'Termux setup writes replacement API key'
  if [[ "$output" == *'****************'* ]]; then
    pass 'Termux replacement prompt prints one mask star per new key character'
  else
    printf '%s\n' "$output" >&2
    fail 'Termux replacement prompt prints one mask star per new key character'
  fi

  rm -rf "$tmp"
}

test_termux_setup_masks_direct_key_paste_over_existing_auth() {
  local tmp auth output bin
  if ! command -v script >/dev/null 2>&1; then
    pass 'Termux direct key paste prompt check skipped without script command'
    return
  fi

  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  auth="$tmp/home/.codex/auth.json"
  mkdir -p "$bin" "$(dirname "$auth")"
  make_fake_curl "$bin"
  cat > "$auth" <<'JSON'
{
  "auth_mode": "apikey",
  "CODEX_KEY": "old-test-api-key"
}
JSON

  if output="$(printf 'direct-test-api-key\n' | env -u CODEX_KEY HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" \
    script -qfec "bash \"$SCRIPT\" --model gpt-5" /dev/null 2>&1)"; then
    pass 'Termux setup accepts direct masked key paste over existing auth'
  else
    printf '%s\n' "$output" >&2
    fail 'Termux setup accepts direct masked key paste over existing auth'
    rm -rf "$tmp"
    return
  fi

  assert_contains "$auth" '"CODEX_KEY": "direct-test-api-key"' 'Termux direct paste writes replacement API key'
  if [[ "$output" == *'*******************'* ]]; then
    pass 'Termux direct paste prints one mask star per key character'
  else
    printf '%s\n' "$output" >&2
    fail 'Termux direct paste prints one mask star per key character'
  fi

  rm -rf "$tmp"
}

test_termux_api_check_reports_safe_details() {
  local tmp bin output status
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_api_error_curl "$bin"

  set +e
  output="$(CODEX_KEY='test-api-key' HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" PATH="$bin:$PATH" \
    bash "$SCRIPT" --non-interactive 2>&1)"
  status="$?"
  set -e

  if [[ "$status" != '0' ]]; then
    pass 'Termux setup fails when API check returns 401'
  else
    fail 'Termux setup fails when API check returns 401'
  fi

  assert_file "$tmp/home/.codex/config.toml" 'Termux setup writes config before failed API check'
  assert_file "$tmp/home/.codex/auth.json" 'Termux setup writes auth before failed API check'

  if [[ "$output" == *'HTTP 401'* && "$output" == *'Настройки записаны'* ]]; then
    pass 'Termux setup reports safe API check details'
  else
    printf '%s\n' "$output" >&2
    fail 'Termux setup reports safe API check details'
  fi
  assert_not_contains_text "$output" 'test-api-key' 'Termux API check error does not print API key'
  assert_not_contains_text "$output" 'Bearer abcdefgh' 'Termux API check error redacts bearer token'
  assert_not_contains_text "$output" 'sk-abcdefgh' 'Termux API check error redacts sk token'

  rm -rf "$tmp"
}

test_bootstrap_downloads_and_runs_setup() {
  local tmp bin output
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  make_fake_bootstrap_curl "$bin"

  if ! output="$(HOME="$tmp/home" PATH="$bin:$PATH" bash "$BOOTSTRAP" --model gpt-5 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail 'short bootstrap exits successfully'
    rm -rf "$tmp"
    return
  fi
  pass 'short bootstrap exits successfully'

  if [[ "$output" == 'downloaded setup ran [--model] [gpt-5]' ]]; then
    pass 'short bootstrap runs downloaded setup with arguments'
  else
    printf '%s\n' "$output" >&2
    fail 'short bootstrap runs downloaded setup with arguments'
  fi

  rm -rf "$tmp"
}

test_creates_files_and_reports_models
test_repairs_config_idempotently
test_reuses_existing_auth_key_non_interactive
test_desktop_setup_creates_config_and_image_helper
test_desktop_setup_reuses_existing_auth_key
test_desktop_setup_can_replace_existing_auth_key
test_desktop_setup_can_replace_env_key_interactively
test_desktop_setup_masks_direct_key_paste_over_existing_auth
test_desktop_api_check_reports_safe_details
test_desktop_setup_can_skip_api_check_from_env
test_desktop_bootstrap_downloads_and_runs_setup
test_desktop_powershell_static_checks
test_desktop_powershell_wsl_ready_failure_is_nonfatal
test_desktop_powershell_wsl_embedded_script
test_desktop_powershell_bootstrap_url_resolution
test_desktop_powershell_setup_download_resolution
test_pipe_safe_prompt_static_checks
test_npm_cli_package_metadata
test_npm_cli_setup_status_openai_and_run
test_desktop_interactive_prompt_reads_from_tty
test_requires_key_when_non_interactive
test_termux_setup_can_replace_existing_auth_key
test_termux_setup_masks_direct_key_paste_over_existing_auth
test_termux_api_check_reports_safe_details
test_bootstrap_downloads_and_runs_setup
test_image_helper_static_checks
test_image_helper_reads_selected_codex_provider

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
  exit 1
fi

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
