'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const agent = require('./agent.cjs');

const PATCH = Symbol.for('codex-usage-badge.shared-quota-adapter');
const DEFAULT_PORTS = [51872, 51873, 51874];
const MAX_PAYLOAD_BYTES = 64 * 1024;
const PORT_TIMEOUT_MS = 750;
const COCOA_EPOCH_OFFSET_SECONDS = 978307200;

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function fingerprintForIdentity(canonicalCodexHome, accountId) {
  if (!nonEmptyString(canonicalCodexHome) || !nonEmptyString(accountId)) return null;
  return crypto.createHash('sha256')
    .update('codex-quota-v1\0' + canonicalCodexHome + '\0' + accountId.trim(), 'utf8')
    .digest('hex');
}

function expandCodexHome(value, homeDirectory) {
  const raw = String(value ?? '');
  if (raw === '~') return homeDirectory;
  if (raw.startsWith('~' + path.sep)) return path.join(homeDirectory, raw.slice(2));
  return path.resolve(raw);
}

function readCurrentIdentity(environment = process.env, homeDirectory = os.homedir()) {
  const configuredHome = nonEmptyString(environment.CODEX_HOME)
    ? environment.CODEX_HOME
    : path.join(homeDirectory, '.codex');

  let canonicalCodexHome;
  try {
    canonicalCodexHome = fs.realpathSync.native(expandCodexHome(configuredHome, homeDirectory));
  } catch {
    return null;
  }

  let auth;
  try {
    const authPath = path.join(canonicalCodexHome, 'auth.json');
    auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
  } catch {
    return null;
  }

  if (!isRecord(auth) || auth.auth_mode !== 'chatgpt') return null;
  const accountId = nonEmptyString(auth.tokens?.account_id)
    ? auth.tokens.account_id.trim()
    : (nonEmptyString(auth.account_id) ? auth.account_id.trim() : null);
  if (!nonEmptyString(accountId)) return null;

  return { canonicalCodexHome, accountId };
}

function currentFingerprint(options = {}) {
  let identity;
  try {
    identity = typeof options.resolveIdentity === 'function'
      ? options.resolveIdentity()
      : readCurrentIdentity(options.environment ?? process.env, options.homeDirectory ?? os.homedir());
  } catch {
    return null;
  }
  return fingerprintForIdentityRecord(identity);
}

function fingerprintForIdentityRecord(identity) {
  if (!isRecord(identity)) return null;
  return fingerprintForIdentity(identity.canonicalCodexHome, identity.accountId);
}

function codexSnapshotFromResponse(response) {
  if (!isRecord(response)) return null;

  if (isRecord(response.rateLimitsByLimitId) && Object.hasOwn(response.rateLimitsByLimitId, 'codex')) {
    const keyed = response.rateLimitsByLimitId.codex;
    return isRecord(keyed) && (keyed.limitId == null || keyed.limitId === 'codex') ? keyed : null;
  }

  if (Object.hasOwn(response, 'rateLimits')) {
    const snapshot = response.rateLimits;
    return isRecord(snapshot) && (snapshot.limitId == null || snapshot.limitId === 'codex')
      ? snapshot
      : null;
  }

  return isRecord(response) && (response.limitId == null || response.limitId === 'codex')
    ? response
    : null;
}

function hasRealCodexWindow(response) {
  const snapshot = codexSnapshotFromResponse(response);
  if (!snapshot) return false;
  return ['primary', 'secondary'].some(key => {
    const window = snapshot[key];
    return isRecord(window)
      && Number.isFinite(window.usedPercent)
      && Number.isFinite(window.windowDurationMins)
      && window.windowDurationMins > 0;
  });
}

function collectRawAccountIds(value, output = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectRawAccountIds(item, output);
  } else if (isRecord(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (/^account_?id$/i.test(key)) output.push(child);
      collectRawAccountIds(child, output);
    }
  }
  return output;
}

