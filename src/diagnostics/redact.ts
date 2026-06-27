const SECRET_KEY_RE = /(api[_-]?key|token|secret|password|authorization|credential)/i;
const ALLOWED_KEY_LIST_RE = /^(auth_keys|env_keys|config_keys|key_names)$/i;

export function redactText(value: string): string {
  return value
    .replace(/Bearer\s+[^\s"',;]+/gi, "Bearer [redacted]")
    .replace(/sk-[A-Za-z0-9_*.-]{8,}/g, "sk-[redacted]")
    .replace(/\b(CODEX_KEY|OPENAI_API_KEY|CODEX_API_KEY)\s*[:=]\s*("[^"]+"|'[^']+'|[^\s,;]+)/gi, "$1=[redacted]");
}

export function redactForLog(value: unknown): unknown {
  if (typeof value === "string") {
    return redactText(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => redactForLog(item));
  }
  if (!value || typeof value !== "object") {
    return value;
  }

  const output: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (SECRET_KEY_RE.test(key) && !ALLOWED_KEY_LIST_RE.test(key)) {
      output[key] = "[redacted]";
    } else {
      output[key] = redactForLog(entry);
    }
  }
  return output;
}
