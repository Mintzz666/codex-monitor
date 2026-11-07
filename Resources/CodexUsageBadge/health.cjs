'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SUPPORT = path.join(os.homedir(), 'Library/Application Support/CodexUsageBadge');
const CHATGPT_APP = process.env.CODEX_BADGE_APP || '/Applications/ChatGPT.app';
process.env.CODEX_BADGE_APP = CHATGPT_APP;
const EXPECTED_BADGE_SHA256 = 'd6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db';
const UI_BADGE_VERSION = 46;
const PROJECT_COLORS_VERSION = 5;
const THREAD_TOKENS_VERSION = 12;

function sha256(file) {
  try {
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  } catch {
    return null;
  }
}

function bundleManifest() {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  } catch {
    return null;
  }
}

function bundledFilesMatch(manifest) {
  if (!manifest || !manifest.files || typeof manifest.files !== 'object') return false;
  for (const [relative, expected] of Object.entries(manifest.files)) {
    const candidate = path.resolve(__dirname, relative);
    if (!candidate.startsWith(`${__dirname}${path.sep}`) || sha256(candidate) !== expected) return false;
  }
  return true;
}

function installedPathFor(relative) {
  if (relative.startsWith('macos/startup/')) {
    return path.join(SUPPORT, 'startup-helper', relative.slice('macos/startup/'.length));
  }
  return path.join(SUPPORT, relative);
}

function installedRuntimeMatches(manifest) {
  if (!manifest || !Array.isArray(manifest.runtimeFiles)) return false;
  return manifest.runtimeFiles.every(relative => {
    const expected = manifest.files?.[relative];
    return typeof expected === 'string' && sha256(installedPathFor(relative)) === expected;
  });
}

