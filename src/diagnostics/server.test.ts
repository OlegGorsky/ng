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
    const installText = await install.text();
    expect(installText).toContain("https://install.example.test/setup.ps1");
    expect(installText).not.toContain("https://install.example.test/d.ps1");

    const short = await app.request("/i");
    expect(short.status).toBe(200);
    const shortText = await short.text();
    expect(shortText).toContain("$env:VIBEMODE_SESSION_ID");
    expect(shortText).toContain("$env:VIBEMODE_CODEX_DESKTOP_SETUP_URL");
    expect(shortText).toContain("https://install.example.test/setup.ps1");
    expect(shortText).toContain("https://install.example.test/responses-image.py");
    expect(shortText).toContain("Starting Vibemode Windows bootstrap");
    expect(shortText).not.toContain("https://install.example.test/d.ps1");

    const setupScript = await app.request("/setup.ps1");
    expect(setupScript.status).toBe(200);
    expect(await setupScript.text()).toContain("Vibemode Windows setup");

    const imageHelper = await app.request("/responses-image.py");
    expect(imageHelper.status).toBe(200);
    expect(await imageHelper.text()).toContain("Responses API image_generation");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
