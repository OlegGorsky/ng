param(
    [switch]$NonInteractive,
    [string]$Model = "gpt-5.4",
    [switch]$SkipApiCheck,
    [switch]$NoImageHelper,
    [switch]$NoWsl,
    [switch]$ReplaceKey,
    [switch]$KeyFromClipboard,
    [string]$WslDistro,
    [string]$ImageHelperPath
)

$ErrorActionPreference = "Stop"

$ProviderName = "vibemode"
$BaseUrl = "https://api.vibemod.pro/v1"
$DefaultReasoningEffort = "medium"
$EnvKey = "CODEX_KEY"
$OpenAiEnvKey = "OPENAI_API_KEY"
$CodexApiEnvKey = "CODEX_API_KEY"
$DefaultCodexDir = Join-Path $HOME ".codex"
$UserCodexHome = [Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
$DefaultImageHelperUrl = "https://raw.githubusercontent.com/OlegGorsky/ng/main/scripts/responses_image.py"
$ImageHelperSourceCandidate = if ($env:VIBEMODE_IMAGE_HELPER_URL) {
    $env:VIBEMODE_IMAGE_HELPER_URL
} else {
    $DefaultImageHelperUrl
}

$CodexDir = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} elseif ($UserCodexHome) {
    $UserCodexHome
} else {
    $DefaultCodexDir
}
$ConfigFile = Join-Path $CodexDir "config.toml"
$AuthFile = Join-Path $CodexDir "auth.json"
$DesktopEnvFile = Join-Path $CodexDir ".env"
if (-not $ImageHelperPath) {
    $ImageHelperPath = Join-Path (Join-Path $HOME ".local\bin") "responses-image.py"
}
$ImageHelperCommandPath = Join-Path (Split-Path -Parent $ImageHelperPath) "responses-image.cmd"

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

function DotEnvEscape([string]$Value) {
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
    $webClient.Headers.Set("User-Agent", "vibemode-codex-desktop-setup")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        $webClient.Headers.Set("Cache-Control", "no-cache")
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
    if ($KeyFromClipboard -or (Test-EnvFlag $env:VIBEMODE_KEY_FROM_CLIPBOARD)) {
        Log "Читаю vibemode key из буфера обмена"
        return Read-ClipboardApiKey
    }

    $plain = Read-MaskedInput "Вставь vibemode key"
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

    foreach ($name in @($EnvKey, $OpenAiEnvKey, $CodexApiEnvKey)) {
        $property = $payload.PSObject.Properties[$name]
        if ($property -and $property.Value -is [string] -and $property.Value.Trim()) {
            return $property.Value.Trim()
        }
    }

    return $null
}

function Confirm-FoundApiKey([string]$Label, [string]$Value) {
    if (-not $Value -or -not $Value.Trim()) {
        return $null
    }

    $trimmed = $Value.Trim()
    if ($NonInteractive) {
        return $trimmed
    }

    if ($ReplaceKey -or (Test-EnvFlag $env:VIBEMODE_REPLACE_KEY) -or $KeyFromClipboard -or (Test-EnvFlag $env:VIBEMODE_KEY_FROM_CLIPBOARD)) {
        return Read-NewApiKey
    }

    $answer = Read-MaskedInput ($Label + ". Enter = использовать, r = заменить, или вставь новый ключ")
    $answer = $answer.Trim()
    if (-not $answer) {
        return $trimmed
    }
    if ($answer -match '^(r|replace|new|n|н|з|заменить)$') {
        return Read-NewApiKey
    }
    return $answer
}

