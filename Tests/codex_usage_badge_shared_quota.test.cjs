'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const test = require('node:test');

const agent = require('../Resources/CodexUsageBadge/agent.cjs');
const {
  MAX_PAYLOAD_BYTES,
  PORT_TIMEOUT_MS,
  currentFingerprint,
  fingerprintForIdentity,
  installSharedQuotaAdapter
} = require('../Resources/CodexUsageBadge/shared-quota.cjs');

const PINNED_AGENT_SHA256 = 'd6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db';
const FUNCTION_SHA256 = {
  installProjectColors: '317b03ec71c69152a483a74339261bc3af5862e347cedda2e302add33d111506',
  installThreadTokens: '062eaf3025419b9dd585406c7cc0b5966c6a4217b7915f1da22b0efb7d627148',
  ThreadTokenReader: '441b591c5cf4f08b4092de4c2e43d34dc6bae659a29e1b58961e63703816d657'
};
const NOW = Date.UTC(2026, 9, 29, 12, 0, 0);
const COCOA_EPOCH_OFFSET_SECONDS = 978307200;

class TrapAppServerClient extends EventEmitter {
  constructor() {
    super();
    this.child = null;
    this.rateLimits = null;
    this.originalStartCalls = 0;
    this.originalRefreshCalls = 0;
    this.requestCalls = 0;
    this.originalStopCalls = 0;
  }

  async start() {
    this.originalStartCalls += 1;
    throw new Error('original start must not run');
  }

  async refresh() {
    this.originalRefreshCalls += 1;
    throw new Error('original refresh must not run');
  }

  async request() {
    this.requestCalls += 1;
    throw new Error('request must not run');
  }

  stop() {
    this.originalStopCalls += 1;
    this.child = null;
  }
}

function createCodexHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'badge-shared-quota-'));
  return {
    home,
    environment: { CODEX_HOME: home },
    writeAuth(accountId, shape = 'tokens') {
      const auth = shape === 'root'
        ? { auth_mode: 'chatgpt', account_id: accountId }
        : { auth_mode: 'chatgpt', tokens: { account_id: accountId } };
      fs.writeFileSync(path.join(home, 'auth.json'), JSON.stringify(auth), { mode: 0o600 });
    },
    cleanup() {
      fs.rmSync(home, { recursive: true, force: true });
    }
  };
}

function identityFingerprint(home, accountId) {
  const canonicalHome = fs.realpathSync.native(home);
  return fingerprintForIdentity(canonicalHome, accountId);
}

function quotaResponse(accountId) {
  return {
    ...(accountId === undefined ? {} : { accountId }),
    planType: 'plus',
    rateLimits: {
      limitId: 'codex',
      primary: { usedPercent: 32, windowDurationMins: 300, resetsAt: 1_800_000_000 },
      secondary: { usedPercent: 12, windowDurationMins: 10_080, resetsAt: 1_800_000_000 }
    }
  };
}

function sharedSnapshot(home, accountId, options = {}) {
  const nowMilliseconds = options.nowMilliseconds ?? NOW;
  return {
    quotaSourceVersion: options.version ?? 1,
    accountFingerprint: options.fingerprint ?? identityFingerprint(home, accountId),
    rateLimitsJSON: options.rateLimitsJSON ?? JSON.stringify(quotaResponse(options.rawAccountId)),
    updatedAt: options.updatedAt ?? nowMilliseconds / 1000 - COCOA_EPOCH_OFFSET_SECONDS,
    ...(options.extra ?? {})
  };
}

function createServer(responder) {
  const state = { calls: 0 };
  const sockets = new Set();
  const server = net.createServer(socket => {
    state.calls += 1;
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    let response;
    try {
      response = typeof responder === 'function' ? responder(state.calls) : responder;
    } catch {
      socket.destroy();
      return;
    }
    if (response === null) {
      socket.destroy();
      return;
    }
    if (response === 'hang') return;
    socket.end(response);
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve({
        port: server.address().port,
        state,
        close: () => new Promise(done => {
          for (const socket of sockets) socket.destroy();
          server.close(() => done());
        })
      });
    });
  });
}

function encoded(snapshot) {
  return JSON.stringify(snapshot);
}

function createAdapter(client, home, ports, options = {}) {
  return installSharedQuotaAdapter(TrapAppServerClient, {
    environment: { CODEX_HOME: home },
    ports,
    timeoutMs: 60,
    now: () => NOW,
    ...options
  });
}

test('computes the fixed SHA-256 identity vector and reads auth.json without exposing the account ID', t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('example-account');

  assert.equal(
    fingerprintForIdentity('/tmp/example', 'example-account'),
    '29ad60ec2bf92ac3140ac1dfaa43f7c1c2f6edad15120a2ee18edf482f97bb8c'
  );
  assert.equal(
    fingerprintForIdentity('/tmp/example', ' example-account '),
    '29ad60ec2bf92ac3140ac1dfaa43f7c1c2f6edad15120a2ee18edf482f97bb8c'
  );
  const identityBefore = fs.readFileSync(path.join(home.home, 'auth.json'), 'utf8');
  const fingerprint = currentFingerprint({ environment: home.environment });

  assert.equal(fingerprint, identityFingerprint(home.home, 'example-account'));
  assert.equal(fs.readFileSync(path.join(home.home, 'auth.json'), 'utf8'), identityBefore);
});

