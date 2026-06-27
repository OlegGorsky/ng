import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { createApp } from "./server";

test("session creation requires admin token when configured", async () => {
  const dir = mkdtempSync(join(tmpdir(), "vibemode-diag-"));
  try {
    const app = createApp({
      adminToken: "admin-secret",
      dbPath: join(dir, "diagnostics.sqlite"),
      publicBaseUrl: "https://install.example.test",
    });

    const denied = await app.request("/api/sessions", {
      method: "POST",
      body: "{}",
      headers: { "content-type": "application/json" },
    });
    expect(denied.status).toBe(403);

    const allowed = await app.request("/api/sessions", {
      method: "POST",
      body: JSON.stringify({ note: "smoke" }),
      headers: {
        "content-type": "application/json",
        "x-admin-token": "admin-secret",
      },
    });
    expect(allowed.status).toBe(200);

    const body = await allowed.json();
    expect(body.command).toContain("https://install.example.test/install.ps1");

    const install = await app.request(body.installUrl);
    expect(await install.text()).toContain("https://install.example.test/d.ps1");

    const short = await app.request("/i");
    expect(short.status).toBe(200);
    const shortText = await short.text();
    expect(shortText).toContain("$env:VIBEMODE_SESSION_ID");
    expect(shortText).toContain("https://install.example.test/d.ps1");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
