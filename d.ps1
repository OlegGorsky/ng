$ErrorActionPreference = "Stop"

$defaultSetupUrl = "https://raw.githubusercontent.com/OlegGorsky/ng/main/setup-vibemode-codex-desktop.ps1"
$setupUrlCandidate = if ($env:VIBEMODE_CODEX_DESKTOP_SETUP_URL) {
    $env:VIBEMODE_CODEX_DESKTOP_SETUP_URL
} else {
    $defaultSetupUrl
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vibemode-codex-desktop-" + [System.Guid]::NewGuid().ToString("N") + ".ps1")

function Redact-DiagnosticsText([string]$Text) {
    if (-not $Text) {
        return ""
    }
    $clean = [regex]::Replace($Text, 'Bearer\s+[^\s"'',;]+', 'Bearer [redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $clean = [regex]::Replace($clean, 'sk-[A-Za-z0-9_*.-]{8,}', 'sk-[redacted]')
    $clean = [regex]::Replace($clean, '\b(CODEX_KEY|OPENAI_API_KEY|CODEX_API_KEY)\s*[:=]\s*("[^"]+"|''[^'']+''|[^\s,;]+)', '$1=[redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $clean
}

function Convert-DiagnosticsValue($Value) {
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return Redact-DiagnosticsText $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '(?i)(api[_-]?key|token|secret|password|authorization|credential)' -and $name -notmatch '^(auth_keys|env_keys|config_keys|key_names)$') {
                $out[$name] = "[redacted]"
            } else {
                $out[$name] = Convert-DiagnosticsValue $Value[$key]
            }
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += Convert-DiagnosticsValue $item
        }
        return $items
    }
    return $Value
}

function Send-DiagnosticsEvent([string]$Stage, [string]$Message, $Data = @{}, [string]$Level = "info") {
    if (-not $env:VIBEMODE_LOG_URL) {
        return
    }
    try {
        $headers = @{}
        if ($env:VIBEMODE_SESSION_TOKEN) {
            $headers["x-session-token"] = $env:VIBEMODE_SESSION_TOKEN
        }
        $body = @{
            level = $Level
            stage = $Stage
            message = (Redact-DiagnosticsText $Message)
            data = (Convert-DiagnosticsValue $Data)
        } | ConvertTo-Json -Compress -Depth 8
        Invoke-RestMethod -Method Post -Uri $env:VIBEMODE_LOG_URL -Headers $headers -ContentType "application/json" -Body $body | Out-Null
    } catch {
    }
}

function Add-CacheBust([string]$Url) {
    if ($Url -notmatch '^https?://') {
        return $Url
    }

    $cacheBust = [System.Guid]::NewGuid().ToString("N")
    if ($Url.Contains("?")) {
        return ($Url + "&cb=" + $cacheBust)
    }
    return ($Url + "?cb=" + $cacheBust)
}

function Refresh-PathFromEnvironment {
    $paths = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine"),
        [Environment]::GetEnvironmentVariable("Path", "User"),
        $env:Path
    ) | Where-Object { $_ }
    $env:Path = ($paths -join ";")
}

function Refresh-CodexEnvironment {
    foreach ($name in @("CODEX_HOME", "CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY")) {
        $value = [Environment]::GetEnvironmentVariable($name, "User")
        if ($null -eq $value) {
            $value = [Environment]::GetEnvironmentVariable($name, "Machine")
        }
        if ($null -ne $value) {
            Set-Item -Path ("Env:" + $name) -Value $value
        }
    }
}

function Test-EnvFlag([string]$Value) {
    if (-not $Value) {
        return $false
    }
    return $Value -match '^(1|true|yes|y|on)$'
}