test('accepts auth.json account_id fallback and tilde-expanded CODEX_HOME', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'badge-shared-home-'));
  const codexHome = path.join(root, 'codex');
  fs.mkdirSync(codexHome);
  fs.writeFileSync(path.join(codexHome, 'auth.json'), JSON.stringify({
    auth_mode: 'chatgpt',
    account_id: '  root-account  '
  }), { mode: 0o600 });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const fingerprint = currentFingerprint({
    environment: { CODEX_HOME: '~/codex' },
    homeDirectory: root
  });
  assert.equal(fingerprint, identityFingerprint(codexHome, 'root-account'));
});

test('loads a direct SharedUsageSnapshot and emits normal merged rate-limits', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-a');
  const response = quotaResponse();
  const server = await createServer(encoded(sharedSnapshot(home.home, 'account-a', {
    rateLimitsJSON: JSON.stringify(response)
  })));
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());
  const events = [];
  client.on('rate-limits', value => events.push(value));

  await client.start();

  assert.equal(client.child, null);
  assert.equal(events.length, 1);
  assert.equal(events[0].rateLimits.primary.usedPercent, 32);
  assert.equal(events[0].rateLimits.secondary.windowDurationMins, 10_080);
  assert.equal(Object.hasOwn(events[0], 'accountId'), false);
});

test('accepts LocalUsageSnapshotPayload wrapper and skips stale, future, malformed, and wrong-version data', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-b');
  let payload = encoded({ snapshot: sharedSnapshot(home.home, 'account-b'), languageCode: 'en' });
  const server = await createServer(() => payload);
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await client.start();
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);

  const stale = sharedSnapshot(home.home, 'account-b', { nowMilliseconds: NOW - 151_000 });
  payload = encoded(stale);
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);

  const future = sharedSnapshot(home.home, 'account-b', { nowMilliseconds: NOW + 5_001 });
  payload = encoded(future);
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);

  payload = '{bad-json';
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);

  payload = encoded(sharedSnapshot(home.home, 'account-b', { version: 2 }));
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);

  payload = encoded(sharedSnapshot(home.home, 'account-b', {
    rateLimitsJSON: JSON.stringify({ planType: 'plus', rateLimits: { limitId: 'codex', primary: null } })
  }));
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);
});

test('rejects unknown identity and a raw quota accountId that conflicts with auth.json', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-c');
  let payload = encoded(sharedSnapshot(home.home, 'account-c', { fingerprint: '0'.repeat(64) }));
  const server = await createServer(() => payload);
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await assert.rejects(client.start(), /No fresh, valid Monitor quota snapshot/);

  payload = encoded(sharedSnapshot(home.home, 'account-c', { rawAccountId: 'account-other' }));
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);

  payload = encoded(sharedSnapshot(home.home, 'account-c', { rawAccountId: ' account-c ' }));
  await client.refresh();
  assert.equal(JSON.stringify(client.rateLimits).includes('account-c'), false);
});

test('rejects the previous account quota after auth.json switches accounts', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-old');
  let payload = encoded(sharedSnapshot(home.home, 'account-old', { rawAccountId: 'account-old' }));
  const server = await createServer(() => payload);
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());
  let eventCount = 0;
  client.on('rate-limits', () => { eventCount += 1; });

  await client.start();
  assert.equal(eventCount, 1);

  home.writeAuth('account-new');
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);
  assert.equal(client.rateLimits, null);
  assert.equal(eventCount, 1);

  payload = encoded(sharedSnapshot(home.home, 'account-new', { rawAccountId: 'account-new' }));
  await client.refresh();
  assert.equal(eventCount, 2);
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);
  assert.equal(JSON.stringify(client.rateLimits).includes('account-new'), false);
});

test('rejects a stale account snapshot when auth.json switches during the TCP read', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-before');
  const stalePayload = encoded(sharedSnapshot(home.home, 'account-before'));
  const freshPayload = encoded(sharedSnapshot(home.home, 'account-after'));
  let firstConnection = true;
  const server = await createServer(() => {
    if (firstConnection) {
      firstConnection = false;
      home.writeAuth('account-after');
      return stalePayload;
    }
    return freshPayload;
  });
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());
  let eventCount = 0;
  client.on('rate-limits', () => { eventCount += 1; });

  await assert.rejects(client.start(), /identity changed during shared quota read/);
  assert.equal(client.rateLimits, null);
  assert.equal(eventCount, 0);

  await client.refresh();
  assert.equal(eventCount, 1);
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);
});

