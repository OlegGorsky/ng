import { Database } from "bun:sqlite";
import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { redactForLog } from "./redact";

type Env = {
  dbPath?: string;
  publicBaseUrl?: string;
  adminToken?: string;
  port?: number;
};

const DEFAULT_PORT = 8787;
const DEFAULT_DB = ".vibemode-diagnostics.sqlite";
const BOOTSTRAP_FILE = "d.ps1";
const SETUP_FILE = "setup-vibemode-codex-desktop.ps1";
const DESKTOP_BASH_SETUP_FILE = "setup-vibemode-codex-desktop.sh";
const TERMUX_BASH_SETUP_FILE = "setup-vibemode-codex-termux.sh";
const IMAGE_HELPER_FILE = "scripts/responses_image.py";
const CODEX_WINDOWS_SETUP_URL =
  "https://raw.githubusercontent.com/OlegGorsky/w/212f701a5b808736637479028bb212b690c9fed7/Setup-CodexWindows.ps1";

function psQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function shQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function htmlEscape(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}

function jsonText(value: unknown): string {
  return JSON.stringify(value ?? {});
}

function textLimit(value: unknown, max: number): string {
  return String(value ?? "").slice(0, max);
}

function baseUrl(c: { req: { url: string } }, configured?: string): string {
  return (configured || new URL(c.req.url).origin).replace(/\/+$/, "");
}

function requireAdmin(c: any, adminToken?: string): boolean {
  if (!adminToken) {
    return true;
  }
  const url = new URL(c.req.url);
  return (c.req.header("x-admin-token") || url.searchParams.get("admin_token")) === adminToken;
}

function initDb(path: string): Database {
  const db = new Database(path);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      token TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
      note TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      level TEXT NOT NULL,
      stage TEXT NOT NULL,
      message TEXT NOT NULL,
      data TEXT NOT NULL,
      ip TEXT NOT NULL DEFAULT '',
      user_agent TEXT NOT NULL DEFAULT '',
      FOREIGN KEY(session_id) REFERENCES sessions(id)
    );
    CREATE INDEX IF NOT EXISTS events_session_idx ON events(session_id, id);
  `);
  return db;
}

async function readTextFile(path: string, label: string): Promise<string> {
  const file = Bun.file(path);
  if (!(await file.exists())) {
    throw new Error(`${label} file is missing.`);
  }
  return file.text();
}

async function installScript(base: string, sessionId: string, token: string, codexOnly = false): Promise<string> {
  const eventUrl = `${base}/api/sessions/${encodeURIComponent(sessionId)}/events`;
  const setupUrl = `${base}/setup.ps1`;
  const imageHelperUrl = `${base}/responses-image.py`;
  const bootstrap = await readTextFile(BOOTSTRAP_FILE, "Bootstrap");
  const mode = codexOnly ? "$env:VIBEMODE_CODEX_ONLY = '1'\n" : "";
  const label = codexOnly ? "Codex/WSL" : "Vibemode";
  return `$ErrorActionPreference = "Stop"
$env:VIBEMODE_SESSION_ID = ${psQuote(sessionId)}
$env:VIBEMODE_SESSION_TOKEN = ${psQuote(token)}
$env:VIBEMODE_LOG_URL = ${psQuote(eventUrl)}
$env:VIBEMODE_CODEX_DESKTOP_SETUP_URL = ${psQuote(setupUrl)}
$env:VIBEMODE_IMAGE_HELPER_URL = ${psQuote(imageHelperUrl)}
${mode}function Send-VibemodeBootstrapEvent([string]$Stage, [string]$Message) {
    try {
        $body = @{ stage = $Stage; message = $Message; data = @{ bootstrap = "install.ps1" } } | ConvertTo-Json -Compress -Depth 4
        Invoke-RestMethod -Method Post -Uri $env:VIBEMODE_LOG_URL -Headers @{ "x-session-token" = $env:VIBEMODE_SESSION_TOKEN } -ContentType "application/json" -Body $body | Out-Null
    } catch {
    }
}
Send-VibemodeBootstrapEvent "bootstrap_start" "Running inline ${label} Windows bootstrap"

