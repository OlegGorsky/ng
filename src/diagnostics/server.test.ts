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

    const page = await app.request("/");
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("$u=&#39;https://install.example.test/install.ps1?sid=");
    expect(html).toContain("curl -fsSL &#39;https://install.example.test/linux.sh?sid=");
    expect(html).toContain("curl -fsSL &#39;https://install.example.test/termux.sh?sid=");
    expect(html).toContain("/events?token=");

    const install = await app.request(body.installUrl);
    const installText = await install.text();
    expect(installText).toContain("https://install.example.test/setup.ps1");
    expect(installText).not.toContain("https://install.example.test/d.ps1");

    const linux = await app.request(`/linux.sh?sid=${body.id}&token=${body.token}`);
    expect(linux.status).toBe(200);
    const linuxText = await linux.text();
    expect(linuxText).toContain("VIBEMODE_SESSION_ID");
    expect(linuxText).toContain("https://install.example.test/setup-desktop.sh");
    expect(linuxText).toContain("bootstrap_failed");

    const termux = await app.request(`/termux.sh?sid=${body.id}&token=${body.token}`);
    expect(termux.status).toBe(200);
    const termuxText = await termux.text();
    expect(termuxText).toContain("VIBEMODE_SESSION_ID");
    expect(termuxText).toContain("https://install.example.test/setup-termux.sh");
    expect(termuxText).toContain("bootstrap_failed");

    const tokenEvents = await app.request(`/api/sessions/${body.id}/events?token=${body.token}`);
    expect(tokenEvents.status).toBe(200);

    const short = await app.request("/i");
    expect(short.status).toBe(200);
    const shortText = await short.text();
    expect(shortText).toContain("$env:VIBEMODE_SESSION_ID");
    expect(shortText).toContain(
      "https://raw.githubusercontent.com/OlegGorsky/w/e7c6e219e8996b9568d117c0a13293efbca0baa8/Setup-CodexWindows.ps1",
    );
    expect(shortText).toContain("-RepairStorePolicies");
    expect(shortText).toContain("Running full Codex Windows setup");
    expect(shortText).toContain("codex_windows_setup_log_tail");
    expect(shortText).toContain('Send-CodexSetupLogTail "info"');
    expect(shortText).not.toContain("$env:VIBEMODE_CODEX_ONLY");
    expect(shortText).not.toContain("Вставь vibemode key");
    expect(shortText).not.toContain("https://install.example.test/d.ps1");

    const setupScript = await app.request("/setup.ps1");
    expect(setupScript.status).toBe(200);
    expect(await setupScript.text()).toContain("Vibemode Windows setup");

    const imageHelper = await app.request("/responses-image.py");
    expect(imageHelper.status).toBe(200);
    expect(await imageHelper.text()).toContain("Responses API image_generation");

    const desktopSetup = await app.request("/setup-desktop.sh");
    expect(desktopSetup.status).toBe(200);
    expect(await desktopSetup.text()).toContain("Codex Desktop");

    const termuxSetup = await app.request("/setup-termux.sh");
    expect(termuxSetup.status).toBe(200);
    expect(await termuxSetup.text()).toContain("Termux");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