function Read-ApiKey {
    foreach ($name in @($EnvKey, $OpenAiEnvKey, $CodexApiEnvKey)) {
        $apiKey = [Environment]::GetEnvironmentVariable($name)
        if ($apiKey -and $apiKey.Trim()) {
            return Confirm-FoundApiKey "vibemode key найден в переменной окружения" $apiKey
        }
    }

    $existingKey = Read-ExistingApiKey
    if ($existingKey) {
        return Confirm-FoundApiKey "Сохранённый vibemode key найден" $existingKey
    }

    if ($NonInteractive) {
        if ($ReplaceKey -or (Test-EnvFlag $env:VIBEMODE_REPLACE_KEY)) {
            Die "Запрошена замена API-ключа. Передай CODEX_KEY или запусти скрипт интерактивно."
        }
        Die "API-ключ не найден. Передай CODEX_KEY или один раз запусти скрипт интерактивно."
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

    if ($Target -eq $AuthFile -or $Target -eq $DesktopEnvFile) {
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
    $lines.Add("cli_auth_credentials_store = `"file`"")
    $lines.Add("")

    if (Test-Path -LiteralPath $ConfigFile) {
        $inRoot = $true
        $skipProvider = $false
        $providerHeader = "[model_providers.$ProviderName]"
        $quotedProviderHeader = "[model_providers.`"$ProviderName`"]"
        $oldProviderHeader = '[model_providers."NeuroGate API"]'
        $oldUnquotedProviderHeader = '[model_providers.NeuroGate API]'
        $defaultProfileHeader = "[profiles.default]"

        foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[') {
                $inRoot = $false
                if ($trimmed -eq $providerHeader -or $trimmed -eq $quotedProviderHeader -or $trimmed -eq $oldProviderHeader -or $trimmed -eq $oldUnquotedProviderHeader -or $trimmed -eq $defaultProfileHeader) {
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
            if ($inRoot -and $line -match '^\s*cli_auth_credentials_store\s*=') {
                continue
            }

            $lines.Add($line)
        }
        $lines.Add("")
    }

    $lines.Add("")
    $lines.Add("[model_providers.$escapedProvider]")
    $lines.Add("name = `"$escapedProvider`"")
    $lines.Add("base_url = `"$escapedUrl`"")
    $lines.Add("requires_openai_auth = true")

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

function Write-DesktopEnv([string]$ApiKey) {
    New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
    Write-IfChanged $DesktopEnvFile (Build-DesktopEnvBody $ApiKey)
}

function Build-DesktopEnvBody([string]$ApiKey) {
    $escapedKey = DotEnvEscape $ApiKey
    return "CODEX_KEY=`"$escapedKey`"`nOPENAI_API_KEY=`"$escapedKey`"`nCODEX_API_KEY=`"$escapedKey`"`n"
}

function Set-CodexPathGlobals([string]$Dir) {
    $script:CodexDir = $Dir
    $script:ConfigFile = Join-Path $script:CodexDir "config.toml"
    $script:AuthFile = Join-Path $script:CodexDir "auth.json"
    $script:DesktopEnvFile = Join-Path $script:CodexDir ".env"
}

function Normalize-PathKey([string]$PathValue) {
    if (-not $PathValue) {
        return ""
    }
    try {
        return ([System.IO.Path]::GetFullPath($PathValue)).TrimEnd('\').ToUpperInvariant()
    } catch {
        return $PathValue.TrimEnd('\').ToUpperInvariant()
    }
}

function Get-AdditionalCodexDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $primaryKey = Normalize-PathKey $CodexDir

    foreach ($dir in @($DefaultCodexDir, [Environment]::GetEnvironmentVariable("CODEX_HOME", "User"))) {
        $key = Normalize-PathKey $dir
        if (-not $key -or $key -eq $primaryKey -or $seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $dirs.Add($dir)
    }

    return $dirs
}

function Sync-AdditionalCodexDirs([string]$ApiKey) {
    $savedCodexDir = $CodexDir
    try {
        foreach ($dir in Get-AdditionalCodexDirs) {
            Set-CodexPathGlobals $dir
            Log ("Синхронизирую Codex auth: " + $CodexDir)
            Write-Config
            Write-Auth $ApiKey
            Write-DesktopEnv $ApiKey
            Assert-AuthReady
        }
    } finally {
        Set-CodexPathGlobals $savedCodexDir
    }
}

function Set-CodexKeyEnvironment([string]$ApiKey) {
    Set-Item -Path "Env:CODEX_HOME" -Value $CodexDir
    Set-Item -Path ("Env:" + $EnvKey) -Value $ApiKey
    Set-Item -Path ("Env:" + $OpenAiEnvKey) -Value $ApiKey
    Set-Item -Path ("Env:" + $CodexApiEnvKey) -Value $ApiKey
    [Environment]::SetEnvironmentVariable("CODEX_HOME", $CodexDir, "User")
    [Environment]::SetEnvironmentVariable($EnvKey, $ApiKey, "User")
    [Environment]::SetEnvironmentVariable($OpenAiEnvKey, $ApiKey, "User")
    [Environment]::SetEnvironmentVariable($CodexApiEnvKey, $ApiKey, "User")
}

function Get-PowerShellProfilePaths {
    $paths = New-Object System.Collections.Generic.List[string]
    if ($PROFILE) {
        $paths.Add([string]$PROFILE)
        try {
            if ($PROFILE.CurrentUserAllHosts) {
                $paths.Add([string]$PROFILE.CurrentUserAllHosts)
            }
        } catch {
        }
    }

    $documents = [Environment]::GetFolderPath("MyDocuments")
    if ($documents) {
        $paths.Add((Join-Path (Join-Path $documents "WindowsPowerShell") "Microsoft.PowerShell_profile.ps1"))
        $paths.Add((Join-Path (Join-Path $documents "PowerShell") "Microsoft.PowerShell_profile.ps1"))
    }

    return ($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Install-PowerShellEnvProfile {
    $begin = "# >>> vibemode codex >>>"
    $end = "# <<< vibemode codex <<<"
    $block = @(
        $begin,
        'foreach ($name in @("CODEX_HOME", "CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY")) {',
        '    $value = [Environment]::GetEnvironmentVariable($name, "User")',
        '    if ($value) { Set-Item -Path ("Env:" + $name) -Value $value }',
        '}',
        $end,
        ''
    ) -join [Environment]::NewLine

    foreach ($profilePath in Get-PowerShellProfilePaths) {
        $profileDir = Split-Path -Parent $profilePath
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        $existing = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw } else { "" }
        $pattern = [regex]::Escape($begin) + '(?s).*?' + [regex]::Escape($end) + '(\r?\n)?'
        $clean = [regex]::Replace($existing, $pattern, "")
        Write-IfChanged $profilePath ($clean.TrimEnd() + [Environment]::NewLine + $block)
    }
}

function Assert-AuthReady {
    try {
        $payload = Get-Content -LiteralPath $AuthFile -Raw | ConvertFrom-Json
    } catch {
        Die ("Codex auth.json не читается: " + $AuthFile)
    }

    $property = $payload.PSObject.Properties[$OpenAiEnvKey]
    if (-not $property -or -not ($property.Value -is [string]) -or -not $property.Value.Trim()) {
        Die ("Codex auth.json не содержит OPENAI_API_KEY: " + $AuthFile)
    }
    Log ("Codex auth готов: " + $AuthFile)
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
    $hint = " Подсказка: HTTP 401 обычно означает, что API-ключ не принят. Для замены ключа положи новый ключ в буфер и запусти: `$env:VIBEMODE_REPLACE_KEY='1'; `$env:VIBEMODE_KEY_FROM_CLIPBOARD='1'; irm `"https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1?`$(Get-Random)`" | iex; Remove-Item Env:\VIBEMODE_REPLACE_KEY, Env:\VIBEMODE_KEY_FROM_CLIPBOARD -ErrorAction SilentlyContinue. Чтобы только записать файлы без проверки: `$env:VIBEMODE_SKIP_API_CHECK='1'; irm `"https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1?`$(Get-Random)`" | iex; Remove-Item Env:\VIBEMODE_SKIP_API_CHECK -ErrorAction SilentlyContinue."
    return ("Не удалось проверить /v1/responses. Настройки записаны, но контрольный запрос к API не прошёл. Установка продолжит работу." + $suffix + $hint)
}

function Check-ResponsesApi([string]$ApiKey) {
    try {
        Enable-Tls12
        $body = @{
            model = $Model
            input = @(@{ role = "user"; content = "ping" })
            max_output_tokens = 1
            stream = $true
        } | ConvertTo-Json -Compress -Depth 5
        Invoke-RestMethod -Method Post -Uri "$BaseUrl/responses" -Headers @{
            Authorization = "Bearer $ApiKey"
            "Content-Type" = "application/json"
        } -Body $body -TimeoutSec 60 | Out-Null
        return $true
    } catch {
        Warn (Format-ApiCheckError $_ $ApiKey)
        return $false
    }
}

function Test-PythonCommand([string]$Command, [string[]]$Arguments) {
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return $false
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $cmd.Source @Arguments *> $null
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return ($LASTEXITCODE -eq 0)
}

function Test-PythonForImageHelper {
    return ((Test-PythonCommand "python" @("--version")) -or (Test-PythonCommand "py" @("-3", "--version")))
}

function Refresh-PathFromEnvironment {
    $paths = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine"),
        [Environment]::GetEnvironmentVariable("Path", "User"),
        $env:Path
    ) | Where-Object { $_ }
    $env:Path = ($paths -join ";")
}

function Add-KnownPythonDirsToPath {
    if (-not $env:LOCALAPPDATA) {
        return
    }

    $root = Join-Path (Join-Path $env:LOCALAPPDATA "Programs") "Python"
    if (-not (Test-Path -LiteralPath $root)) {
        return
    }

    $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "python.exe") } |
        Sort-Object Name -Descending
    foreach ($dir in $dirs) {
        $env:Path = $dir.FullName + ";" + $env:Path
        return
    }
}

function Add-KnownNodeDirsToPath {
    $dirs = @()
    if ($env:APPDATA) {
        $dirs += (Join-Path $env:APPDATA "npm")
    }
    if ($env:LOCALAPPDATA) {
        $dirs += (Join-Path (Join-Path $env:LOCALAPPDATA "Programs") "nodejs")
    }
    if ($env:ProgramFiles) {
        $dirs += (Join-Path $env:ProgramFiles "nodejs")
    }
    if (${env:ProgramFiles(x86)}) {
        $dirs += (Join-Path ${env:ProgramFiles(x86)} "nodejs")
    }

    foreach ($dir in ($dirs | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
            $env:Path = $dir + ";" + $env:Path
        }
    }
}

function Add-UserPathDir([string]$Dir) {
    if (-not $Dir) {
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($userPath -split ';') | Where-Object { $_ }
    foreach ($part in $parts) {
        if ($part.TrimEnd('\') -ieq $Dir.TrimEnd('\')) {
            return
        }
    }

    $newPath = if ($userPath) { $userPath + ";" + $Dir } else { $Dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = $Dir + ";" + $env:Path
}

function Get-NpmCommand {
    Add-KnownNodeDirsToPath
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        $npm = Get-Command npm -ErrorAction SilentlyContinue
    }
    return $npm
}

function Test-CodexCli {
    Add-KnownNodeDirsToPath
    $codex = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $codex) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
    }
    if (-not $codex) {
        return $false
    }

    $version = ""
    try {
        $version = (& $codex.Source --version 2>$null | Select-Object -First 1)
    } catch {
    }
    if ($version) {
        Log ("Codex CLI найден: " + $version)
    } else {
        Log ("Codex CLI найден: " + $codex.Source)
    }
    return $true
}

function Get-NodeZipUrl {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
        $arch = "arm64"
    } elseif ([Environment]::Is64BitOperatingSystem) {
        $arch = "x64"
    } else {
        $arch = "x86"
    }

    $fileTag = "win-" + $arch + "-zip"
    Enable-Tls12
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "vibemode-codex-desktop-setup")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        $index = $webClient.DownloadString("https://nodejs.org/dist/index.json") | ConvertFrom-Json
        $release = $index | Where-Object { $_.lts -and ($_.files -contains $fileTag) } | Select-Object -First 1
        if (-not $release) {
            return ""
        }
        $file = "node-" + $release.version + "-win-" + $arch + ".zip"
        return ("https://nodejs.org/dist/" + $release.version + "/" + $file)
    } catch {
        Warn ("Не удалось найти Node.js LTS на nodejs.org: " + $_.Exception.Message)
        return ""
    } finally {
        $webClient.Dispose()
    }
}

function Install-NodeFromNodeOrg {
    $url = Get-NodeZipUrl
    if (-not $url) {
        return $false
    }
    if (-not $env:LOCALAPPDATA) {
        Warn "Не удалось выбрать папку для Node.js: LOCALAPPDATA не задан."
        return $false
    }

    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) (Split-Path -Leaf $url)
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vibemode-node-" + [System.Guid]::NewGuid().ToString("N"))
    $installDir = Join-Path (Join-Path $env:LOCALAPPDATA "Programs") "nodejs"
    Log ("winget не найден или не смог поставить Node.js. Скачиваю Node.js LTS zip с nodejs.org: " + $url)

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "vibemode-codex-desktop-setup")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        Enable-Tls12
        $webClient.DownloadFile($url, $zipPath)
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $sourceDir = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $sourceDir -or -not (Test-Path -LiteralPath (Join-Path $sourceDir.FullName "npm.cmd"))) {
            Warn "Архив Node.js не содержит npm.cmd."
            return $false
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installDir) | Out-Null
        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDir.FullName -Destination $installDir
        Add-UserPathDir $installDir
        if ($env:APPDATA) {
            Add-UserPathDir (Join-Path $env:APPDATA "npm")
        }
        return $true
    } catch {
        Warn ("Не удалось поставить Node.js с nodejs.org: " + $_.Exception.Message)
        return $false
    } finally {
        $webClient.Dispose()
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-NodeForCodexCli {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Log "npm не найден. Пробую установить Node.js LTS через winget..."
        $commonArgs = @("install", "--id", "OpenJS.NodeJS.LTS", "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements", "--silent")
        & $winget.Source @($commonArgs + @("--scope", "user"))
        if ($LASTEXITCODE -ne 0) {
            & $winget.Source @commonArgs
        }
        Refresh-PathFromEnvironment
        Add-KnownNodeDirsToPath
        if (Get-NpmCommand) {
            return $true
        }
    }

    $installed = Install-NodeFromNodeOrg
    Refresh-PathFromEnvironment
    Add-KnownNodeDirsToPath
    return ($installed -and (Get-NpmCommand))
}