${bootstrap}
`;
}

function codexWindowsInstallScript(base: string, sessionId: string, token: string): string {
  const eventUrl = `${base}/api/sessions/${encodeURIComponent(sessionId)}/events`;
  return `$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:VIBEMODE_SESSION_ID = ${psQuote(sessionId)}
$env:VIBEMODE_SESSION_TOKEN = ${psQuote(token)}
$env:VIBEMODE_LOG_URL = ${psQuote(eventUrl)}
$setupUrl = ${psQuote(CODEX_WINDOWS_SETUP_URL)}
$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$setup = Join-Path $tempRoot "Setup-CodexWindows.ps1"

function Send-CodexBootstrapEvent([string]$Stage, [string]$Message, $Data = @{}, [string]$Level = "info") {
    try {
        $body = @{ level = $Level; stage = $Stage; message = $Message; data = $Data } | ConvertTo-Json -Compress -Depth 6
        Invoke-RestMethod -Method Post -Uri $env:VIBEMODE_LOG_URL -Headers @{ "x-session-token" = $env:VIBEMODE_SESSION_TOKEN } -ContentType "application/json" -Body $body | Out-Null
    } catch {
    }
}

function Send-CodexSetupLogTail([string]$Level = "info") {
    try {
        $latestLog = Get-ChildItem -LiteralPath $tempRoot -Filter "codex-windows-setup-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $latestLog) {
            Send-CodexBootstrapEvent "codex_windows_setup_log_tail" "Latest Codex Windows setup log tail" @{
                path = $latestLog.FullName
                tail = ((Get-Content -LiteralPath $latestLog.FullName -Tail 120 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
            } $Level
        }
    } catch {
    }
}

try {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
    }

    Send-CodexBootstrapEvent "bootstrap_start" "Running full Codex Windows setup" @{ setup_source = $setupUrl }
    $cacheBust = [Guid]::NewGuid().ToString("N")
    Invoke-WebRequest -Uri ("{0}?cb={1}" -f $setupUrl, $cacheBust) -UseBasicParsing -OutFile $setup
    try { Unblock-File -Path $setup -ErrorAction SilentlyContinue } catch {}

    $powershell = Join-Path $env:WINDIR "System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    Send-CodexBootstrapEvent "codex_windows_setup_execute" "Executing full Codex Windows setup" @{ powershell = $powershell; setup_file = $setup }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $setup -RepairStorePolicies
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    if ($exitCode -eq 3010) {
        Send-CodexSetupLogTail "info"
        Send-CodexBootstrapEvent "codex_windows_setup_reboot_required" "Codex Windows setup completed and requires reboot" @{ exit_code = $exitCode } "warn"
    } elseif ($exitCode -ne 0) {
        Send-CodexBootstrapEvent "codex_windows_setup_failed" "Codex Windows setup failed" @{ exit_code = $exitCode } "error"
        Send-CodexSetupLogTail "warn"
        throw "Codex Windows setup failed with exit code $exitCode."
    } else {
        Send-CodexSetupLogTail "info"
        Send-CodexBootstrapEvent "codex_windows_setup_done" "Codex Windows setup completed" @{ exit_code = $exitCode }
    }
} catch {
    Send-CodexBootstrapEvent "bootstrap_failed" ($_.Exception.Message) @{} "error"
    Send-CodexSetupLogTail "warn"
    throw
}
`;
}

function bashInstallScript(base: string, sessionId: string, token: string, target: "linux" | "termux"): string {
  const setupUrl = `${base}/${target === "termux" ? "setup-termux.sh" : "setup-desktop.sh"}`;
  const label = target === "termux" ? "Termux" : "Linux/macOS";
  const eventUrl = `${base}/api/sessions/${encodeURIComponent(sessionId)}/events`;
  return `#!/usr/bin/env bash
