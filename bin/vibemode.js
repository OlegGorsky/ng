#!/usr/bin/env node
'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');
const readline = require('readline');

const PROVIDER_NAME = 'vibemode';
const BASE_URL = 'https://api.vibemod.pro/v1';
const DEFAULT_MODEL = 'gpt-5.4';
const OPENAI_MODEL = 'gpt-5';
const DEFAULT_REASONING_EFFORT = 'medium';
const ENV_KEY = 'CODEX_KEY';
const OPENAI_ENV_KEY = 'OPENAI_API_KEY';
const CODEX_API_ENV_KEY = 'CODEX_API_KEY';
const AUTH_ENV_KEYS = [ENV_KEY, OPENAI_ENV_KEY, CODEX_API_ENV_KEY];
const SHELL_ENV_BEGIN = '# >>> vibemode codex >>>';
const SHELL_ENV_END = '# <<< vibemode codex <<<';

function usage() {
  console.log(`Vibemode Codex setup CLI

Usage:
  vibemode setup [--target all|local|cli|desktop] [--model MODEL] [--skip-api-check]
  vibemode status
  vibemode key set [KEY]
  vibemode key remove
  vibemode use vibemode [--model MODEL] [--skip-api-check]
  vibemode use openai
  vibemode remove
  vibemode run -- codex --yolo
  vibemode install-codex
  vibemode uninstall-codex --yes

Options:
  --non-interactive    Do not prompt for input.
  --replace-key        Ignore a saved key and read a new one.
  --skip-api-check     Do not call ${BASE_URL}/responses.
  --install-codex      Install @openai/codex during setup if missing.
  --skip-codex-install Do not offer Codex CLI installation.
  --no-shell           Do not write shell startup files.
  --yes                Confirm destructive or install actions.
  --target TARGET      local, cli, desktop, or all. All local targets share Codex config.

Environment:
  CODEX_KEY            Vibemode API key.
  OPENAI_API_KEY       OpenAI-compatible API key fallback.
  CODEX_API_KEY        Codex exec-compatible API key fallback.
  CODEX_HOME           Codex config directory. Default: ~/.codex.`);
}

function parseArgs(argv) {
  const result = { command: argv[0] || 'help', positionals: [], options: {}, runArgs: [] };
  const args = argv.slice(1);
  const dashDash = args.indexOf('--');
  const parsePart = result.command === 'run' && dashDash >= 0 ? args.slice(0, dashDash) : args;
  result.runArgs = result.command === 'run' && dashDash >= 0 ? args.slice(dashDash + 1) : [];

  for (let i = 0; i < parsePart.length; i += 1) {
    const arg = parsePart[i];
    if (arg === '-h' || arg === '--help') {
      result.options.help = true;
    } else if (arg.startsWith('--')) {
      const eq = arg.indexOf('=');
      const name = eq >= 0 ? arg.slice(2, eq) : arg.slice(2);
      const inlineValue = eq >= 0 ? arg.slice(eq + 1) : null;
      if (takesValue(name)) {
        const value = inlineValue !== null ? inlineValue : parsePart[++i];
        if (!value) {
          throw new Error(`--${name} requires a value`);
        }
        result.options[toCamel(name)] = value;
      } else {
        result.options[toCamel(name)] = inlineValue === null ? true : inlineValue;
      }
    } else {
      result.positionals.push(arg);
    }
  }

  if (result.command === 'run' && dashDash < 0 && result.positionals.length > 0) {
    result.runArgs = result.positionals;
    result.positionals = [];
  }

  return result;
}

function takesValue(name) {
  return ['target', 'model', 'key'].includes(name);
}

function toCamel(name) {
  return name.replace(/-([a-z])/g, (_, char) => char.toUpperCase());
}

function homeDir() {
  return process.env.HOME || process.env.USERPROFILE || os.homedir();
}

function codexDir() {
  return process.env.CODEX_HOME || path.join(homeDir(), '.codex');
}

function pathsForLocal() {
  const dir = codexDir();
  return {
    dir,
    config: path.join(dir, 'config.toml'),
    auth: path.join(dir, 'auth.json'),
    envFile: path.join(dir, 'vibemode.env'),
    desktopEnv: path.join(dir, '.env'),
    home: homeDir(),
  };
}