function JsonEscape([string]$Value) {
    if ($null -eq $Value) {
        return ""
    }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", "").Replace("`n", "")
}

function TomlEscape([string]$Value) {
    return JsonEscape $Value
}

function DotEnvEscape([string]$Value) {
    return JsonEscape $Value
}

function Get-ClipboardRepairApiKey {
    if (-not (Test-EnvFlag $env:VIBEMODE_KEY_FROM_CLIPBOARD)) {
        return $null
    }

    try {
        $value = (Get-Clipboard -ErrorAction Stop) -join [Environment]::NewLine
    } catch {
        return $null
    }

    if ($value -and $value.Trim()) {
        return $value.Trim()
    }
    return $null
}

function Set-CodexRepairKeyEnvironment([string]$apiKey) {
    if (-not $apiKey) {
        return
    }

    foreach ($name in @("CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY")) {
        Set-Item -Path ("Env:" + $name) -Value $apiKey
        [Environment]::SetEnvironmentVariable($name, $apiKey, "User")
    }
}

function Get-CodexRepairDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $defaultUserProfileDir = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE ".codex" } else { $null }
    foreach ($dir in @(
        $env:CODEX_HOME,
        [Environment]::GetEnvironmentVariable("CODEX_HOME", "User"),
        [Environment]::GetEnvironmentVariable("CODEX_HOME", "Machine"),
        (Join-Path $HOME ".codex"),
        $defaultUserProfileDir
    )) {
        if (-not $dir) {
            continue
        }
        try {
            $key = ([System.IO.Path]::GetFullPath($dir)).TrimEnd('\').ToUpperInvariant()
        } catch {
            $key = $dir.TrimEnd('\').ToUpperInvariant()
        }
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $dirs.Add($dir)
    }
    return $dirs
}

function Build-CodexRepairConfigBody([string]$ConfigFile) {
    $providerName = "vibemode"
    $escapedModel = TomlEscape "gpt-5.4"
    $escapedProvider = TomlEscape $providerName
    $escapedUrl = TomlEscape "https://api.vibemod.pro/v1"
    $escapedEffort = TomlEscape "medium"
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("model = `"$escapedModel`"")
    $lines.Add("model_provider = `"$escapedProvider`"")
    $lines.Add("model_reasoning_effort = `"$escapedEffort`"")
    $lines.Add("cli_auth_credentials_store = `"file`"")
    $lines.Add("")

    if (Test-Path -LiteralPath $ConfigFile) {
        $inRoot = $true
        $skipTable = $false
        foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[') {
                $inRoot = $false
                $skipTable = @(
                    "[model_providers.$providerName]",
                    "[model_providers.`"$providerName`"]",
                    '[model_providers."NeuroGate API"]',
                    '[model_providers.NeuroGate API]',
                    "[profiles.default]"
                ) -contains $trimmed
                if ($skipTable) {
                    continue
                }
            }

            if ($skipTable) {
                continue
            }
            if ($inRoot -and $line -match '^\s*(model|model_provider|model_reasoning_effort|cli_auth_credentials_store)\s*=') {
                continue
            }
            if ($line -match '^\s*wire_api\s*=') {
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

function Write-CodexRepairText([string]$Path, [string]$Body) {
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Body, $utf8)
}

function Write-CodexRepairConfig([string]$Dir) {
    $configFile = Join-Path $Dir "config.toml"
    Write-CodexRepairText $configFile (Build-CodexRepairConfigBody $configFile)
}

function Write-CodexRepairAuth([string]$Dir, [string]$ApiKey) {
    $authFile = Join-Path $Dir "auth.json"
    $escapedKey = JsonEscape $ApiKey
    $body = "{`n  `"auth_mode`": `"apikey`",`n  `"OPENAI_API_KEY`": `"$escapedKey`"`n}`n"
    Write-CodexRepairText $authFile $body
}

function Write-CodexRepairDesktopEnv([string]$Dir, [string]$ApiKey) {
    $envFile = Join-Path $Dir ".env"
    $escapedKey = DotEnvEscape $ApiKey
    $body = "CODEX_KEY=`"$escapedKey`"`nOPENAI_API_KEY=`"$escapedKey`"`nCODEX_API_KEY=`"$escapedKey`"`n"
    Write-CodexRepairText $envFile $body
}

function Repair-CodexApiKeyAuth {
    $clipboardApiKey = Get-ClipboardRepairApiKey
    foreach ($dir in Get-CodexRepairDirs) {
        $authFile = Join-Path $dir "auth.json"
        $apiKey = $clipboardApiKey

        if (-not $apiKey -and (Test-Path -LiteralPath $authFile)) {
            try {
                $payload = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
                $openAiProperty = $payload.PSObject.Properties["OPENAI_API_KEY"]
                if ($openAiProperty -and $openAiProperty.Value -is [string] -and $openAiProperty.Value.Trim()) {
                    $apiKey = $openAiProperty.Value.Trim()
                } else {
                    $staleProperty = $payload.PSObject.Properties["CODEX_KEY"]
                    if ($staleProperty -and $staleProperty.Value -is [string] -and $staleProperty.Value.Trim()) {
                        $apiKey = $staleProperty.Value.Trim()
                    }
                    if (-not $apiKey) {
                        $codexApiProperty = $payload.PSObject.Properties["CODEX_API_KEY"]
                        if ($codexApiProperty -and $codexApiProperty.Value -is [string] -and $codexApiProperty.Value.Trim()) {
                            $apiKey = $codexApiProperty.Value.Trim()
                        }
                    }
                }
            } catch {
            }
        }

        if (-not $apiKey) {
            foreach ($name in @("OPENAI_API_KEY", "CODEX_KEY", "CODEX_API_KEY")) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if ($value -and $value.Trim()) {
                    $apiKey = $value.Trim()
                    break
                }
            }
        }
        if (-not $apiKey) {
            continue
        }

        Set-CodexRepairKeyEnvironment $apiKey
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-CodexRepairConfig $dir
        Write-CodexRepairAuth $dir $apiKey
        Write-CodexRepairDesktopEnv $dir $apiKey
    }
}