function commandSucceeded(file, args) {
  try {
    execFileSync(file, args, { stdio: 'ignore', timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

function launchAgentRunning(label) {
  try {
    const output = execFileSync('/bin/launchctl', ['print', `gui/${process.getuid()}/${label}`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000
    });
    return /state = running/.test(output);
  } catch {
    return false;
  }
}

function mainWindowTargets(targets, agent) {
  if (!Array.isArray(targets)) return [];
  return targets.filter(target => target?.type === 'page'
    && typeof target.webSocketDebuggerUrl === 'string'
    && agent.isMainWindow(target));
}

async function readUIStatus(target) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  try {
    return await new Promise(resolve => {
      let settled = false;
      const timer = setTimeout(() => finish(null), 3500);
      const finish = value => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { socket.close(); } catch {}
        resolve(value);
      };
      socket.addEventListener('open', () => {
        socket.send(JSON.stringify({
          id: 1,
          method: 'Runtime.evaluate',
          params: {
            returnByValue: true,
            expression: `(() => {
              const badge = window.__codexUsageBadge?.status?.() ?? null;
              const colors = window.__codexProjectColors?.status?.() ?? null;
              const tokens = window.__codexThreadTokens?.status?.() ?? null;
              return {
                badgeReady: !!badge && badge.placed === true && badge.badgeCount === 1 && badge.version === ${UI_BADGE_VERSION} && badge.stale === false,
                projectColorsVersion: Number.isInteger(colors?.version) ? colors.version : null,
                threadTokensVersion: Number.isInteger(tokens?.version) ? tokens.version : null
              };
            })()`
          }
        }));
      });
      socket.addEventListener('error', () => finish(null));
      socket.addEventListener('message', event => {
        try {
          const message = JSON.parse(String(event.data));
          if (message.id !== 1) return;
          finish(message.result?.exceptionDetails ? null : message.result?.result?.value ?? null);
        } catch {
          finish(null);
        }
      });
    });
  } catch {
    try { socket.close(); } catch {}
    return null;
  }
}

function checkMonitor() {
  const app = '/Applications/Codex Monitor.app';
  const info = path.join(app, 'Contents/Info.plist');
  let version = null;
  let build = null;
  try {
    version = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', info], { encoding: 'utf8' }).trim();
    build = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleVersion', info], { encoding: 'utf8' }).trim();
  } catch {}
  return {
    installed: fs.existsSync(info),
    running: process.env.CODEX_MONITOR_HEALTH_CALLER === 'running-app'
      || commandSucceeded('/usr/bin/pgrep', ['-x', 'Codex Monitor']),
    signatureValid: fs.existsSync(info) && commandSucceeded('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]),
    version,
    build
  };
}

function assessHealth(data) {
  const errors = [];
  if (!data.monitor.installed || !data.monitor.running) errors.push('monitor_not_running');
  if (!data.monitor.signatureValid) errors.push('monitor_signature_invalid');
  if (!data.badgeBundleHashValid) errors.push('bundle_hash_mismatch');
  if (!data.badgeActiveHashValid) errors.push('active_hash_mismatch');
  if (!data.badgeManagerHashValid || !data.badgeActiveFilesValid) errors.push('active_manager_or_files_mismatch');
  if (!data.quotaSnapshotFresh) errors.push('quota_snapshot_unavailable_or_stale');
  if (!data.badgeAgentRunning) errors.push('badge_agent_not_running');
  if (!data.badgeStartupAgentRunning) errors.push('badge_startup_agent_not_running');
  if (!data.chatGPTInstalled) errors.push('chatgpt_app_missing');
  if (!data.cdpReachable) errors.push('chatgpt_debug_port_unreachable');
  else if (data.mainWindowCount === 0) errors.push('chatgpt_main_window_unavailable');
  else if (data.injectedWindowCount === 0) errors.push('badge_ui_not_confirmed');
  return { overall: errors.length === 0 ? 'healthy' : 'attention', errors };
}

async function collectHealth() {
  const bundleAgent = path.join(__dirname, 'agent.cjs');
  const activeAgent = path.join(SUPPORT, 'agent.cjs');
  const manifest = bundleManifest();
  const bundleHash = sha256(bundleAgent);
  const activeHash = sha256(activeAgent);
  const badgeBundleHashValid = bundleHash === EXPECTED_BADGE_SHA256 && bundledFilesMatch(manifest);
  const badgeManagerHashValid = sha256(path.join(SUPPORT, 'manage.cjs')) === manifest?.files?.['manage.cjs'];
  const badgeActiveFilesValid = installedRuntimeMatches(manifest);
  let snapshotFresh = false;
  try {
    await require('./shared-quota.cjs').readSharedQuota();
    snapshotFresh = true;
  } catch {}

  let targets = [];
  let cdpReachable = false;
  try {
    const response = await fetch('http://127.0.0.1:39222/json/list', { signal: AbortSignal.timeout(2000) });
    cdpReachable = response.ok;
    if (response.ok) targets = await response.json();
  } catch {}
  const pages = mainWindowTargets(targets, require('./agent.cjs'));
  const uiStatuses = await Promise.all(pages.map(readUIStatus));
  const injectedWindowCount = uiStatuses.filter(status => status
    && status.badgeReady
    && status.projectColorsVersion === PROJECT_COLORS_VERSION
    && status.threadTokensVersion === THREAD_TOKENS_VERSION).length;
  const chatGPTInstalled = fs.existsSync(path.join(CHATGPT_APP, 'Contents/Info.plist'));
  const bundleHashValid = badgeBundleHashValid;
  const activeHashValid = activeHash === EXPECTED_BADGE_SHA256;
  const badgeAgentRunning = launchAgentRunning('com.codexusagebadge.agent');
  const badgeStartupAgentRunning = launchAgentRunning('com.codexusagebadge.startup');
  const monitor = checkMonitor();

  const assessment = assessHealth({
    monitor,
    quotaSnapshotFresh: snapshotFresh,
    badgeBundleHashValid: bundleHashValid,
    badgeActiveHashValid: activeHashValid,
    badgeManagerHashValid,
    badgeActiveFilesValid,
    badgeAgentRunning,
    badgeStartupAgentRunning,
    chatGPTInstalled,
    cdpReachable,
    mainWindowCount: pages.length,
    injectedWindowCount
  });
  return {
    checkedAt: new Date().toISOString(),
    overall: assessment.overall,
    monitor,
    quotaSnapshotFresh: snapshotFresh,
    badgeBundleHashValid: bundleHashValid,
    badgeActiveHashValid: activeHashValid,
    badgeManagerHashValid,
    badgeActiveFilesValid,
    badgeAgentRunning,
    badgeStartupAgentRunning,
    chatGPTInstalled,
    cdpReachable,
    mainWindowCount: pages.length,
    injectedWindowCount,
    projectColorsVersion: PROJECT_COLORS_VERSION,
    threadTokensVersion: THREAD_TOKENS_VERSION,
    errors: assessment.errors
  };
}

function sanitizedError(error) {
  return String(error?.message || error || 'operation_failed')
    .replaceAll(os.homedir(), '~')
    .replace(/[\r\n\t]+/g, ' ')
    .slice(0, 240);
}

function backupInstalledBadge() {
  if (!fs.existsSync(SUPPORT)) return null;
  const backupRoot = path.join(os.homedir(), 'Library/Application Support/Codex Monitor Backups');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const destination = path.join(backupRoot, `Badge-before-update-${stamp}`);
  fs.mkdirSync(destination, { recursive: true, mode: 0o700 });
  const selected = [
    'agent.cjs', 'manage.cjs', 'network-agent.cjs', 'shared-quota.cjs', 'macos',
    'startup-helper/bridge', 'startup-helper/controller.cjs', 'startup-helper/watch.cjs',
    'local-customization/project-thread-color'
  ];
  const files = [];
  for (const relative of selected) {
    const source = path.join(SUPPORT, relative);
    if (!fs.existsSync(source)) continue;
    const stat = fs.lstatSync(source);
    if (stat.isSymbolicLink()) throw new Error(`Refusing to archive a symbolic link: ${relative}`);
    const target = path.join(destination, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    fs.cpSync(source, target, { recursive: true, preserveTimestamps: true, errorOnExist: true });
    if (stat.isFile()) files.push({ path: relative, sha256: sha256(source) });
    else {
      for (const entry of fs.readdirSync(source, { recursive: true, withFileTypes: true })) {
        if (!entry.isFile()) continue;
        const file = path.join(entry.parentPath || source, entry.name);
        files.push({ path: path.relative(SUPPORT, file), sha256: sha256(file) });
      }
    }
  }
  fs.writeFileSync(path.join(destination, 'backup-manifest.json'), JSON.stringify({ createdAt: new Date().toISOString(), files }, null, 2) + '\n', { mode: 0o600 });
  return destination;
}

async function installOrRepair() {
  if (sha256(path.join(__dirname, 'agent.cjs')) !== EXPECTED_BADGE_SHA256) {
    throw new Error('Packaged optimized Badge hash does not match the pinned build. No files were changed.');
  }
  const backupPath = backupInstalledBadge();
  const messages = [];
  const originalLog = console.log;
  const originalWarn = console.warn;
  console.log = (...values) => messages.push(values.join(' '));
  console.warn = (...values) => messages.push(values.join(' '));
  try {
    await require('./manage.cjs').install();
  } finally {
    console.log = originalLog;
    console.warn = originalWarn;
  }
  const report = await collectHealth();
  return {
    ...report,
    operation: 'install_or_repair',
    operationSucceeded: true,
    backupPath: backupPath ? path.basename(backupPath) : null,
    operationMessage: messages.length ? 'Badge files staged and background services refreshed.' : 'Badge services refreshed.'
  };
}

async function main() {
  const action = process.argv[2] || 'health';
  if (action === 'health') return collectHealth();
  if (action === 'install') return installOrRepair();
  throw new Error('Supported actions: health, install');
}

if (require.main === module) {
  main().then(result => process.stdout.write(JSON.stringify(result) + '\n')).catch(error => {
    process.stdout.write(JSON.stringify({
      checkedAt: new Date().toISOString(),
      overall: 'attention',
      operationSucceeded: false,
      error: sanitizedError(error)
    }) + '\n');
    process.exitCode = 1;
  });
}

module.exports = { EXPECTED_BADGE_SHA256, assessHealth };
