#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');
const agent = require('./agent.cjs');
const { installSharedQuotaAdapter } = require('./shared-quota.cjs');

const PATCH = Symbol.for('codex-usage-badge.network-adapter');
const MIN_RPC_TIMEOUT_MS = 20_000;
const LOOPBACK_EXCEPTIONS = ['localhost', '127.0.0.1', '::1', '[::1]'];
const PROXY_KEYS = [
  'HTTP_PROXY', 'http_proxy',
  'HTTPS_PROXY', 'https_proxy',
  'ALL_PROXY', 'all_proxy',
  'SOCKS_PROXY', 'socks_proxy',
  'NO_PROXY', 'no_proxy'
];

function enabled(value) {
  return value === true || value === 1 || value === '1' || String(value).toLowerCase() === 'true';
}

function proxyURL(scheme, host, port) {
  const numericPort = Number(port);
  if (!host || !Number.isInteger(numericPort) || numericPort < 1 || numericPort > 65_535) return null;
  const rawHost = String(host).trim();
  if (!rawHost || /[\s\u0000-\u001f\u007f/@?#]/.test(rawHost)) return null;
  if ((rawHost.startsWith('[') && !rawHost.endsWith(']')) || (!rawHost.startsWith('[') && rawHost.includes(']'))) return null;
  const safeHost = rawHost.includes(':') && !rawHost.startsWith('[') ? `[${rawHost}]` : rawHost;
  return `${scheme}://${safeHost}:${numericPort}`;
}

function parseScutilProxyOutput(output) {
  const values = Object.create(null);
  const exceptions = [];
  let readingExceptions = false;

  for (const rawLine of String(output ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (readingExceptions) {
      if (line === '}') {
        readingExceptions = false;
        continue;
      }
      const item = line.match(/^\d+\s*:\s*(.*?)\s*$/);
      const value = item?.[1]
        ?.replace(/^<string>\s*/i, '')
        .replace(/\s*<\/string>$/i, '')
        .trim();
      if (value) exceptions.push(value);
      continue;
    }

    const pair = line.match(/^([A-Za-z][A-Za-z0-9]*)\s*:\s*(.*)$/);
    if (!pair) continue;
    const [, key, rawValue] = pair;
    if (key === 'ExceptionsList' && /<array>\s*\{/.test(rawValue)) {
      readingExceptions = true;
      continue;
    }
    values[key] = rawValue.replace(/\s+$/, '');
  }

  const http = enabled(values.HTTPEnable)
    ? proxyURL('http', values.HTTPProxy, values.HTTPPort)
    : null;
  const https = enabled(values.HTTPSEnable)
    ? proxyURL('http', values.HTTPSProxy, values.HTTPSPort)
    : null;
  const socks = enabled(values.SOCKSEnable)
    ? proxyURL('socks5h', values.SOCKSProxy, values.SOCKSPort)
    : null;

  return {
    http,
    https,
    socks,
    exceptions,
    excludeSimpleHostnames: enabled(values.ExcludeSimpleHostnames)
  };
}

function resolveSystemProxy() {
  if (process.platform !== 'darwin') return {};
  try {
    const output = execFileSync('/usr/sbin/scutil', ['--proxy'], {
      encoding: 'utf8',
      timeout: 1000,
      stdio: ['ignore', 'pipe', 'ignore']
    });
    return parseScutilProxyOutput(output);
  } catch {
    return {};
  }
}

function firstExplicit(environment, upperName) {
  const lowerName = upperName.toLowerCase();
  const lower = environment[lowerName];
  if (typeof lower === 'string' && lower.trim()) return lower.trim();
  const upper = environment[upperName];
  if (typeof upper === 'string' && upper.trim()) return upper.trim();
  return null;
}

function normalizeSystemException(value) {
  const exception = String(value ?? '').trim();
  if (!exception || exception === '<local>') return null;
  return exception.startsWith('*.') ? `.${exception.slice(2)}` : exception;
}

function addUnique(target, values) {
  const seen = new Set(target.map(value => value.toLowerCase()));
  for (const rawValue of values) {
    const value = String(rawValue ?? '').trim();
    if (!value) continue;
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    target.push(value);
  }
}

function buildProxyEnvironment(baseEnvironment = {}, systemProxy = {}) {
  const explicitHTTP = firstExplicit(baseEnvironment, 'HTTP_PROXY');
  const explicitHTTPS = firstExplicit(baseEnvironment, 'HTTPS_PROXY');
  const explicitALL = firstExplicit(baseEnvironment, 'ALL_PROXY');
  const explicitSOCKS = firstExplicit(baseEnvironment, 'SOCKS_PROXY');
  const explicitNoProxy = [
    baseEnvironment.NO_PROXY,
    baseEnvironment.no_proxy
  ].filter(value => typeof value === 'string' && value.trim());

  const http = explicitHTTP ?? (explicitALL || explicitSOCKS ? null : systemProxy.http ?? null);
  const https = explicitHTTPS ?? (explicitALL || explicitSOCKS ? null : systemProxy.https ?? null);
  const all = explicitALL ?? explicitSOCKS ?? ((http || https) ? null : systemProxy.socks ?? null);

  const noProxyValues = [];
  addUnique(noProxyValues, explicitNoProxy.flatMap(value => value.split(',')));
  addUnique(noProxyValues, LOOPBACK_EXCEPTIONS);
  addUnique(noProxyValues, (Array.isArray(systemProxy.exceptions) ? systemProxy.exceptions : [])
    .map(normalizeSystemException).filter(Boolean));
  const noProxy = noProxyValues.join(',');

  const environment = Object.create(null);
  for (const [key, value] of [
    ['HTTP_PROXY', http],
    ['HTTPS_PROXY', https],
    ['ALL_PROXY', all],
    ['NO_PROXY', noProxy]
  ]) {
    if (value == null || value === '') continue;
    environment[key] = value;
    environment[key.toLowerCase()] = value;
  }

  return environment;
}

function stableSignature(environment) {
  return JSON.stringify(Object.keys(environment).sort().map(key => [key, environment[key]]));
}

function withProxyEnvironment(environment, action) {
  const previous = new Map();
  for (const key of PROXY_KEYS) {
    previous.set(key, Object.hasOwn(process.env, key) ? process.env[key] : undefined);
    delete process.env[key];
  }
  for (const [key, value] of Object.entries(environment)) process.env[key] = value;

  try {
    return action();
  } finally {
    for (const key of PROXY_KEYS) {
      const previousValue = previous.get(key);
      if (previousValue === undefined) delete process.env[key];
      else process.env[key] = previousValue;
    }
  }
}

function isUnsupportedParameterError(error) {
  const message = String(error?.message ?? error ?? '').toLowerCase();
  return /invalid\s+params?|invalid\s+parameter|unknown\s+(?:field|parameter|property)|unrecognized\s+(?:field|parameter|property)|unexpected\s+(?:field|parameter|property)|additional\s+propert/.test(message);
}

function installNetworkAdapter(AppServerClient, options = {}) {
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

  const baseEnvironment = { ...(options.baseEnvironment ?? process.env) };
  const readSystemProxy = options.resolveSystemProxy ?? resolveSystemProxy;
  const mergeRateLimitsResponse = options.mergeRateLimitsResponse ?? agent.mergeRateLimitsResponse;
  const states = new WeakMap();

  function stateFor(client) {
    let state = states.get(client);
    if (!state) {
      state = { accountReady: false, proxySignature: null, startPromise: null };
      states.set(client, state);
    }
    return state;
  }

  function currentProxyConfiguration() {
    let systemProxy = {};
    try {
      systemProxy = readSystemProxy() ?? {};
    } catch {
      systemProxy = {};
    }
    const environment = buildProxyEnvironment(baseEnvironment, systemProxy);
    return { environment, signature: stableSignature(environment) };
  }

  async function refreshAccountAndLimits(client, state, args) {
    if (!state.accountReady) {
      const account = await client.request('account/read', { refreshToken: false });
      if (!account || (account.requiresOpenaiAuth === true && account.account == null)) {
        throw new Error('Codex app-server has no signed-in ChatGPT account');
      }
      state.accountReady = true;
    }

    const params = { excludeResetCreditDetails: true };
    let response;
    try {
      response = await client.request('account/rateLimits/read', params);
    } catch (error) {
      if (!isUnsupportedParameterError(error)) throw error;
      response = await client.request('account/rateLimits/read');
    }

    client.rateLimits = mergeRateLimitsResponse(null, response);
    client.emit('rate-limits', client.rateLimits);
    return client.rateLimits;
  }

  async function networkStart(...args) {
    const state = stateFor(this);
    if (state.startPromise) return state.startPromise;
    if (this.child) return originals.start.apply(this, args);

    const timeout = Number(this.requestTimeoutMs);
    this.requestTimeoutMs = Number.isFinite(timeout)
      ? Math.max(timeout, MIN_RPC_TIMEOUT_MS)
      : MIN_RPC_TIMEOUT_MS;

    const proxy = currentProxyConfiguration();
    state.proxySignature = proxy.signature;
    state.startPromise = Promise.resolve().then(() => withProxyEnvironment(
      proxy.environment,
      () => originals.start.apply(this, args)
    ));
    try {
      return await state.startPromise;
    } finally {
      state.startPromise = null;
    }
  }

  async function networkRefresh(...args) {
    const state = stateFor(this);
    if (!state.startPromise) {
      const proxy = currentProxyConfiguration();
      if (this.child && state.proxySignature !== proxy.signature) {
        await networkStop.call(this);
        await networkStart.call(this);
        return this.rateLimits;
      }
    }
    return refreshAccountAndLimits(this, state, args);
  }

  function networkStop(...args) {
    const state = stateFor(this);
    state.accountReady = false;
    state.proxySignature = null;
    state.startPromise = null;
    return originals.stop.apply(this, args);
  }

  Object.defineProperties(prototype, {
    start: { value: networkStart, configurable: true, writable: true },
    refresh: { value: networkRefresh, configurable: true, writable: true },
    stop: { value: networkStop, configurable: true, writable: true }
  });

  const patch = {
    uninstall() {
      if (prototype.start !== networkStart) return;
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

async function main() {
  installSharedQuotaAdapter(agent.AppServerClient);
  return agent.main();
}

module.exports = {
  buildProxyEnvironment,
  installNetworkAdapter,
  isUnsupportedParameterError,
  installSharedQuotaAdapter,
  main,
  parseScutilProxyOutput,
  resolveSystemProxy
};

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`network agent failed: ${error?.message ?? 'unknown error'}\n`);
    process.exitCode = 1;
  });
}