function ensureSupportedTarget(target) {
  const normalized = target || 'local';
  const supported = new Set(['all', 'local', 'cli', 'desktop']);
  if (!supported.has(normalized)) {
    throw new Error(`Unsupported target: ${target}. Use all, local, cli, or desktop.`);
  }
  return normalized;
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function chmodQuiet(file, mode) {
  try {
    fs.chmodSync(file, mode);
  } catch (_) {
    // Best effort on Windows and unusual filesystems.
  }
}

function timestamp() {
  const now = new Date();
  const pad = value => String(value).padStart(2, '0');
  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    '-',
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds()),
  ].join('');
}

function backupFile(file) {
  if (!fs.existsSync(file)) {
    return;
  }
  const backup = `${file}.bak-${timestamp()}`;
  fs.copyFileSync(file, backup);
  chmodQuiet(backup, 0o600);
  console.log(`backup: ${backup}`);
}

function writeIfChanged(file, content, mode) {
  mkdirp(path.dirname(file));
  const buffer = Buffer.from(content, 'utf8');
  if (fs.existsSync(file) && Buffer.compare(fs.readFileSync(file), buffer) === 0) {
    chmodQuiet(file, mode);
    return false;
  }

  backupFile(file);
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp-${process.pid}-${Date.now()}`);
  fs.writeFileSync(tmp, buffer, { mode });
  fs.renameSync(tmp, file);
  chmodQuiet(file, mode);
  return true;
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return '';
  }
}

function tomlEscape(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, '');
}

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function dotenvEscape(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, '')}"`;
}

function trimBlankEdges(lines) {
  const copy = lines.slice();
  while (copy.length && copy[0].trim() === '') {
    copy.shift();
  }
  while (copy.length && copy[copy.length - 1].trim() === '') {
    copy.pop();
  }
  return copy;
}

function cleanCodexConfig(existing) {
  const lines = existing.split(/\r?\n/);
  const kept = [];
  let inRoot = true;
  let skipTable = false;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    const header = line.match(/^\[(.+)]$/);
    if (header) {
      inRoot = false;
      const name = header[1].replace(/\s+/g, '');
      skipTable = (
        name === `model_providers.${PROVIDER_NAME}` ||
        name === `model_providers."${PROVIDER_NAME}"` ||
        name === 'model_providers."NeuroGateAPI"' ||
        name === 'model_providers.NeuroGateAPI' ||
        name === 'profiles.default'
      );
      if (skipTable) {
        continue;
      }
    }

    if (skipTable) {
      continue;
    }
    if (inRoot && /^(model|model_provider|model_reasoning_effort)\s*=/.test(line)) {
      continue;
    }
    if (/^wire_api\s*=/.test(line)) {
      continue;
    }
    kept.push(rawLine);
  }

  return trimBlankEdges(kept);
}

function buildVibemodeConfig(existing, model) {
  const escapedModel = tomlEscape(model || DEFAULT_MODEL);
  const escapedProvider = tomlEscape(PROVIDER_NAME);
  const escapedUrl = tomlEscape(BASE_URL);
  const escapedEffort = tomlEscape(DEFAULT_REASONING_EFFORT);
  const escapedEnvKey = tomlEscape(ENV_KEY);
  const kept = cleanCodexConfig(existing);
  const lines = [
    `model = "${escapedModel}"`,
    `model_provider = "${escapedProvider}"`,
  ];

  if (kept.length) {
    lines.push('', ...kept);
  }

  lines.push(
    '',
    `[model_providers.${escapedProvider}]`,
    `name = "${escapedProvider}"`,
    `base_url = "${escapedUrl}"`,
    `env_key = "${escapedEnvKey}"`,
    '',
    '[profiles.default]',
    `model = "${escapedModel}"`,
    `model_provider = "${escapedProvider}"`,
    `reasoning_effort = "${escapedEffort}"`,
    ''
  );
  return lines.join('\n');
}