function Write-CodexRepairState {
    $activeHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
    Write-Host ("[Vibemode] CODEX_HOME=" + $activeHome)
    Write-Host ("[Vibemode] HOME=" + $HOME)
    Write-Host ("[Vibemode] USERPROFILE=" + $env:USERPROFILE)
    $state = @{
        codex_home = $activeHome
        home = $HOME
        userprofile = $env:USERPROFILE
        config = @{
            path = (Join-Path $activeHome "config.toml")
            exists = $false
            requires_openai_auth = $false
            env_key_present = $false
        }
        auth = @{
            path = (Join-Path $activeHome "auth.json")
            exists = $false
            auth_keys = @()
        }
    }

    $configFile = Join-Path $activeHome "config.toml"
    if (Test-Path -LiteralPath $configFile) {
        try {
            $configText = Get-Content -LiteralPath $configFile -Raw
            $requiresOpenAiAuth = if ($configText -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*$') { "true" } else { "false" }
            $hasEnvKey = if ($configText -match '(?m)^\s*env_key\s*=') { "true" } else { "false" }
            $state.config.exists = $true
            $state.config.requires_openai_auth = ($requiresOpenAiAuth -eq "true")
            $state.config.env_key_present = ($hasEnvKey -eq "true")
            Write-Host ("[Vibemode] config.toml: requires_openai_auth=" + $requiresOpenAiAuth + "; env_key_present=" + $hasEnvKey)
        } catch {
            $state.config.error = $_.Exception.Message
            Write-Warning ("Could not inspect " + $configFile + ": " + $_.Exception.Message)
        }
    } else {
        Write-Host ("[Vibemode] config.toml missing: " + $configFile)
    }

    $authFile = Join-Path $activeHome "auth.json"
    if (Test-Path -LiteralPath $authFile) {
        try {
            $payload = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
            $names = @($payload.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
            $state.auth.exists = $true
            $state.auth.auth_keys = @($payload.PSObject.Properties | ForEach-Object { $_.Name })
            Write-Host ("[Vibemode] auth.json keys: " + $names)
        } catch {
            $state.auth.error = $_.Exception.Message
            Write-Warning ("Could not inspect " + $authFile + ": " + $_.Exception.Message)
        }
    } else {
        Write-Host ("[Vibemode] auth.json missing: " + $authFile)
    }
    Send-DiagnosticsEvent "repair_state" "Codex repair state" $state
}

function Get-CodexRepairCommand {
    Add-KnownCommandDirsToPath
    $codex = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $codex) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
    }
    return $codex
}

function Test-CodexRepairSmoke {
    $codex = Get-CodexRepairCommand
    if (-not $codex) {
        Send-DiagnosticsEvent "repair_codex_missing" "Codex command was not found"
        return
    }

    $apiEnvNames = @("CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY")
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

    $details = (($output | Out-String).Trim())
    if ($details -match 'API key auth is missing a key') {
        $activeHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
        Send-DiagnosticsEvent "repair_smoke_missing_key" $details @{
            codex_source = $codex.Source
            codex_home = $activeHome
            config_file = (Join-Path $activeHome "config.toml")
            auth_file = (Join-Path $activeHome "auth.json")
        } "error"
        Write-Warning ("Codex CLI still reads broken API-key auth. CODEX_HOME=" + $activeHome + "; check " + (Join-Path $activeHome "config.toml") + " and " + (Join-Path $activeHome "auth.json"))
    } else {
        Send-DiagnosticsEvent "repair_smoke_ok" "Codex repair smoke-check passed" @{
            codex_source = $codex.Source
        }
    }
}

function Add-KnownCommandDirsToPath {
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

    foreach ($dir in ($dirs | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
            $env:Path = $dir + ";" + $env:Path
        }
    }
}

function Test-HttpUrl([string]$Url) {
    return ($Url -match '^https?://')
}

function Resolve-SetupSource([string]$Candidate, [string]$DefaultUrl) {
    $value = if ($Candidate) { $Candidate.Trim() } else { "" }
    if ($value -and (Test-HttpUrl $value)) {
        return $value
    }
    if ($value -and (Test-Path -LiteralPath $value -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $value).Path
    }
    if ($value -and $value -ne $DefaultUrl) {
        Write-Warning ("Ignoring invalid VIBEMODE_CODEX_DESKTOP_SETUP_URL value: " + $value)
    }
    return $DefaultUrl
}

function Resolve-SetupSourceCandidates([string]$Candidate, [string]$DefaultUrl) {
    $sources = New-Object System.Collections.Generic.List[string]
    $first = Resolve-SetupSource $Candidate $DefaultUrl
    if ($first) {
        [void]$sources.Add($first)
    }
    if ($DefaultUrl -and $first -ne $DefaultUrl) {
        [void]$sources.Add($DefaultUrl)
    }
    return @($sources)
}

