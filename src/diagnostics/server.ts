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
const RAW_BOOTSTRAP_URL = "https://raw.githubusercontent.com/OlegGorsky/ng/main/d.ps1";

function psQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
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

function installScript(base: string, sessionId: string, token: string): string {
  const eventUrl = `${base}/api/sessions/${encodeURIComponent(sessionId)}/events`;
  return `$ErrorActionPreference = "Stop"
$env:VIBEMODE_SESSION_ID = ${psQuote(sessionId)}
$env:VIBEMODE_SESSION_TOKEN = ${psQuote(token)}
$env:VIBEMODE_LOG_URL = ${psQuote(eventUrl)}
function Send-VibemodeBootstrapEvent([string]$Stage, [string]$Message) {
    try {
        $body = @{ stage = $Stage; message = $Message; data = @{ bootstrap = "install.ps1" } } | ConvertTo-Json -Compress -Depth 4
        Invoke-RestMethod -Method Post -Uri $env:VIBEMODE_LOG_URL -Headers @{ "x-session-token" = $env:VIBEMODE_SESSION_TOKEN } -ContentType "application/json" -Body $body | Out-Null
    } catch {
    }
}
Send-VibemodeBootstrapEvent "bootstrap_start" "Downloading Vibemode Windows bootstrap"
$u = ${psQuote(RAW_BOOTSTRAP_URL)}
try {
    $script = (Invoke-WebRequest -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache"; "Pragma" = "no-cache" } "$u?$(Get-Random)").Content
    Send-VibemodeBootstrapEvent "bootstrap_downloaded" "Downloaded d.ps1"
    Invoke-Expression $script
    Send-VibemodeBootstrapEvent "bootstrap_done" "Bootstrap finished"
} catch {
    Send-VibemodeBootstrapEvent "bootstrap_error" $_.Exception.Message
    throw
}
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

  app.get("/healthz", (c) => c.json({ ok: true }));

  app.post("/api/sessions", async (c) => {
    if (!requireAdmin(c, adminToken)) {
      return c.json({ error: "admin_token_required" }, 403);
    }
    let body: any = {};
    try {
      body = await c.req.json();
    } catch {
    }
    const id = randomUUID();
    const token = randomUUID();
    const base = baseUrl(c, configuredBase);
    const installUrl = `${base}/install.ps1?sid=${encodeURIComponent(id)}&token=${encodeURIComponent(token)}`;
    const command = `$u=${psQuote(installUrl)}; iex (iwr -UseBasicParsing -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'} "$u&cb=$(Get-Random)").Content`;
    createSession.run(id, token, textLimit(body.note, 300));
    return c.json({
      id,
      token,
      installUrl,
      eventUrl: `${base}/api/sessions/${id}/events`,
      eventsTextUrl: `${base}/api/sessions/${id}/events.txt`,
      command,
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
    if (!requireAdmin(c, adminToken)) {
      return c.json({ error: "admin_token_required" }, 403);
    }
    const id = c.req.param("id");
    const rows = listEvents.all(id).map((row: any) => ({ ...row, data: JSON.parse(row.data) }));
    return c.json({ id, events: rows });
  });

  app.get("/api/sessions/:id/events.txt", (c) => {
    if (!requireAdmin(c, adminToken)) {
      return c.text("admin_token_required\n", 403);
    }
    const id = c.req.param("id");
    const rows = listEvents.all(id) as any[];
    const text = rows
      .map((row) => `${row.id}\t${row.created_at}\t${row.level}\t${row.stage}\t${row.message}\t${row.data}`)
      .join("\n");
    return c.text(text + (text ? "\n" : ""));
  });

  app.get("/install.ps1", (c) => {
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
    return c.text(installScript(baseUrl(c, configuredBase), id, token), 200, {
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