function buildOpenAIConfig(existing) {
  const kept = cleanCodexConfig(existing);
  const lines = [
    `model = "${tomlEscape(OPENAI_MODEL)}"`,
    'model_provider = "openai"',
  ];

  if (kept.length) {
    lines.push('', ...kept);
  }

  lines.push(
    '',
    '[profiles.default]',
    `model = "${tomlEscape(OPENAI_MODEL)}"`,
    'model_provider = "openai"',
    `reasoning_effort = "${tomlEscape(DEFAULT_REASONING_EFFORT)}"`,
    ''
  );
  return lines.join('\n');
}

function parseJsonFile(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  } catch (_) {
    return {};
  }
}

function readAuthKey(paths) {
  const payload = parseJsonFile(paths.auth);
  for (const name of AUTH_ENV_KEYS) {
    const value = payload[name];
    if (typeof value === 'string' && value.trim()) {
      return value.trim();
    }
  }
  return '';
}

function writeAuthKey(paths, key) {
  const payload = parseJsonFile(paths.auth);
  payload.auth_mode = 'apikey';
  for (const name of AUTH_ENV_KEYS) {
    payload[name] = key;
  }
  writeIfChanged(paths.auth, `${JSON.stringify(payload, null, 2)}\n`, 0o600);
}

function removeAuthKey(paths) {
  if (!fs.existsSync(paths.auth)) {
    return;
  }
  const payload = parseJsonFile(paths.auth);
  for (const name of AUTH_ENV_KEYS) {
    delete payload[name];
  }
  writeIfChanged(paths.auth, `${JSON.stringify(payload, null, 2)}\n`, 0o600);
}

function writeShellEnv(paths, key) {
  const body = AUTH_ENV_KEYS.map(name => `export ${name}=${shellEscape(key)}`).join('\n');
  writeIfChanged(paths.envFile, `${body}\n`, 0o600);
}

function writeDesktopEnv(paths, key) {
  const body = AUTH_ENV_KEYS.map(name => `${name}=${dotenvEscape(key)}`).join('\n');
  writeIfChanged(paths.desktopEnv, `${body}\n`, 0o600);
}

function startupFiles(paths) {
  const files = [path.join(paths.home, '.profile')];
  const shellName = path.basename(process.env.SHELL || '');
  const bashrc = path.join(paths.home, '.bashrc');
  const zshrc = path.join(paths.home, '.zshrc');

  if (fs.existsSync(bashrc) || shellName === 'bash') {
    files.push(bashrc);
  }
  if (fs.existsSync(zshrc) || shellName === 'zsh') {
    files.push(zshrc);
  }
  return [...new Set(files)];
}

function stripStartupBlock(text) {
  const lines = text.split(/\r?\n/);
  const kept = [];
  let skip = false;
  for (const line of lines) {
    if (line === SHELL_ENV_BEGIN) {
      skip = true;
      continue;
    }
    if (line === SHELL_ENV_END) {
      skip = false;
      continue;
    }
    if (!skip) {
      kept.push(line);
    }
  }
  return trimBlankEdges(kept).join('\n');
}

function updateShellStartup(paths) {
  for (const file of startupFiles(paths)) {
    mkdirp(path.dirname(file));
    const current = readText(file);
    const stripped = stripStartupBlock(current);
    const prefix = stripped ? `${stripped}\n\n` : '';
    const source = shellEscape(paths.envFile);
    const next = `${prefix}${SHELL_ENV_BEGIN}\n[ -f ${source} ] && . ${source}\n${SHELL_ENV_END}\n`;
    writeIfChanged(file, next, fs.existsSync(file) ? fileMode(file) : 0o644);
  }
}

function removeShellStartup(paths) {
  for (const file of startupFiles(paths)) {
    if (!fs.existsSync(file)) {
      continue;
    }
    const current = readText(file);
    const stripped = stripStartupBlock(current);
    const next = stripped ? `${stripped}\n` : '';
    writeIfChanged(file, next, fileMode(file));
  }
}

function fileMode(file) {
  try {
    return fs.statSync(file).mode & 0o777;
  } catch (_) {
    return 0o644;
  }
}