function stripPrivateIdentityFields(value) {
  if (Array.isArray(value)) return value.map(stripPrivateIdentityFields);
  if (!isRecord(value)) return value;
  const clean = {};
  for (const [key, child] of Object.entries(value)) {
    if (/^(?:account_?id|tokens)$/i.test(key)) continue;
    clean[key] = stripPrivateIdentityFields(child);
  }
  return clean;
}

function readPortPayload(port, options = {}) {
  const timeoutMs = Number.isFinite(options.timeoutMs) ? Math.max(1, options.timeoutMs) : PORT_TIMEOUT_MS;
  return new Promise(resolve => {
    let socket;
    let timer = null;
    let settled = false;
    const chunks = [];
    let byteLength = 0;

    const finish = value => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      if (socket) {
        socket.removeAllListeners();
        socket.destroy();
      }
      resolve(value);
    };

    try {
      socket = net.createConnection({ host: '127.0.0.1', port });
    } catch {
      finish(null);
      return;
    }

    timer = setTimeout(() => finish(null), timeoutMs);
    socket.on('data', chunk => {
      byteLength += chunk.length;
      if (byteLength > MAX_PAYLOAD_BYTES) {
        finish(null);
        return;
      }
      chunks.push(chunk);
    });
    socket.on('end', () => {
      if (byteLength === 0) {
        finish(null);
        return;
      }
      try {
        finish(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, byteLength)));
      } catch {
        finish(null);
      }
    });
    socket.on('error', () => finish(null));
    socket.on('close', () => finish(null));
  });
}

function payloadSnapshot(payload) {
  if (!isRecord(payload)) return null;
  if (Object.hasOwn(payload, 'snapshot')) {
    if (!isRecord(payload.snapshot)) return null;
    return { ...payload, ...payload.snapshot };
  }
  return payload;
}

function validatePayload(text, identity, nowMilliseconds = Date.now()) {
  if (typeof text !== 'string' || Buffer.byteLength(text, 'utf8') > MAX_PAYLOAD_BYTES) return null;

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }

  const snapshot = payloadSnapshot(parsed);
  if (!snapshot || snapshot.quotaSourceVersion !== 1) return null;
  if (!identity || !nonEmptyString(identity.accountId)) return null;

  const expectedFingerprint = fingerprintForIdentity(identity.canonicalCodexHome, identity.accountId);
  if (!expectedFingerprint || snapshot.accountFingerprint !== expectedFingerprint) return null;

  if (typeof snapshot.updatedAt !== 'number' || !Number.isFinite(snapshot.updatedAt)) return null;
  const updatedAtUnixSeconds = snapshot.updatedAt + COCOA_EPOCH_OFFSET_SECONDS;
  const ageSeconds = nowMilliseconds / 1000 - updatedAtUnixSeconds;
  if (ageSeconds < -5 || ageSeconds > 150) return null;

  if (typeof snapshot.rateLimitsJSON !== 'string') return null;
  let response;
  try {
    response = JSON.parse(snapshot.rateLimitsJSON);
  } catch {
    return null;
  }
  if (!isRecord(response) || !hasRealCodexWindow(response)) return null;

  const rawAccountIds = collectRawAccountIds(response);
  if (rawAccountIds.some(value => typeof value !== 'string' || value.trim() !== identity.accountId)) return null;

  return stripPrivateIdentityFields(response);
}

async function readSharedQuota(options = {}) {
  const identityResolver = typeof options.resolveIdentity === 'function'
    ? options.resolveIdentity
    : () => readCurrentIdentity(options.environment ?? process.env, options.homeDirectory ?? os.homedir());

  const resolveIdentityState = () => {
    let candidate;
    try {
      candidate = identityResolver();
    } catch {
      return null;
    }
    if (!isRecord(candidate)) return null;
    const identity = {
      canonicalCodexHome: candidate.canonicalCodexHome,
      accountId: typeof candidate.accountId === 'string' ? candidate.accountId.trim() : candidate.accountId
    };
    const fingerprint = fingerprintForIdentityRecord(identity);
    return fingerprint ? { identity, fingerprint } : null;
  };

  const initial = resolveIdentityState();
  if (!initial) throw new Error('Current Codex account identity is unavailable');

  const ensureSameIdentity = () => {
    const current = resolveIdentityState();
    if (!current || current.fingerprint !== initial.fingerprint) {
      throw new Error('Current Codex account identity changed during shared quota read');
    }
  };

  const ports = Array.isArray(options.ports) ? options.ports : DEFAULT_PORTS;
  for (const port of ports) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) continue;
    const text = await readPortPayload(port, { timeoutMs: options.timeoutMs });
    if (text === null) continue;
    ensureSameIdentity();
    const now = typeof options.now === 'function' ? options.now() : Date.now();
    const response = validatePayload(text, initial.identity, now);
    if (response) {
      ensureSameIdentity();
      return response;
    }
  }
  throw new Error('No fresh, valid Monitor quota snapshot is available');
}

