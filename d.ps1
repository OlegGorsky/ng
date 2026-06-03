$ErrorActionPreference = "Stop"

$setupUrl = if ($env:NEUROGATE_CODEX_DESKTOP_SETUP_URL) {
    $env:NEUROGATE_CODEX_DESKTOP_SETUP_URL
} else {
    "https://raw.githubusercontent.com/OlegGorsky/neurogate-codex-termux/main/setup-neurogate-codex-desktop.ps1"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("neurogate-codex-desktop-" + [System.Guid]::NewGuid().ToString("N") + ".ps1")

function Add-CacheBust([string]$Url) {
    if ($Url -notmatch '^https?://') {
        return $Url
    }

    $cacheBust = [System.Guid]::NewGuid().ToString("N")
    if ($Url.Contains("?")) {
        return "$Url&cb=$cacheBust"
    }
    return "$Url?cb=$cacheBust"
}

function Enable-Tls12 {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {
    }
}

function Get-SetupBytes([string]$Url) {
    if (Test-Path -LiteralPath $Url) {
        return [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Url).Path)
    }

    $downloadUrl = Add-CacheBust $Url
    Enable-Tls12
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Set("User-Agent", "neurogate-codex-desktop-bootstrap")
    if ($webClient.Proxy) {
        $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }

    try {
        return $webClient.DownloadData($downloadUrl)
    } catch {
        throw ("Could not download NeuroGate setup from " + $downloadUrl + ": " + $_.Exception.Message)
    } finally {
        $webClient.Dispose()
    }
}

function ConvertFrom-SetupBytes([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -eq 0) {
        throw "Downloaded NeuroGate setup is empty."
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    try {
        $text = $strictUtf8.GetString($Bytes)
    } catch {
        throw ("Downloaded NeuroGate setup is not valid UTF-8: " + $_.Exception.Message)
    }

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    if ($text.TrimStart() -match '^(?i)<(!doctype|html)') {
        throw "Downloaded NeuroGate setup looks like HTML, not a PowerShell script."
    }

    return $text
}

function Save-SetupScript([string]$Url, [string]$Path) {
    $bytes = Get-SetupBytes $Url
    $text = ConvertFrom-SetupBytes $bytes
    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($Path, $text, $utf8Bom)
}

function Test-SetupScriptSyntax([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $parseErrors = $null
    [System.Management.Automation.PSParser]::Tokenize($text, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $summary = ($parseErrors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join " | "
        throw ("Downloaded NeuroGate setup failed PowerShell parse preflight: " + $summary)
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
    Save-SetupScript $setupUrl $tmp
    Test-SetupScriptSyntax $tmp
    try {
        Unblock-File -Path $tmp -ErrorAction SilentlyContinue
    } catch {
    }

    $powershell = Resolve-SetupPowerShell
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $tmp @args
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Setup failed with exit code $exitCode."
    }
} finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
}
