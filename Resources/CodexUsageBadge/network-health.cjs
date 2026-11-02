'use strict';

const dns = require('node:dns').promises;
const net = require('node:net');
const os = require('node:os');
const { execFileSync, spawnSync } = require('node:child_process');

const PROXY_SETTINGS = '/usr/sbin/scutil';
const TARGETS = ['chatgpt.com', 'api.openai.com'];
const LOCAL_PORTS = [51872, 51873, 51874, 39222];

function parseScutilProxy(text) {
  const values = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$/);
    if (match) values[match[1]] = match[2];
  }
  return values;
}

function parseProxyURL(value, fallbackScheme = 'http') {
  if (!value) return null;
  try {
    const url = new URL(value.includes('://') ? value : `${fallbackScheme}://${value}`);
    const isSocks = url.protocol === 'socks5:' || url.protocol === 'socks5h:';
    const port = Number(url.port || (url.protocol === 'https:' ? 443 : isSocks ? 1080 : 80));
    if (!url.hostname || !Number.isInteger(port) || port < 1 || port > 65535) return null;
    const scheme = url.protocol === 'socks5:' || url.protocol === 'socks5h:'
      ? 'socks5h'
      : url.protocol === 'https:' ? 'https' : 'http';
    return { scheme, host: url.hostname, port, hasCredentials: Boolean(url.username || url.password) };
  } catch {
    return null;
  }
}

function resolveProxy(environment = process.env, scutil = {}) {
  const inherited = environment.https_proxy || environment.HTTPS_PROXY
    || environment.http_proxy || environment.HTTP_PROXY
    || environment.all_proxy || environment.ALL_PROXY;
  if (inherited) {
    const parsed = parseProxyURL(inherited);
    if (parsed) return { ...parsed, source: 'environment' };
  }
  if (scutil.HTTPSProxy && scutil.HTTPSPort && scutil.HTTPSEnable === '1') {
    const parsed = parseProxyURL(`${scutil.HTTPSProxy}:${scutil.HTTPSPort}`, 'http');
    if (parsed) return { ...parsed, source: 'system' };
  }
  if (scutil.HTTPProxy && scutil.HTTPPort && scutil.HTTPEnable === '1') {
    const parsed = parseProxyURL(`${scutil.HTTPProxy}:${scutil.HTTPPort}`, 'http');
    if (parsed) return { ...parsed, source: 'system' };
  }
  if (scutil.SOCKSProxy && scutil.SOCKSPort && scutil.SOCKSEnable === '1') {
    const parsed = parseProxyURL(`${scutil.SOCKSProxy}:${scutil.SOCKSPort}`, 'socks5h');
    if (parsed) return { ...parsed, source: 'system' };
  }
  return null;
}

function tcpReachable(host, port, timeoutMs = 1600) {
  return new Promise(resolve => {
    const socket = net.createConnection({ host, port });
    let done = false;
    const finish = value => {
      if (done) return;
      done = true;
      socket.destroy();
      resolve(value);
    };
    socket.setTimeout(timeoutMs, () => finish(false));
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
  });
}

async function portReachable(port) {
  return tcpReachable('127.0.0.1', port, 650);
}

async function dnsReachable(host) {
  try {
    return (await dns.lookup(host, { all: true })).length > 0;
  } catch {
    return false;
  }
}

function defaultRouteAvailable() {
  try {
    const result = execFileSync('/sbin/route', ['-n', 'get', 'default'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2500
    });
    return /^\s*interface:\s*\S+/m.test(result);
  } catch {
    return false;
  }
}

function httpsProbe(host, proxy) {
  const args = ['--silent', '--show-error', '--head', '--connect-timeout', '3', '--max-time', '9',
    '--output', '/dev/null', '--write-out', '%{http_code}'];
  if (proxy) {
    const proxyURL = `${proxy.scheme}://${proxy.host.includes(':') ? `[${proxy.host}]` : proxy.host}:${proxy.port}`;
    args.push('--proxy', proxyURL);
  } else {
    args.push('--noproxy', '*');
  }
  args.push(`https://${host}/`);
  const result = spawnSync('/usr/bin/curl', args, {
    encoding: 'utf8', timeout: 11000, maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' }
  });
  const code = Number((result.stdout || '').trim());
  return {
    reachable: result.status === 0 && Number.isInteger(code) && code >= 100 && code <= 599 && code !== 407,
    httpStatus: Number.isInteger(code) && code >= 100 && code <= 599 ? code : null,
    proxyAuthRequired: code === 407,
    timedOut: result.error?.code === 'ETIMEDOUT' || /timed out/i.test(result.stderr || '')
  };
}