function Install-CodexCli {
    if (Test-CodexCli) {
        return
    }

    $npm = Get-NpmCommand
    if (-not $npm) {
        Install-NodeForCodexCli | Out-Null
        $npm = Get-NpmCommand
    }
    if (-not $npm) {
        Warn "Codex CLI не установлен: npm не найден. Установи Node.js LTS и запусти: npm install -g @openai/codex"
        return
    }

    Log "Codex CLI не найден. Ставлю @openai/codex через npm..."
    & $npm.Source install -g @openai/codex
    if ($env:APPDATA) {
        Add-UserPathDir (Join-Path $env:APPDATA "npm")
    }
    Refresh-PathFromEnvironment
    Add-KnownNodeDirsToPath
    if (-not (Test-CodexCli)) {
        Warn "Codex CLI установлен, но текущая PowerShell-сессия ещё не видит codex. Открой новый терминал или запусти: npx --yes @openai/codex --yolo"
    }
}

function Get-CodexCommand {
    Add-KnownNodeDirsToPath
    $codex = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $codex) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
    }
    return $codex
}

function Invoke-CodexLogin([string]$ApiKey) {
    $codex = Get-CodexCommand
    if (-not $codex) {
        return
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = $ApiKey | & $codex.Source @("login", "--with-api-key") 2>&1
    } catch {
        Warn ("Codex API-key login не прошёл: " + (Sanitize-Secret $_.Exception.Message $ApiKey))
        return
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($LASTEXITCODE -ne 0) {
        $details = Sanitize-Secret (($output | Out-String).Trim()) $ApiKey
        if ($details) {
            Warn ("Codex API-key login не прошёл: " + $details)
        } else {
            Warn "Codex API-key login не прошёл."
        }
    }
}

function Test-CodexCliAuth([string]$ApiKey) {
    $codex = Get-CodexCommand
    if (-not $codex) {
        return
    }

    $apiEnvNames = @($EnvKey, $OpenAiEnvKey, $CodexApiEnvKey)
    $savedApiEnv = @{}
    foreach ($name in $apiEnvNames) {
        $savedApiEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = "" | & $codex.Source 2>&1
    } catch {
        $output = @($_.Exception.Message)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        foreach ($name in $apiEnvNames) {
            if ($null -eq $savedApiEnv[$name]) {
                Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ("Env:" + $name) -Value $savedApiEnv[$name]
            }
        }
    }

    $details = Sanitize-Secret (($output | Out-String).Trim()) $ApiKey
    if ($details -match 'API key auth is missing a key') {
        Die ("Codex CLI всё ещё видит сломанный API-key auth. CODEX_HOME=" + $env:CODEX_HOME + "; auth.json=" + $AuthFile)
    }
    Log "Codex CLI auth smoke-check пройден"
}

function Get-PythonInstallerUrl {
    $version = "3.13.14"
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
        $file = "python-" + $version + "-arm64.exe"
    } elseif ([Environment]::Is64BitOperatingSystem) {
        $file = "python-" + $version + "-amd64.exe"
    } else {
        $file = "python-" + $version + ".exe"
    }
    return ("https://www.python.org/ftp/python/3.13.14/" + $file)
}

