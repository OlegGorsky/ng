param(
    [switch]$NonInteractive,
    [string]$Model = "gpt-5.5",
    [switch]$SkipApiCheck,
    [switch]$NoImageHelper,
    [switch]$NoWsl,
    [switch]$ReplaceKey,
    [switch]$KeyFromClipboard,
    [string]$WslDistro,
    [string]$ImageHelperPath
)

$ErrorActionPreference = "Stop"

$ProviderName = "NeuroGate API"
$BaseUrl = "https://api.neurogate.space/v1"
$DefaultReasoningEffort = "medium"
$DefaultImageHelperUrl = "https://raw.githubusercontent.com/OlegGorsky/neurogate-codex-termux/main/scripts/responses_image.py"
$ImageHelperSourceCandidate = if ($env:NEUROGATE_IMAGE_HELPER_URL) {
    $env:NEUROGATE_IMAGE_HELPER_URL
} else {
    $DefaultImageHelperUrl
}

$CodexDir = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path $HOME ".codex"
}
$ConfigFile = Join-Path $CodexDir "config.toml"
$AuthFile = Join-Path $CodexDir "auth.json"
if (-not $ImageHelperPath) {
    $ImageHelperPath = Join-Path (Join-Path $HOME ".local\bin") "responses-image.py"
}

function Log([string]$Message) {
    Write-Host $Message
}

function Warn([string]$Message) {
    Write-Warning $Message
}

function Die([string]$Message) {
    Write-Error $Message
    exit 1
}