set -euo pipefail

export VIBEMODE_SESSION_ID=${shQuote(sessionId)}
export VIBEMODE_SESSION_TOKEN=${shQuote(token)}
export VIBEMODE_LOG_URL=${shQuote(eventUrl)}
export VIBEMODE_SETUP_URL=${shQuote(setupUrl)}

send_event() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -X POST "$VIBEMODE_LOG_URL" \\
    -H "x-session-token: $VIBEMODE_SESSION_TOKEN" \\
    -H 'content-type: application/json' \\
    --data "$1" >/dev/null 2>&1 || true
}

tmp_parent="\${TMPDIR:-\${PREFIX:-}/tmp}"
if [[ -z "$tmp_parent" || ! -d "$tmp_parent" ]]; then
  tmp_parent="\${HOME:-.}"
fi
tmp="$(mktemp "$tmp_parent/vibemode-${target}.XXXXXX")"

finish() {
  status="$?"
  if [[ "$status" -eq 0 ]]; then
    send_event '{"stage":"bootstrap_done","message":"Bash setup finished","data":{"bootstrap":"install.sh","target":"${target}"}}'
  else
    send_event '{"stage":"bootstrap_failed","message":"Bash setup failed","data":{"bootstrap":"install.sh","target":"${target}","exit_code":'"$status"'}}'
  fi
  rm -f "$tmp"
  exit "$status"
}
trap finish EXIT