function readEnvFileKey(paths) {
  const text = readText(paths.envFile);
  for (const name of AUTH_ENV_KEYS) {
    const match = text.match(new RegExp(`^export\\s+${name}=('(?:'\\\\''|[^'])*'|"[^"]*"|\\S+)`, 'm'));
    if (!match) {
      continue;
    }
    const raw = match[1];
    if (raw.startsWith("'") && raw.endsWith("'")) {
      return raw.slice(1, -1).replace(/'\\''/g, "'");
    }
    if (raw.startsWith('"') && raw.endsWith('"')) {
      return raw.slice(1, -1);
    }
    return raw;
  }
  return '';
}

function savedKey(paths) {
  return readAuthKey(paths) || readEnvFileKey(paths);
}

async function resolveApiKey(paths, options) {
  if (options.key) {
    return String(options.key).trim();
  }
  for (const name of AUTH_ENV_KEYS) {
    if (process.env[name] && process.env[name].trim()) {
      return process.env[name].trim();
    }
  }
  if (!options.replaceKey) {
    const existing = readAuthKey(paths);
    if (existing) {
      return existing;
    }
  }
  if (options.nonInteractive) {
    throw new Error(`API key not found. Pass ${ENV_KEY}=sk-... or run without --non-interactive.`);
  }
  return promptSecret('Paste Vibemode API key: ');
}

function promptSecret(label) {
  return new Promise((resolve, reject) => {
    const input = process.stdin;
    const output = process.stderr;

    if (!input.isTTY || !input.setRawMode) {
      const rl = readline.createInterface({ input, output });
      rl.question(label, answer => {
        rl.close();
        resolve(answer.trim());
      });
      return;
    }

    output.write(label);
    input.setRawMode(true);
    input.resume();
    input.setEncoding('utf8');
    let value = '';

    const cleanup = () => {
      input.setRawMode(false);
      input.pause();
      input.removeListener('data', onData);
      output.write('\n');
    };

    const onData = char => {
      if (char === '\u0003') {
        cleanup();
        reject(new Error('Cancelled'));
        return;
      }
      if (char === '\r' || char === '\n') {
        cleanup();
        resolve(value.trim());
        return;
      }
      if (char === '\u007f' || char === '\b') {
        if (value.length) {
          value = value.slice(0, -1);
          output.write('\b \b');
        }
        return;
      }
      value += char;
      output.write('*');
    };

    input.on('data', onData);
  });
}

function writeVibemodeLocal(paths, key, model, options) {
  ensureSupportedTarget(options.target);
  const current = readText(paths.config);
  writeIfChanged(paths.config, buildVibemodeConfig(current, model), 0o600);
  writeAuthKey(paths, key);
  writeDesktopEnv(paths, key);
  writeShellEnv(paths, key);
  if (!options.noShell) {
    updateShellStartup(paths);
  }
}

function writeOpenAILocal(paths) {
  const current = readText(paths.config);
  writeIfChanged(paths.config, buildOpenAIConfig(current), 0o600);
}

function removeVibemodeLocal(paths) {
  writeOpenAILocal(paths);
  removeAuthKey(paths);
  if (fs.existsSync(paths.envFile)) {
    backupFile(paths.envFile);
    fs.rmSync(paths.envFile, { force: true });
  }
  if (fs.existsSync(paths.desktopEnv)) {
    backupFile(paths.desktopEnv);
    fs.rmSync(paths.desktopEnv, { force: true });
  }
  removeShellStartup(paths);
}

function parseConfigValue(text, key) {
  const match = text.match(new RegExp(`^\\s*${key}\\s*=\\s*"([^"]*)"`, 'm'));
  return match ? match[1] : '';
}

function statusLocal(paths) {
  const config = readText(paths.config);
  const provider = parseConfigValue(config, 'model_provider') || 'unknown';
  const model = parseConfigValue(config, 'model') || 'unknown';
  const hasEnvKey = AUTH_ENV_KEYS.some(name => process.env[name] && process.env[name].trim());
  const keyState = savedKey(paths) ? 'saved' : (hasEnvKey ? 'env' : 'missing');

  console.log(`codex_dir: ${paths.dir}`);
  console.log(`config: ${fs.existsSync(paths.config) ? 'found' : 'missing'}`);
  console.log(`provider: ${provider}`);
  console.log(`model: ${model}`);
  console.log(`key: ${keyState}`);
  console.log(`env_file: ${fs.existsSync(paths.envFile) ? 'found' : 'missing'}`);
  console.log(`desktop_env: ${fs.existsSync(paths.desktopEnv) ? 'found' : 'missing'}`);
}

function sanitizeApiText(text, key) {
  let safe = String(text || '');
  if (key) {
    safe = safe.split(key).join('[redacted]');
  }
  return safe
    .replace(/[Bb][Ee][Aa][Rr][Ee][Rr]\s+[A-Za-z0-9._~+/=-]+/g, 'Bearer [redacted]')
    .replace(/sk-[A-Za-z0-9_*.-]{8,}/g, 'sk-[redacted]');
}

function checkApi(key, model) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${BASE_URL}/responses`);
    const payload = JSON.stringify({
      model: model || DEFAULT_MODEL,
      input: [{ role: 'user', content: 'ping' }],
      max_output_tokens: 1,
      stream: true,
    });
    const request = https.request(url, {
      method: 'POST',
      timeout: 60000,
      headers: {
        Authorization: `Bearer ${key}`,
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
    }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        body += chunk;
      });
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(`API check failed: HTTP ${response.statusCode} | ${sanitizeApiText(body, key).slice(0, 500)}`));
          return;
        }
        resolve();
      });
    });
    request.on('timeout', () => {
      request.destroy(new Error('API check timed out.'));
    });
    request.on('error', error => {
      reject(new Error(sanitizeApiText(error.message, key)));
    });
    request.end(payload);
  });
}

function commandExists(command) {
  const checker = process.platform === 'win32' ? 'where' : 'command';
  const args = process.platform === 'win32' ? [command] : ['-v', command];
  const result = childProcess.spawnSync(checker, args, {
    stdio: 'ignore',
    shell: process.platform !== 'win32',
  });
  return result.status === 0;
}

function npmCommand() {
  return process.platform === 'win32' ? 'npm.cmd' : 'npm';
}

function runChecked(command, args) {
  const result = childProcess.spawnSync(command, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} exited with ${result.status}`);
  }
}