test('rejects quota reads while auth.json has no verified ChatGPT account', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  const server = await createServer(encoded(sharedSnapshot(home.home, 'account-h')));
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await assert.rejects(client.start(), /Current Codex account identity is unavailable/);
  home.writeAuth('account-h');
  await client.refresh();
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);
});

test('accepts exactly 64 KiB and rejects payloads one byte larger', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-d');
  const base = sharedSnapshot(home.home, 'account-d');
  const emptyPadding = encoded({ ...base, padding: '' });
  const exact = encoded({
    ...base,
    padding: 'x'.repeat(MAX_PAYLOAD_BYTES - Buffer.byteLength(emptyPadding, 'utf8'))
  });
  assert.equal(Buffer.byteLength(exact, 'utf8'), MAX_PAYLOAD_BYTES);

  let payload = exact;
  const server = await createServer(() => payload);
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await client.start();
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);

  payload = exact + ' ';
  assert.equal(Buffer.byteLength(payload, 'utf8'), MAX_PAYLOAD_BYTES + 1);
  await assert.rejects(client.refresh(), /No fresh, valid Monitor quota snapshot/);
});

test('uses the 750 ms per-port timeout and closes an unanswered socket', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-timeout');
  const server = await createServer('hang');
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port], { timeoutMs: 40 });
  t.after(() => uninstall());

  const startedAt = Date.now();
  await assert.rejects(client.start(), /No fresh, valid Monitor quota snapshot/);
  const elapsedMs = Date.now() - startedAt;

  assert.equal(PORT_TIMEOUT_MS, 750);
  assert.equal(server.state.calls, 1);
  assert.ok(elapsedMs >= 25 && elapsedMs < 1_000, 'test timeout should settle promptly');
});

test('stop prevents a late shared read from emitting rate-limits', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-stop');
  const payload = encoded(sharedSnapshot(home.home, 'account-stop'));
  let serverCalls = 0;
  const server = net.createServer(socket => {
    serverCalls += 1;
    setTimeout(() => socket.end(payload), 50);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise(done => server.close(() => done())));

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.address().port], { timeoutMs: 200 });
  t.after(() => uninstall());
  let eventCount = 0;
  client.on('rate-limits', () => { eventCount += 1; });
  const connected = new Promise(resolve => server.once('connection', resolve));
  const pending = client.start();

  await connected;
  client.stop();
  await assert.rejects(pending, /Shared quota read was stopped/);

  assert.equal(serverCalls, 1);
  assert.equal(eventCount, 0);
  assert.equal(client.rateLimits, null);
});

test('falls back through all three loopback ports and succeeds on the last one', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-e');

  const first = await createServer('{');
  const second = await createServer('x'.repeat(MAX_PAYLOAD_BYTES + 1));
  const third = await createServer(encoded(sharedSnapshot(home.home, 'account-e')));
  t.after(async () => {
    await Promise.all([first.close(), second.close(), third.close()]);
  });

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [first.port, second.port, third.port]);
  t.after(() => uninstall());

  await client.start();

  assert.deepEqual([first.state.calls, second.state.calls, third.state.calls], [1, 1, 1]);
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);
});

test('recovers after a disconnected Monitor without restarting the badge client', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-f');
  let disconnected = true;
  const server = await createServer(() => disconnected ? null : encoded(sharedSnapshot(home.home, 'account-f')));
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await assert.rejects(client.start(), /No fresh, valid Monitor quota snapshot/);
  disconnected = false;
  await client.refresh();

  assert.equal(server.state.calls, 2);
  assert.equal(client.rateLimits.rateLimits.primary.usedPercent, 32);
});

test('shared mode never invokes app-server start, refresh, or request methods', async t => {
  const home = createCodexHome();
  t.after(() => home.cleanup());
  home.writeAuth('account-g');
  const server = await createServer(encoded(sharedSnapshot(home.home, 'account-g')));
  t.after(() => server.close());

  const client = new TrapAppServerClient();
  const uninstall = createAdapter(client, home.home, [server.port]);
  t.after(() => uninstall());

  await client.start();
  await client.refresh();
  client.stop();

  assert.equal(client.originalStartCalls, 0);
  assert.equal(client.originalRefreshCalls, 0);
  assert.equal(client.requestCalls, 0);
  assert.equal(client.originalStopCalls, 1);
  assert.equal(client.child, null);
});

test('keeps the pinned canonical agent, thread-token, and project-color functions unchanged', () => {
  const activePath = path.resolve(__dirname, '../Resources/CodexUsageBadge/agent.cjs');
  const agentHash = crypto.createHash('sha256').update(fs.readFileSync(activePath)).digest('hex');
  assert.equal(agentHash, PINNED_AGENT_SHA256);

  for (const [name, expectedHash] of Object.entries(FUNCTION_SHA256)) {
    const actualHash = crypto.createHash('sha256').update(String(agent[name])).digest('hex');
    assert.equal(actualHash, expectedHash, name + ' changed');
  }
});