function JsonEscape([string]$Value) {
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", "").Replace("`n", "")
}

function TomlEscape([string]$Value) {
    return JsonEscape $Value
}

function Write-TextNoBom([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function To-Base64([string]$Text) {
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-EnvFlag([string]$Value) {
    if (-not $Value) {
        return $false
    }
    return $Value -match '^(1|true|yes|y|on|да|д)$'
}

function Test-HttpUrl([string]$Value) {
    return ($Value -match '^https?://')
}

function Add-CacheBust([string]$Url) {
    if (-not (Test-HttpUrl $Url)) {
        return $Url
    }

    $cacheBust = [System.Guid]::NewGuid().ToString("N")
    if ($Url.Contains("?")) {
        return ($Url + "&cb=" + $cacheBust)
    }
    return ($Url + "?cb=" + $cacheBust)
}

function Resolve-DownloadSource([string]$Candidate, [string]$DefaultUrl, [string]$Name) {
    $value = if ($Candidate) { $Candidate.Trim() } else { "" }
    if ($value -and (Test-HttpUrl $value)) {
        return $value
    }
    if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $value).Path
    }
    if ($value -and $value -ne $DefaultUrl) {
        Warn ("Ignoring invalid " + $Name + " value: " + $value)
    }
    return $DefaultUrl
}

function Enable-Tls12 {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

function Get-DownloadBytes([string]$Source, [string]$Label) {
    if (-not $Source) {
        Die ($Label + " source is empty.")
    }

    if (-not (Test-HttpUrl $Source)) {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            Die ($Label + " source is neither an http(s) URL nor an existing file: " + $Source)
        }
        return [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source).Path)
    }

    $downloadUrl = Add-CacheBust $Source
    Enable-Tls12
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "neurogate-codex-desktop-setup")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        return $webClient.DownloadData($downloadUrl)
    } catch {
        Die ("Could not download " + $Label + " from " + $downloadUrl + ": " + $_.Exception.Message)
    } finally {
        $webClient.Dispose()
    }
}

function ConvertFrom-Utf8Bytes([byte[]]$Bytes, [string]$Label) {
    if (-not $Bytes -or $Bytes.Length -eq 0) {
        Die ($Label + " download is empty.")
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    try {
        $text = $strictUtf8.GetString($Bytes)
    } catch {
        Die ($Label + " download is not valid UTF-8: " + $_.Exception.Message)
    }

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    if ($text.TrimStart() -match '^(?i)<(!doctype|html)') {
        Die ($Label + " download looks like HTML, not a script.")
    }

    return $text
}

function Save-DownloadedTextFile([string]$Source, [string]$Target, [string]$Label) {
    $bytes = Get-DownloadBytes $Source $Label
    $text = ConvertFrom-Utf8Bytes $bytes $Label
    Write-TextNoBom $Target $text
}

function Read-ClipboardApiKey {
    try {
        $value = (Get-Clipboard -ErrorAction Stop) -join [Environment]::NewLine
    } catch {
        Die "Не удалось прочитать API-ключ из буфера обмена."
    }

    if (-not $value -or -not $value.Trim()) {
        Die "В буфере обмена нет API-ключа."
    }

    return $value.Trim()
}

function Read-SecureStringPlain([string]$Prompt) {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Read-MaskedInput([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        return Read-SecureStringPlain $Prompt
    }

    Write-Host -NoNewline "${Prompt}: "
    $builder = New-Object System.Text.StringBuilder
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                break
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($builder.Length -gt 0) {
                    [void]$builder.Remove($builder.Length - 1, 1)
                    Write-Host -NoNewline "`b `b"
                }
                continue
            }
            if ([char]::IsControl($key.KeyChar)) {
                continue
            }

            [void]$builder.Append($key.KeyChar)
            Write-Host -NoNewline "*"
        }
    } catch {
        Write-Host ""
        return Read-SecureStringPlain $Prompt
    }

    return $builder.ToString()
}

function Read-NewApiKey {
    if ($KeyFromClipboard -or (Test-EnvFlag $env:NEUROGATE_KEY_FROM_CLIPBOARD)) {
        Log "Читаю NeuroGate API key из буфера обмена"
        return Read-ClipboardApiKey
    }

    $plain = Read-MaskedInput "Вставь NeuroGate API key"
    if (-not $plain -or -not $plain.Trim()) {
        Die "API-ключ не найден."
    }
    return $plain.Trim()
}

function Read-ExistingApiKey {
    if (-not (Test-Path -LiteralPath $AuthFile)) {
        return $null
    }

    try {
        $payload = Get-Content -LiteralPath $AuthFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }

    foreach ($name in @("OPENAI_API_KEY", "openai_api_key", "api_key")) {
        $property = $payload.PSObject.Properties[$name]
        if ($property -and $property.Value -is [string] -and $property.Value.Trim()) {
            return $property.Value.Trim()
        }
    }

    return $null
}

function Read-ApiKey {
    $apiKey = if ($env:NEUROGATE_API_KEY) { $env:NEUROGATE_API_KEY } else { $env:OPENAI_API_KEY }
    if ($apiKey -and $apiKey.Trim()) {
        return $apiKey.Trim()
    }

    $replaceExisting = $ReplaceKey -or (Test-EnvFlag $env:NEUROGATE_REPLACE_KEY)
    $existingKey = Read-ExistingApiKey
    if ($existingKey -and -not $replaceExisting) {
        if (-not $NonInteractive) {
            $answer = Read-MaskedInput "Сохранённый NeuroGate API key найден. Enter = оставить, r = заменить, или вставь новый ключ"
            $answer = $answer.Trim()
            if (-not $answer) {
                return $existingKey
            }
            if ($answer -match '^(r|replace|new|n|н|з|заменить)$') {
                return Read-NewApiKey
            }
            return $answer
        }
        return $existingKey
    }

    if ($NonInteractive) {
        if ($replaceExisting) {
            Die "Запрошена замена API-ключа. Передай NEUROGATE_API_KEY или запусти скрипт интерактивно."
        }
        Die "API-ключ не найден. Передай NEUROGATE_API_KEY или один раз запусти скрипт интерактивно."
    }

    return Read-NewApiKey
}

function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Log "Бэкап: $backup"
}

function Set-PrivateFilePermissions([string]$Path) {
    if ($IsWindows -eq $false -and $PSVersionTable.PSEdition -eq "Core") {
        return
    }

    $icacls = Get-Command icacls.exe -ErrorAction SilentlyContinue
    if (-not $icacls) {
        return
    }

    try {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & $icacls.Source $Path /inheritance:r /grant:r "${user}:F" | Out-Null
    } catch {
        Warn "Не удалось выставить приватные ACL для $Path"
    }
}

function Write-IfChanged([string]$Target, [string]$Body, [int]$Mode = 600) {
    $tmp = [System.IO.Path]::GetTempFileName()
    Write-TextNoBom $tmp $Body

    $same = $false
    if (Test-Path -LiteralPath $Target) {
        $same = ((Get-Content -LiteralPath $Target -Raw) -eq (Get-Content -LiteralPath $tmp -Raw))
    }

    if ($same) {
        Remove-Item -LiteralPath $tmp -Force
    } else {
        Backup-File $Target
        Move-Item -LiteralPath $tmp -Destination $Target -Force
    }

    if ($Target -eq $AuthFile) {
        Set-PrivateFilePermissions $Target
    }
}

function Build-ConfigBody {
    $escapedModel = TomlEscape $Model
    $escapedProvider = TomlEscape $ProviderName
    $escapedUrl = TomlEscape $BaseUrl
    $escapedEffort = TomlEscape $DefaultReasoningEffort
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("model = `"$escapedModel`"")
    $lines.Add("model_provider = `"$escapedProvider`"")
    $lines.Add("model_reasoning_effort = `"$escapedEffort`"")
    $lines.Add("")

    if (Test-Path -LiteralPath $ConfigFile) {
        $inRoot = $true
        $skipProvider = $false
        $providerHeader = "[model_providers.`"$ProviderName`"]"

        foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[') {
                $inRoot = $false
                if ($trimmed -eq $providerHeader) {
                    $skipProvider = $true
                    continue
                }
                $skipProvider = $false
            }

            if ($skipProvider) {
                continue
            }
            if ($inRoot -and $line -match '^\s*model\s*=') {
                continue
            }
            if ($inRoot -and $line -match '^\s*model_provider\s*=') {
                continue
            }
            if ($inRoot -and $line -match '^\s*model_reasoning_effort\s*=') {
                continue
            }

            $lines.Add($line)
        }
        $lines.Add("")
    }

    $lines.Add("")
    $lines.Add("[model_providers.`"$escapedProvider`"]")
    $lines.Add("name = `"$escapedProvider`"")
    $lines.Add("base_url = `"$escapedUrl`"")
    $lines.Add('wire_api = "responses"')

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-Config {
    New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
    Write-IfChanged $ConfigFile (Build-ConfigBody)
}

function Write-Auth([string]$ApiKey) {
    New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
    Write-IfChanged $AuthFile (Build-AuthBody $ApiKey)
}

function Build-AuthBody([string]$ApiKey) {
    $escapedKey = JsonEscape $ApiKey
    return "{`n  `"auth_mode`": `"apikey`",`n  `"OPENAI_API_KEY`": `"$escapedKey`"`n}`n"
}

function Sanitize-Secret([string]$Text, [string]$ApiKey) {
    if (-not $Text) {
        return ""
    }

    $clean = $Text
    if ($ApiKey) {
        $clean = [regex]::Replace($clean, [regex]::Escape($ApiKey), '[redacted]')
    }
    $clean = [regex]::Replace($clean, 'Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $clean = [regex]::Replace($clean, 'sk-[A-Za-z0-9_*.-]{8,}', 'sk-[redacted]')
    return $clean
}

function Read-ErrorResponseBody($Response) {
    if (-not $Response) {
        return ""
    }

    try {
        $stream = $Response.GetResponseStream()
        if (-not $stream) {
            return ""
        }
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } catch {
        return ""
    }
}

function Format-ApiCheckError($ErrorRecord, [string]$ApiKey) {
    $details = New-Object System.Collections.Generic.List[string]
    $response = $ErrorRecord.Exception.Response

    if ($response) {
        try {
            $status = [int]$response.StatusCode
            $statusDescription = [string]$response.StatusDescription
            if ($statusDescription) {
                $details.Add("HTTP $status $statusDescription")
            } else {
                $details.Add("HTTP $status")
            }
        } catch {
        }
    }

    $body = ""
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = [string]$ErrorRecord.ErrorDetails.Message
    }
    if (-not $body) {
        $body = Read-ErrorResponseBody $response
    }
    if ($body) {
        $body = Sanitize-Secret $body $ApiKey
        if ($body.Length -gt 500) {
            $body = $body.Substring(0, 500) + "..."
        }
        $details.Add($body)
    }

    if (-not $details.Count) {
        $message = Sanitize-Secret $ErrorRecord.Exception.Message $ApiKey
        if ($message) {
            $details.Add($message)
        }
    }

    $suffix = if ($details.Count) { " Details: $($details -join ' | ')" } else { "" }
    return "Не удалось проверить /v1/models. Настройки записаны, но контрольный запрос к API не прошёл.$suffix"
}

function Check-Models([string]$ApiKey) {
    try {
        Enable-Tls12
        $response = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 60
    } catch {
        Die (Format-ApiCheckError $_ $ApiKey)
    }

    $models = @()
    if ($response.data) {
        foreach ($item in $response.data) {
            if ($item.id) {
                $models += [string]$item.id
            }
        }
    }

    if (-not $models.Count) {
        Die "API ответил, но список моделей не удалось прочитать."
    }

    return $models | Select-Object -Unique
}

function Install-ImageHelper {
    if ($NoImageHelper) {
        return
    }

    $helperDir = Split-Path -Parent $ImageHelperPath
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $imageHelperSource = Resolve-DownloadSource $ImageHelperSourceCandidate $DefaultImageHelperUrl "NEUROGATE_IMAGE_HELPER_URL"
    Save-DownloadedTextFile $imageHelperSource $ImageHelperPath "image helper"

    $cmdPath = Join-Path $helperDir "responses-image.cmd"
    $helperName = Split-Path -Leaf $ImageHelperPath
    $cmdBody = "@echo off`r`npython `"%~dp0$helperName`" %*`r`n"
    Write-TextNoBom $cmdPath $cmdBody
    Log "Helper для картинок: $ImageHelperPath"
    Log "Wrapper helper для картинок: $cmdPath"
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Warn "python не найден в PATH. Установи Python перед использованием responses-image."
    }
}

function Get-WslCommand {
    return Get-Command wsl.exe -ErrorAction SilentlyContinue
}

function Get-WslBaseArgs {
    $wslArgs = @()
    if ($WslDistro) {
        $wslArgs += @("--distribution", $WslDistro)
    }
    return $wslArgs
}

function Test-WslReady {
    $wsl = Get-WslCommand
    if (-not $wsl) {
        return $false
    }

    $wslArgs = @(Get-WslBaseArgs) + @("--", "sh", "-lc", "printf ready")
    $output = & $wsl.Source @wslArgs 2>$null
    return ($LASTEXITCODE -eq 0 -and ($output -join "") -eq "ready")
}

function Install-WslConfig([string]$ApiKey) {
    if ($NoWsl) {
        Log "Настройка WSL пропущена"
        return
    }

    $wsl = Get-WslCommand
    if (-not $wsl) {
        Log "WSL не найден, настройка WSL пропущена"
        return
    }

    if (-not (Test-WslReady)) {
        if ($WslDistro) {
            Warn "WSL-дистрибутив '$WslDistro' не готов, настройка WSL пропущена"
        } else {
            Warn "WSL установлен, но default distro не готов, настройка WSL пропущена"
        }
        return
    }

    $helperB64 = ""
    if (-not $NoImageHelper -and (Test-Path -LiteralPath $ImageHelperPath)) {
        $helperB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImageHelperPath))
    }

    $providerB64 = To-Base64 $ProviderName
    $baseUrlB64 = To-Base64 $BaseUrl
    $modelB64 = To-Base64 $Model
    $effortB64 = To-Base64 $DefaultReasoningEffort
    $authB64 = To-Base64 (Build-AuthBody $ApiKey)

    $wslScript = @'
set -euo pipefail

decode() {
  printf '%s' "$1" | base64 -d
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

provider="$(decode '__PROVIDER_B64__')"
base_url="$(decode '__BASE_URL_B64__')"
model="$(decode '__MODEL_B64__')"
reasoning_effort="$(decode '__EFFORT_B64__')"
auth_body_b64='__AUTH_B64__'
helper_body_b64='__HELPER_B64__'

codex_dir="$HOME/.codex"
config_file="$codex_dir/config.toml"
auth_file="$codex_dir/auth.json"
mkdir -p "$codex_dir"
chmod 700 "$codex_dir"

backup_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$path.bak-$stamp"
  cp "$path" "$backup"
  if chmod 600 "$backup" 2>/dev/null; then
    :
  fi
}

write_if_changed() {
  local target="$1"
  local body_b64="$2"
  local tmp
  tmp="$(mktemp "$codex_dir/$(basename "$target").tmp.XXXXXX")"
  printf '%s' "$body_b64" | base64 -d > "$tmp"
  if [[ -f "$target" ]] && cmp -s "$target" "$tmp"; then
    rm -f "$tmp"
  else
    backup_file "$target"
    mv "$tmp" "$target"
  fi
  chmod 600 "$target"
}

build_config_body() {
  local escaped_model escaped_provider escaped_url escaped_effort
  escaped_model="$(toml_escape "$model")"
  escaped_provider="$(toml_escape "$provider")"
  escaped_url="$(toml_escape "$base_url")"
  escaped_effort="$(toml_escape "$reasoning_effort")"

  printf 'model = "%s"\n' "$escaped_model"
  printf 'model_provider = "%s"\n' "$escaped_provider"
  printf 'model_reasoning_effort = "%s"\n' "$escaped_effort"
  printf '\n'

  if [[ -f "$config_file" ]]; then
    awk -v provider="$provider" '
      BEGIN {
        in_root = 1
        skip_provider = 0
        provider_header = "[model_providers.\"" provider "\"]"
      }
      /^[[:space:]]*\[/ {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        in_root = 0
        if (line == provider_header) {
          skip_provider = 1
          next
        }
        skip_provider = 0
      }
      skip_provider { next }
      in_root && /^[[:space:]]*model[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_reasoning_effort[[:space:]]*=/ { next }
      { print }
    ' "$config_file"
    printf '\n'
  fi

  printf '\n[model_providers."%s"]\n' "$escaped_provider"
  printf 'name = "%s"\n' "$escaped_provider"
  printf 'base_url = "%s"\n' "$escaped_url"
  printf 'wire_api = "responses"\n'
}

config_b64="$(build_config_body | base64 | tr -d '\n')"
write_if_changed "$config_file" "$config_b64"
write_if_changed "$auth_file" "$auth_body_b64"

if [[ -n "$helper_body_b64" ]]; then
  mkdir -p "$HOME/.local/bin"
  printf '%s' "$helper_body_b64" | base64 -d > "$HOME/.local/bin/responses-image"
  chmod +x "$HOME/.local/bin/responses-image"
fi

printf 'codex_dir=%s\n' "$HOME/.codex"
wsl_user=""
if command -v id >/dev/null 2>&1; then
  if wsl_user="$(id -un 2>/dev/null)"; then
    :
  else
    wsl_user=""
  fi
fi
if [[ -z "$wsl_user" ]]; then
  wsl_user="$(whoami)"
fi
printf 'user=%s\n' "$wsl_user"
printf 'home=%s\n' "$HOME"
'@

    $wslScript = $wslScript.Replace('__PROVIDER_B64__', $providerB64)
    $wslScript = $wslScript.Replace('__BASE_URL_B64__', $baseUrlB64)
    $wslScript = $wslScript.Replace('__MODEL_B64__', $modelB64)
    $wslScript = $wslScript.Replace('__EFFORT_B64__', $effortB64)
    $wslScript = $wslScript.Replace('__AUTH_B64__', $authB64)
    $wslScript = $wslScript.Replace('__HELPER_B64__', $helperB64)

    $wslArgs = @(Get-WslBaseArgs) + @("--", "bash", "-s")
    $output = $wslScript | & $wsl.Source @wslArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $target = ""
        $wslUser = ""
        $wslHome = ""
        foreach ($line in $output) {
            if ($line -match '^codex_dir=(.*)$') {
                $target = $Matches[1]
            } elseif ($line -match '^user=(.*)$') {
                $wslUser = $Matches[1]
            } elseif ($line -match '^home=(.*)$') {
                $wslHome = $Matches[1]
            }
        }
        if (-not $target) {
            $target = ($output | Select-Object -Last 1)
        }

        $userLabel = if ($wslUser) { ", user $wslUser" } else { "" }
        if ($WslDistro) {
            Log ("Папка Codex в WSL (" + $WslDistro + $userLabel + "): " + $target)
        } else {
            Log ("Папка Codex в WSL" + $userLabel + ": " + $target)
        }
        if ($wslHome) {
            Log "WSL HOME: $wslHome"
        }
        if ($helperB64) {
            Log "Helper картинок в WSL: ~/.local/bin/responses-image"
        }
    } else {
        Warn "Настройка WSL не удалась: $($output -join ' ')"
    }
}

$apiKey = Read-ApiKey

Log "Папка Codex Desktop: $CodexDir"
Write-Config
Write-Auth $apiKey
Install-ImageHelper
Install-WslConfig $apiKey

if ($SkipApiCheck) {
    Log "Проверка /v1/models пропущена"
} else {
    Log "Проверяю NeuroGate API через /v1/models..."
    $models = Check-Models $apiKey
    Log ""
    Log "API готов"
    Log "Доступные модели:"
    foreach ($item in $models) {
        Log " - $item"
    }
}

Log ""
Log "Перезапусти Codex Desktop, чтобы он перечитал provider config."
Log ("Пример helper для генерации картинок: python " + [char]34 + $ImageHelperPath + [char]34 + " --list-presets")