function Enable-Tls12 {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

function Get-SetupBytes([string]$Url) {
    if (-not $Url) {
        throw "Vibemode setup source is empty."
    }

    if (-not (Test-HttpUrl $Url)) {
        if (-not (Test-Path -LiteralPath $Url -PathType Leaf)) {
            throw ("Vibemode setup source is neither an http(s) URL nor an existing file: " + $Url)
        }
        return [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Url).Path)
    }

    $downloadUrl = Add-CacheBust $Url
    Enable-Tls12
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "vibemode-codex-desktop-bootstrap")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        $webClient.Headers.Set("Cache-Control", "no-cache")
        return $webClient.DownloadData($downloadUrl)
    } catch {
        throw ("Could not download Vibemode setup from " + $downloadUrl + ": " + $_.Exception.Message)
    } finally {
        $webClient.Dispose()
    }
}

function ConvertFrom-SetupBytes([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) {
        throw "Downloaded Vibemode setup is empty."
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    try {
        $text = $strictUtf8.GetString($Bytes)
    } catch {
        throw ("Downloaded Vibemode setup is not valid UTF-8: " + $_.Exception.Message)
    }

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    if ($text.TrimStart() -match '^(?i)<(!doctype|html)') {
        throw "Downloaded Vibemode setup looks like HTML, not a PowerShell script."
    }

    return $text
}

function Save-SetupScript([string[]]$Sources, [string]$Path) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($setupSource in @($Sources)) {
        if (-not $setupSource) {
            continue
        }
        try {
            Send-DiagnosticsEvent "repair_bootstrap_download_attempt" "Trying setup source" @{
                setup_source = $setupSource
            }
            $bytes = Get-SetupBytes $setupSource
            $text = ConvertFrom-SetupBytes $bytes
            $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
            [System.IO.File]::WriteAllText($Path, $text, $utf8Bom)
            return $setupSource
        } catch {
            $message = $_.Exception.Message
            [void]$errors.Add($setupSource + ": " + $message)
            Write-Warning ("Setup source failed: " + $setupSource + ": " + $message)
            Send-DiagnosticsEvent "repair_bootstrap_download_failed" $message @{
                setup_source = $setupSource
            } "warn"
        }
    }

    if (-not $errors.Count) {
        throw "No Vibemode setup sources were available."
    }
    throw ("All Vibemode setup sources failed: " + ($errors -join " | "))
}

function Test-SetupScriptSyntax([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $parseErrors = $null
    [System.Management.Automation.PSParser]::Tokenize($text, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $summary = ($parseErrors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join " | "
        throw ("Downloaded Vibemode setup failed PowerShell parse preflight: " + $summary)
    }
}

function Resolve-SetupPowerShell {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    $roots = @(
        [Environment]::GetFolderPath('ProgramFiles'),
        $env:ProgramW6432,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($root in $roots) {
        foreach ($version in @("7", "7-preview")) {
            $candidate = Join-Path $root ("PowerShell\" + $version + "\pwsh.exe")
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")
}

try {
    Send-DiagnosticsEvent "repair_bootstrap_start" "Starting Vibemode Windows bootstrap" @{
        setup_source = $setupUrlCandidate
    }
    $setupSources = Resolve-SetupSourceCandidates $setupUrlCandidate $defaultSetupUrl
    Send-DiagnosticsEvent "repair_bootstrap_resolved" "Resolved setup source" @{
        setup_sources = @($setupSources)
    }
    $setupUrl = Save-SetupScript $setupSources $tmp
    Send-DiagnosticsEvent "repair_bootstrap_downloaded" "Downloaded setup script" @{
        setup_source = $setupUrl
        temp_file = $tmp
    }
    Test-SetupScriptSyntax $tmp
    try {
        Unblock-File -Path $tmp -ErrorAction SilentlyContinue
    } catch {
    }

    $powershell = Resolve-SetupPowerShell
    Send-DiagnosticsEvent "repair_bootstrap_execute" "Executing setup script" @{
        powershell = $powershell
    }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $tmp @args
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        Send-DiagnosticsEvent "repair_bootstrap_setup_failed" ("Setup failed with exit code " + $exitCode + ".") @{
            exit_code = $exitCode
        } "error"
        throw "Setup failed with exit code $exitCode."
    }
} finally {
    Refresh-CodexEnvironment
    Repair-CodexApiKeyAuth
    Refresh-CodexEnvironment
    Write-CodexRepairState
    Refresh-PathFromEnvironment
    Add-KnownCommandDirsToPath
    Test-CodexRepairSmoke
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    Send-DiagnosticsEvent "repair_bootstrap_finally_done" "Bootstrap cleanup finished"
}