function classifyNetwork(report) {
  if (!report.defaultRouteAvailable) return 'no_default_route';
  if (report.proxy.configured && report.proxy.listenerReachable === false) return 'proxy_unreachable';
  if (Object.values(report.https).some(result => result.reachable)) return 'reachable';
  if (Object.values(report.https).every(result => !result.reachable)) {
    if (Object.values(report.https).some(result => result.proxyAuthRequired)) return 'proxy_auth_required';
    if (Object.values(report.dns).every(ok => !ok)) return 'dns_unavailable';
    return 'https_unavailable';
  }
  return 'https_unavailable';
}

function hostMatchesException(host, pattern) {
  const normalized = String(pattern).trim().toLowerCase().replace(/^\*\./, '.');
  if (!normalized || normalized === '<local>') return normalized === '<local>' && !host.includes('.');
  if (normalized === '*') return true;
  const domain = normalized.replace(/^\./, '');
  return host === domain || host.endsWith(`.${domain}`);
}

function bypassesProxy(host, environment, rawSystemSettings) {
  const envExceptions = (environment.no_proxy || environment.NO_PROXY || '')
    .split(',').map(value => value.trim()).filter(Boolean);
  if (envExceptions.some(pattern => hostMatchesException(host, pattern))) return true;
  const systemExceptions = rawSystemSettings.match(/(?:\*\.)?[A-Za-z0-9.-]+/g) || [];
  return systemExceptions.some(pattern => hostMatchesException(host, pattern));
}

async function collectNetworkHealth() {
  let rawSettings = '';
  try {
    rawSettings = execFileSync(PROXY_SETTINGS, ['--proxy'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2500
    });
  } catch {}
  const systemProxy = parseScutilProxy(rawSettings);
  const proxy = resolveProxy(process.env, systemProxy);
  const listenerReachable = proxy ? await tcpReachable(proxy.host, proxy.port) : null;
  const dnsResults = Object.fromEntries(await Promise.all(TARGETS.map(async host => [host, await dnsReachable(host)])));
  const httpsResults = Object.fromEntries(TARGETS.map(host => {
    const bypass = bypassesProxy(host, process.env, rawSettings);
    const result = httpsProbe(host, bypass ? null : proxy);
    return [host, { ...result, route: bypass ? 'direct-bypass' : proxy ? proxy.source : 'direct' }];
  }));
  const localResults = Object.fromEntries(await Promise.all(LOCAL_PORTS.map(async port => [String(port), await portReachable(port)])));
  const report = {
    checkedAt: new Date().toISOString(),
    defaultRouteAvailable: defaultRouteAvailable(),
    activeNetworkInterface: Object.values(os.networkInterfaces()).some(items =>
      items?.some(item => !item.internal && (item.family === 'IPv4' || item.family === 4))),
    proxy: {
      configured: Boolean(proxy),
      source: proxy?.source ?? 'direct',
      kind: proxy?.scheme ?? 'direct',
      listenerReachable,
      credentialsConfigured: Boolean(proxy?.hasCredentials)
    },
    dns: dnsResults,
    https: httpsResults,
    localPorts: localResults
  };
  report.classification = classifyNetwork(report);
  return report;
}

if (require.main === module) {
  collectNetworkHealth().then(report => process.stdout.write(JSON.stringify(report) + '\n')).catch(() => {
    process.stdout.write(JSON.stringify({ checkedAt: new Date().toISOString(), classification: 'diagnostic_failed' }) + '\n');
    process.exitCode = 1;
  });
}

module.exports = { bypassesProxy, classifyNetwork, hostMatchesException, parseScutilProxy, parseProxyURL, resolveProxy };
