import { expect, test } from "bun:test";
import { redactForLog } from "./redact";

test("redacts secrets but keeps diagnostic key names", () => {
  const clean = redactForLog({
    OPENAI_API_KEY: "real-key",
    message: "Authorization: Bearer abc123 and CODEX_KEY=secret",
    data: {
      auth_keys: ["auth_mode", "OPENAI_API_KEY"],
      nestedToken: "secret-token",
    },
  });

  expect(JSON.stringify(clean)).not.toContain("real-key");
  expect(JSON.stringify(clean)).not.toContain("abc123");
  expect(JSON.stringify(clean)).not.toContain("secret-token");
  expect(JSON.stringify(clean)).toContain("OPENAI_API_KEY");
  expect(JSON.stringify(clean)).toContain("auth_mode");
});