function Install-PythonFromPythonOrg {
    $url = Get-PythonInstallerUrl
    $installerPath = Join-Path ([System.IO.Path]::GetTempPath()) (Split-Path -Leaf $url)
    Log ("winget не найден или не смог поставить Python. Скачиваю Python с python.org: " + $url)

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "vibemode-codex-desktop-setup")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        Enable-Tls12
        $webClient.DownloadFile($url, $installerPath)
        $installerArgs = @("/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1", "Include_pip=1", "Include_test=0", "Shortcuts=0")
        $process = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -Wait -PassThru
        return ($process.ExitCode -eq 0)
    } catch {
        Warn ("Не удалось поставить Python с python.org: " + $_.Exception.Message)
        return $false
    } finally {
        $webClient.Dispose()
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-PythonForImageHelper {
    if (Test-PythonForImageHelper) {
        return
    }
    Add-KnownPythonDirsToPath
    if (Test-PythonForImageHelper) {
        Log "Python найден"
        return
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $installed = $false
    if ($winget) {
        Log "python не найден в PATH. Пробую установить Python через winget..."
        $pythonPackages = @("Python.Python.3.14", "Python.Python.3.13", "Python.Python.3.12")
        foreach ($package in $pythonPackages) {
            $wingetArgs = @("install", "--id", $package, "--exact", "--source", "winget", "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--silent")
            & $winget.Source @wingetArgs
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
                break
            }
        }
    }

    if (-not $installed) {
        $installed = Install-PythonFromPythonOrg
    }

    Refresh-PathFromEnvironment
    Add-KnownPythonDirsToPath
    if (Test-PythonForImageHelper) {
        Log "Python найден"
    } elseif ($installed) {
        Warn "Python установлен или установка запущена, но текущая PowerShell-сессия ещё не видит python. Открой новый терминал перед использованием responses-image."
    } else {
        Warn "Не удалось установить Python автоматически. Установи Python перед использованием responses-image."
    }
}

function Install-ImageHelper {
    if ($NoImageHelper) {
        return
    }

    $helperDir = Split-Path -Parent $ImageHelperPath
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $imageHelperSource = Resolve-DownloadSource $ImageHelperSourceCandidate $DefaultImageHelperUrl "VIBEMODE_IMAGE_HELPER_URL"
    Save-DownloadedTextFile $imageHelperSource $ImageHelperPath "image helper"

    $cmdPath = $ImageHelperCommandPath
    $helperName = Split-Path -Leaf $ImageHelperPath
    $cmdBody = @"
@echo off
python --version >nul 2>nul
if %errorlevel%==0 (
  python "%~dp0$helperName" %*
  exit /b %errorlevel%
)
py -3 --version >nul 2>nul
if %errorlevel%==0 (
  py -3 "%~dp0$helperName" %*
  exit /b %errorlevel%
)
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python*") do (
  if exist "%%D\python.exe" (
    "%%D\python.exe" "%~dp0$helperName" %*
    exit /b %errorlevel%
  )
)
echo Python is required for responses-image. Re-run Vibemode setup or install Python.
exit /b 1
"@
    Write-TextNoBom $cmdPath $cmdBody
    Log "Helper для картинок: $ImageHelperPath"
    Log "Wrapper helper для картинок: $cmdPath"
    Install-PythonForImageHelper
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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $wsl.Source @wslArgs 2>$null
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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
    $apiKeyB64 = To-Base64 $ApiKey
    $authB64 = To-Base64 (Build-AuthBody $ApiKey)
    $desktopEnvB64 = To-Base64 (Build-DesktopEnvBody $ApiKey)

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

shell_escape() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

provider="$(decode '__PROVIDER_B64__')"
base_url="$(decode '__BASE_URL_B64__')"
model="$(decode '__MODEL_B64__')"
reasoning_effort="$(decode '__EFFORT_B64__')"
api_key="$(decode '__API_KEY_B64__')"
env_key='CODEX_KEY'
auth_body_b64='__AUTH_B64__'
desktop_env_body_b64='__DESKTOP_ENV_B64__'
helper_body_b64='__HELPER_B64__'

codex_dir="$HOME/.codex"
config_file="$codex_dir/config.toml"
auth_file="$codex_dir/auth.json"
desktop_env_file="$codex_dir/.env"
shell_env_file="$codex_dir/vibemode.env"
profile_file="$HOME/.profile"
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
  printf 'cli_auth_credentials_store = "file"\n'
  printf '\n'

  if [[ -f "$config_file" ]]; then
    awk -v provider="$provider" '
      BEGIN {
        in_root = 1
        skip_provider = 0
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
          skip_provider = 1
          next
        }
        skip_provider = 0
      }
      skip_provider { next }
      in_root && /^[[:space:]]*model[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*model_reasoning_effort[[:space:]]*=/ { next }
      in_root && /^[[:space:]]*cli_auth_credentials_store[[:space:]]*=/ { next }
      { print }
    ' "$config_file"
    printf '\n'
  fi

  printf '\n[model_providers.%s]\n' "$escaped_provider"
  printf 'name = "%s"\n' "$escaped_provider"
  printf 'base_url = "%s"\n' "$escaped_url"
  printf 'requires_openai_auth = true\n'
}