async function maybeInstallCodex(options) {
  if (commandExists('codex')) {
    return;
  }
  if (options.skipCodexInstall) {
    return;
  }
  if (options.installCodex || options.yes) {
    runChecked(npmCommand(), ['install', '-g', '@openai/codex']);
    return;
  }
  if (options.nonInteractive) {
    console.log('Codex CLI not found. Install later with: vibemode install-codex');
    return;
  }
  const answer = await promptPlain('Codex CLI not found. Install @openai/codex globally now? [Y/n] ');
  if (!answer || /^y(es)?$/i.test(answer)) {
    runChecked(npmCommand(), ['install', '-g', '@openai/codex']);
  }
}

function promptPlain(label) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
    rl.question(label, answer => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function commandSetup(options) {
  ensureSupportedTarget(options.target || 'all');
  const paths = pathsForLocal();
  const key = await resolveApiKey(paths, options);
  if (!key) {
    throw new Error('API key is empty.');
  }

  await maybeInstallCodex(options);
  writeVibemodeLocal(paths, key, options.model || DEFAULT_MODEL, options);
  console.log(`codex_dir: ${paths.dir}`);
  console.log('provider: vibemode');
  console.log(`model: ${options.model || DEFAULT_MODEL}`);
  console.log('key: saved');

  if (options.skipApiCheck) {
    console.log('api_check: skipped');
  } else {
    await checkApi(key, options.model || DEFAULT_MODEL);
    console.log('api_check: ok');
  }
  console.log('run: vibemode run -- codex --yolo');
}

async function commandUse(positionals, options) {
  const mode = positionals[0];
  const paths = pathsForLocal();
  if (mode === 'openai') {
    ensureSupportedTarget(options.target || 'local');
    writeOpenAILocal(paths);
    console.log(`codex_dir: ${paths.dir}`);
    console.log('provider: openai');
    console.log(`model: ${OPENAI_MODEL}`);
    return;
  }
  if (mode === 'vibemode') {
    await commandSetup({ ...options, target: options.target || 'local', skipCodexInstall: true });
    return;
  }
  throw new Error('Usage: vibemode use vibemode|openai');
}

async function commandKey(positionals, options) {
  const action = positionals[0] || 'status';
  const paths = pathsForLocal();
  if (action === 'set') {
    const explicit = positionals[1];
    const key = explicit || await resolveApiKey(paths, { ...options, replaceKey: true });
    if (!key) {
      throw new Error('API key is empty.');
    }
    const trimmed = key.trim();
    writeAuthKey(paths, trimmed);
    writeDesktopEnv(paths, trimmed);
    writeShellEnv(paths, trimmed);
    if (!options.noShell) {
      updateShellStartup(paths);
    }
    console.log('key: saved');
    return;
  }
  if (action === 'remove') {
    removeAuthKey(paths);
    if (fs.existsSync(paths.envFile)) {
      backupFile(paths.envFile);
      fs.rmSync(paths.envFile, { force: true });
    }
    if (fs.existsSync(paths.desktopEnv)) {
      backupFile(paths.desktopEnv);
      fs.rmSync(paths.desktopEnv, { force: true });
    }
    removeShellStartup(paths);
    console.log('key: removed');
    return;
  }
  if (action === 'status') {
    console.log(`key: ${savedKey(paths) ? 'saved' : 'missing'}`);
    return;
  }
  throw new Error('Usage: vibemode key set [KEY] | key remove | key status');
}

function commandRun(runArgs) {
  if (!runArgs.length) {
    throw new Error('Usage: vibemode run -- codex --yolo');
  }
  const paths = pathsForLocal();
  const key = savedKey(paths) || AUTH_ENV_KEYS.map(name => (process.env[name] || '').trim()).find(Boolean);
  if (!key) {
    throw new Error(`Saved ${ENV_KEY} not found. Run: vibemode setup`);
  }

  const [command, ...args] = runArgs;
  const env = { ...process.env };
  for (const name of AUTH_ENV_KEYS) {
    env[name] = key;
  }
  const result = childProcess.spawnSync(command, args, {
    env,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (result.error) {
    throw result.error;
  }
  process.exit(result.status === null ? 1 : result.status);
}

async function commandRemove(options) {
  ensureSupportedTarget(options.target || 'local');
  const paths = pathsForLocal();
  removeVibemodeLocal(paths);
  console.log(`codex_dir: ${paths.dir}`);
  console.log('provider: openai');
  console.log('vibemode: removed');
}

async function commandUninstallCodex(options) {
  if (!options.yes && !options.nonInteractive) {
    const answer = await promptPlain('Uninstall @openai/codex globally? [y/N] ');
    if (!/^y(es)?$/i.test(answer)) {
      console.log('uninstall: cancelled');
      return;
    }
  }
  if (!options.yes && options.nonInteractive) {
    throw new Error('Pass --yes to uninstall in non-interactive mode.');
  }
  runChecked(npmCommand(), ['uninstall', '-g', '@openai/codex']);
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.options.help || parsed.command === 'help' || parsed.command === '--help' || parsed.command === '-h') {
    usage();
    return;
  }

  switch (parsed.command) {
    case 'setup':
      await commandSetup(parsed.options);
      break;
    case 'status':
      ensureSupportedTarget(parsed.options.target || 'local');
      statusLocal(pathsForLocal());
      break;
    case 'key':
      await commandKey(parsed.positionals, parsed.options);
      break;
    case 'use':
      await commandUse(parsed.positionals, parsed.options);
      break;
    case 'remove':
      await commandRemove(parsed.options);
      break;
    case 'run':
      commandRun(parsed.runArgs);
      break;
    case 'install-codex':
      runChecked(npmCommand(), ['install', '-g', '@openai/codex']);
      break;
    case 'uninstall-codex':
      await commandUninstallCodex(parsed.options);
      break;
    default:
      throw new Error(`Unknown command: ${parsed.command}`);
  }
}

main().catch(error => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