function installSharedQuotaAdapter(AppServerClient, options = {}) {
  const prototype = AppServerClient?.prototype;
  if (!prototype) throw new TypeError('AppServerClient must be a class with a prototype');
  if (prototype[PATCH]) return prototype[PATCH].uninstall;

  const originals = {
    start: prototype.start,
    refresh: prototype.refresh,
    stop: prototype.stop
  };
  if (Object.values(originals).some(method => typeof method !== 'function')) {
    throw new TypeError('AppServerClient start, refresh, and stop methods are required');
  }

  const mergeRateLimitsResponse = options.mergeRateLimitsResponse ?? agent.mergeRateLimitsResponse;
  const states = new WeakMap();

  function stateFor(client) {
    let state = states.get(client);
    if (!state) {
      state = { inFlight: null, generation: 0 };
      states.set(client, state);
    }
    return state;
  }

  function refreshFromSharedSource() {
    const client = this;
    const state = stateFor(client);
    if (state.inFlight) return state.inFlight;

    const generation = state.generation;
    const inFlight = Promise.resolve().then(() => readSharedQuota(options)).then(response => {
      if (state.generation !== generation) throw new Error('Shared quota read was stopped');
      const merged = mergeRateLimitsResponse(null, response);
      if (!isRecord(merged) || !hasRealCodexWindow(merged)) {
        throw new Error('No fresh, valid Monitor quota snapshot is available');
      }
      client.child = null;
      client.rateLimits = merged;
      client.emit('rate-limits', client.rateLimits);
      return client.rateLimits;
    }).catch(error => {
      if (state.generation === generation) client.rateLimits = null;
      throw error;
    }).finally(() => {
      if (state.generation === generation && state.inFlight === inFlight) state.inFlight = null;
    });
    state.inFlight = inFlight;
    return inFlight;
  }

  function sharedStart() {
    this.child = null;
    return refreshFromSharedSource.call(this);
  }

  function sharedRefresh() {
    this.child = null;
    return refreshFromSharedSource.call(this);
  }

  function sharedStop(...args) {
    const state = states.get(this);
    if (state) {
      state.generation += 1;
      state.inFlight = null;
    }
    this.child = null;
    this.rateLimits = null;
    return originals.stop.apply(this, args);
  }

  Object.defineProperties(prototype, {
    start: { value: sharedStart, configurable: true, writable: true },
    refresh: { value: sharedRefresh, configurable: true, writable: true },
    stop: { value: sharedStop, configurable: true, writable: true }
  });

  const patch = {
    uninstall() {
      if (prototype.start !== sharedStart) return;
      Object.defineProperties(prototype, {
        start: { value: originals.start, configurable: true, writable: true },
        refresh: { value: originals.refresh, configurable: true, writable: true },
        stop: { value: originals.stop, configurable: true, writable: true }
      });
      delete prototype[PATCH];
    }
  };
  Object.defineProperty(prototype, PATCH, { value: patch, configurable: true });
  return patch.uninstall;
}

module.exports = {
  DEFAULT_PORTS,
  MAX_PAYLOAD_BYTES,
  PORT_TIMEOUT_MS,
  currentFingerprint,
  fingerprintForIdentity,
  hasRealCodexWindow,
  installSharedQuotaAdapter,
  readSharedQuota,
  validatePayload
};