build_shell_env_body() {
  local escaped_key escaped_codex_dir
  escaped_key="$(shell_escape "$api_key")"
  escaped_codex_dir="$(shell_escape "$codex_dir")"
  printf 'export CODEX_HOME=%s\n' "$escaped_codex_dir"
  printf 'export %s=%s\n' "$env_key" "$escaped_key"
  printf 'export OPENAI_API_KEY=%s\n' "$escaped_key"
  printf 'export CODEX_API_KEY=%s\n' "$escaped_key"
}

write_shell_startup() {
  local begin end quoted_env tmp body_b64
  begin='# >>> vibemode codex >>>'
  end='# <<< vibemode codex <<<'
  quoted_env="$(shell_escape "$shell_env_file")"
  tmp="$(mktemp "$codex_dir/profile.tmp.XXXXXX")"

  if [[ -f "$profile_file" ]]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$profile_file" > "$tmp"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
  fi

  {
    printf '%s\n' "$begin"
    printf '[ -f %s ] && . %s\n' "$quoted_env" "$quoted_env"
    printf '%s\n' "$end"
  } >> "$tmp"

  body_b64="$(base64 < "$tmp" | tr -d '\n')"
  rm -f "$tmp"
  write_if_changed "$profile_file" "$body_b64"
}

config_b64="$(build_config_body | base64 | tr -d '\n')"
shell_env_b64="$(build_shell_env_body | base64 | tr -d '\n')"
write_if_changed "$config_file" "$config_b64"
write_if_changed "$auth_file" "$auth_body_b64"
write_if_changed "$desktop_env_file" "$desktop_env_body_b64"
write_if_changed "$shell_env_file" "$shell_env_b64"
write_shell_startup

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
    $wslScript = $wslScript.Replace('__API_KEY_B64__', $apiKeyB64)
    $wslScript = $wslScript.Replace('__AUTH_B64__', $authB64)
    $wslScript = $wslScript.Replace('__DESKTOP_ENV_B64__', $desktopEnvB64)
    $wslScript = $wslScript.Replace('__HELPER_B64__', $helperB64)

    $wslArgs = @(Get-WslBaseArgs) + @("--", "bash", "-s")
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = $wslScript | & $wsl.Source @wslArgs 2>&1
    } catch {
        Warn "Настройка WSL не удалась: $($_.Exception.Message)"
        return
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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
Write-DesktopEnv $apiKey
Set-CodexKeyEnvironment $apiKey
Install-PowerShellEnvProfile
Install-ImageHelper
Install-WslConfig $apiKey
Install-CodexCli
Invoke-CodexLogin $apiKey
Write-Auth $apiKey
Assert-AuthReady
Sync-AdditionalCodexDirs $apiKey
Test-CodexCliAuth $apiKey

if ($SkipApiCheck -or (Test-EnvFlag $env:VIBEMODE_SKIP_API_CHECK)) {
    Log "Проверка /v1/responses пропущена"
} else {
    Log "Проверяю Vibemode API через /v1/responses..."
    if (Check-ResponsesApi $apiKey) {
        Log ""
        Log "API готов"
    }
}

Log ""
Log "Перезапусти Codex Desktop, чтобы он перечитал provider config."
Log ("Пример helper для генерации картинок: & " + [char]34 + $ImageHelperCommandPath + [char]34 + " --list-presets")