send_event '{"stage":"bootstrap_start","message":"Running Vibemode ${label} bootstrap","data":{"bootstrap":"install.sh","target":"${target}"}}'
curl -fsSL -H 'Cache-Control: no-cache' "$VIBEMODE_SETUP_URL" -o "$tmp"
send_event '{"stage":"bootstrap_execute","message":"Executing bash setup script","data":{"bootstrap":"install.sh","target":"${target}"}}'
bash "$tmp" "$@"
`;
}

export function createApp(env: Env = {}) {
  const db = initDb(env.dbPath || Bun.env.VIBEMODE_DIAG_DB || DEFAULT_DB);
  const adminToken = env.adminToken ?? Bun.env.VIBEMODE_DIAG_ADMIN_TOKEN;
  const configuredBase = env.publicBaseUrl ?? Bun.env.VIBEMODE_PUBLIC_BASE_URL;
  const app = new Hono();

  const getSession = db.query("SELECT id, token, created_at, last_seen_at, note FROM sessions WHERE id = ?");
  const createSession = db.prepare("INSERT INTO sessions (id, token, note) VALUES (?, ?, ?)");
  const touchSession = db.prepare("UPDATE sessions SET last_seen_at = datetime('now') WHERE id = ?");
  const insertEvent = db.prepare(
    "INSERT INTO events (session_id, level, stage, message, data, ip, user_agent) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  const listEvents = db.query(
    "SELECT id, created_at, level, stage, message, data, ip, user_agent FROM events WHERE session_id = ? ORDER BY id ASC",
  );

  function createSessionPayload(c: any, note: unknown) {
    const id = randomUUID();
    const token = randomUUID();
    const base = baseUrl(c, configuredBase);
    const installUrl = `${base}/install.ps1?sid=${encodeURIComponent(id)}&token=${encodeURIComponent(token)}`;
    const linuxInstallUrl = `${base}/linux.sh?sid=${encodeURIComponent(id)}&token=${encodeURIComponent(token)}`;
    const termuxInstallUrl = `${base}/termux.sh?sid=${encodeURIComponent(id)}&token=${encodeURIComponent(token)}`;
    const command = `$u=${psQuote(installUrl)}; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u&cb=$(Get-Random)").Content`;
    createSession.run(id, token, textLimit(note, 300));
    return {
      id,
      token,
      installUrl,
      linuxInstallUrl,
      termuxInstallUrl,
      eventUrl: `${base}/api/sessions/${id}/events`,
      eventsUrl: `${base}/api/sessions/${id}/events?token=${encodeURIComponent(token)}`,
      eventsTextUrl: `${base}/api/sessions/${id}/events.txt`,
      command,
      linuxCommand: `curl -fsSL ${shQuote(linuxInstallUrl)} | bash`,
      termuxCommand: `curl -fsSL ${shQuote(termuxInstallUrl)} | bash`,
    };
  }

  function installPage(c: any): string {
    const session = createSessionPayload(c, "site connect");
    const commands = [
      ["Windows PowerShell", session.command],
      ["Linux/macOS", session.linuxCommand],
      ["Termux", session.termuxCommand],
    ];
    return `<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Vibemode Codex connect</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:32px;max-width:960px;background:#0f172a;color:#e5e7eb}
    h1{font-size:28px;margin:0 0 20px}
    h2{font-size:16px;margin:22px 0 8px;color:#93c5fd}
    pre{white-space:pre-wrap;word-break:break-word;background:#020617;border:1px solid #334155;border-radius:8px;padding:14px}
    code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}
  </style>
</head>
<body>
  <h1>Vibemode Codex connect</h1>
  ${commands.map(([title, command]) => `<h2>${htmlEscape(title)}</h2><pre><code>${htmlEscape(command)}</code></pre>`).join("")}
  <h2>Логи</h2>
  <pre id="logs">waiting...</pre>
  <script>
    const eventsUrl = ${JSON.stringify(session.eventsUrl)};
    async function poll() {
      try {
        const response = await fetch(eventsUrl, { cache: "no-store" });
        const body = await response.json();
        const rows = body.events || [];
        document.getElementById("logs").textContent = rows.length
          ? rows.map((event) => [event.id, event.created_at, event.level, event.stage, event.message].join(" | ")).join("\\n")
          : "waiting...";
      } catch {
      }
    }
    poll();
    setInterval(poll, 2000);
  </script>
</body>
</html>`;
  }

  function sessionTokenOk(id: string, c: any): boolean {
    const session = getSession.get(id) as { token: string } | null;
    if (!session) {
      return false;
    }
    const url = new URL(c.req.url);
    return (c.req.header("x-session-token") || url.searchParams.get("token")) === session.token;
  }

  app.get("/healthz", (c) => c.json({ ok: true }));

  app.get("/", (c) =>
    c.html(installPage(c), 200, {
      "Cache-Control": "no-store",
    }),
  );

  app.post("/api/sessions", async (c) => {
    if (!requireAdmin(c, adminToken)) {
      return c.json({ error: "admin_token_required" }, 403);
    }
    let body: any = {};
    try {
      body = await c.req.json();
    } catch {
    }
    return c.json(createSessionPayload(c, body.note));
  });

  app.get("/i", async (c) => {
    const session = createSessionPayload(c, "short install");
    return c.text(codexWindowsInstallScript(baseUrl(c, configuredBase), session.id, session.token), 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/linux.sh", async (c) => {
    const url = new URL(c.req.url);
    const id = url.searchParams.get("sid") || "";
    if (!sessionTokenOk(id, c)) {
      return c.text("Bad diagnostics session token.", 403);
    }
    const token = url.searchParams.get("token") || c.req.header("x-session-token") || "";
    return c.text(bashInstallScript(baseUrl(c, configuredBase), id, token, "linux"), 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/termux.sh", async (c) => {
    const url = new URL(c.req.url);
    const id = url.searchParams.get("sid") || "";
    if (!sessionTokenOk(id, c)) {
      return c.text("Bad diagnostics session token.", 403);
    }
    const token = url.searchParams.get("token") || c.req.header("x-session-token") || "";
    return c.text(bashInstallScript(baseUrl(c, configuredBase), id, token, "termux"), 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.post("/api/sessions/:id/events", async (c) => {
    const id = c.req.param("id");
    const session = getSession.get(id) as { token: string } | null;
    if (!session) {
      return c.json({ error: "session_not_found" }, 404);
    }
    const url = new URL(c.req.url);
    const token = c.req.header("x-session-token") || url.searchParams.get("token");
    if (token !== session.token) {
      return c.json({ error: "bad_session_token" }, 403);
    }

    let body: any = {};
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "bad_json" }, 400);
    }

    const clean = redactForLog(body) as Record<string, unknown>;
    const level = textLimit(clean.level || "info", 20);
    const stage = textLimit(clean.stage || "event", 80);
    const message = textLimit(clean.message || "", 2000);
    const data = jsonText(clean.data || {});
    if (data.length > 30000) {
      return c.json({ error: "event_too_large" }, 413);
    }

    insertEvent.run(
      id,
      level,
      stage,
      message,
      data,
      textLimit(c.req.header("x-forwarded-for") || "", 200),
      textLimit(c.req.header("user-agent") || "", 300),
    );
    touchSession.run(id);
    console.log(`[${id}] ${level} ${stage}: ${message}`);
    return c.json({ ok: true });
  });

  app.get("/api/sessions/:id/events", (c) => {
    const id = c.req.param("id");
    if (!requireAdmin(c, adminToken) && !sessionTokenOk(id, c)) {
      return c.json({ error: "admin_token_required" }, 403);
    }
    const rows = listEvents.all(id).map((row: any) => ({ ...row, data: JSON.parse(row.data) }));
    return c.json({ id, events: rows });
  });

  app.get("/api/sessions/:id/events.txt", (c) => {
    const id = c.req.param("id");
    if (!requireAdmin(c, adminToken) && !sessionTokenOk(id, c)) {
      return c.text("admin_token_required\n", 403);
    }
    const rows = listEvents.all(id) as any[];
    const text = rows
      .map((row) => `${row.id}\t${row.created_at}\t${row.level}\t${row.stage}\t${row.message}\t${row.data}`)
      .join("\n");
    return c.text(text + (text ? "\n" : ""));
  });

  app.get(`/${BOOTSTRAP_FILE}`, async (c) => {
    const file = Bun.file(BOOTSTRAP_FILE);
    if (!(await file.exists())) {
      return c.text("Bootstrap file is missing.", 500);
    }
    return c.body(file, 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/setup.ps1", async (c) => {
    const file = Bun.file(SETUP_FILE);
    if (!(await file.exists())) {
      return c.text("Setup file is missing.", 500);
    }
    return c.body(file, 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/setup-desktop.sh", async (c) => {
    const file = Bun.file(DESKTOP_BASH_SETUP_FILE);
    if (!(await file.exists())) {
      return c.text("Desktop setup file is missing.", 500);
    }
    return c.body(file, 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/setup-termux.sh", async (c) => {
    const file = Bun.file(TERMUX_BASH_SETUP_FILE);
    if (!(await file.exists())) {
      return c.text("Termux setup file is missing.", 500);
    }
    return c.body(file, 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/responses-image.py", async (c) => {
    const file = Bun.file(IMAGE_HELPER_FILE);
    if (!(await file.exists())) {
      return c.text("Image helper file is missing.", 500);
    }
    return c.body(file, 200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
    });
  });

  app.get("/install.ps1", async (c) => {
    const url = new URL(c.req.url);
    const id = url.searchParams.get("sid") || "";
    const token = url.searchParams.get("token") || "";
    const session = getSession.get(id) as { token: string } | null;
    if (!session) {
      return c.text("Unknown diagnostics session.", 404);
    }
    if (token !== session.token) {
      return c.text("Bad diagnostics session token.", 403);
    }
    return c.text(await installScript(baseUrl(c, configuredBase), id, token), 200, {
      "Content-Type": "text/plain; charset=utf-8",
    });
  });

  return app;
}

if (import.meta.main) {
  const port = Number(Bun.env.PORT || DEFAULT_PORT);
  Bun.serve({ port, fetch: createApp({ port }).fetch });
  console.log(`Vibemode diagnostics server listening on http://127.0.0.1:${port}`);
}
