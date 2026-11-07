'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const bundle = path.resolve(__dirname, '../Resources/CodexUsageBadge');

test('the compatibility entry point installs shared mode before starting the agent', async () => {
  const calls = [];
  class Client {}
  const sandbox = { module: { exports: {} }, require: id => {
    if (id === './agent.cjs') return { AppServerClient: Client, main: async () => calls.push('main') };
    assert.equal(id, './shared-quota.cjs', 'no network or process adapter may be loaded');
    return { installSharedQuotaAdapter: client => {
      assert.equal(client, Client);
      calls.push('shared');
    } };
  } };
  vm.runInNewContext(fs.readFileSync(path.join(bundle, 'network-agent.cjs'), 'utf8'), sandbox);
  await sandbox.module.exports.main();
  assert.deepEqual(calls, ['shared', 'main']);
});

test('packaged installer rolls back failed writes and launch jobs in a disposable home', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'monitor-install-'));
  const fixtureApp = path.join(home, 'Fixture.app');
  fs.mkdirSync(fixtureApp);
  const support = path.join(home, 'Library/Application Support/CodexUsageBadge');
  const jobs = new Set();
  let failCopy = false;
  let failJob = '';
  const execFileSync = (bin, args) => {
    if (bin === '/bin/launchctl') {
      const job = args[0] === 'bootstrap' ? path.basename(args[2], '.plist') : args[1].split('/').at(-1);
      if (args[0] === 'print') {
        if (!jobs.has(job)) throw Error('job absent');
        return 'state = running';
      }
      if (args[0] === 'bootout') { jobs.delete(job); return ''; }
      assert.equal(args[0], 'bootstrap');
      if (failJob === job) { failJob = ''; throw Error('simulated bootstrap failure'); }
      jobs.add(job);
      if (job.endsWith('.startup')) {
        const statePath = path.join(support, 'startup-helper/state.json');
        let previous = {};
        try { previous = JSON.parse(fs.readFileSync(statePath)); } catch {}
        fs.writeFileSync(statePath, JSON.stringify({
          ...previous, event: 'skipped-active-or-background', watchingAt: Date.now(), updatedAt: Date.now()
        }));
      }
      return '';
    }
    assert.ok(!['/usr/bin/open', '/usr/bin/osascript', '/usr/bin/pkill'].includes(bin), 'never restart the desktop client');
    return bin.endsWith('/bridge') ? '{"apps":[]}' : '';
  };
  const sandbox = {
    module: { exports: {} }, __dirname: bundle,
    process: { ...process, env: { ...process.env, CODEX_BADGE_APP: fixtureApp } },
    Buffer, URL, setTimeout, clearTimeout,
    console: { log() {}, warn() {} },
    require: id => {
      if (id === 'node:os') return { ...os, homedir: () => home };
      if (id === 'node:child_process') return { execFileSync };
      if (id === 'node:fs') return { ...fs, copyFileSync: (source, destination) => {
        if (failCopy && destination.endsWith('startup-helper/bridge')) {
          failCopy = false;
          throw Error('simulated write failure');
        }
        fs.copyFileSync(source, destination);
      } };
      if (id === './agent.cjs') return { resolveCodexBin: () => '/fixture/codex', isMainWindow: () => false };
      if (id === './macos/shortcuts.cjs') return { cleanupLegacyLauncher: async () => {} };
      return require(id);
    }
  };
  try {
    vm.runInNewContext(fs.readFileSync(path.join(bundle, 'manage.cjs'), 'utf8'), sandbox);
    const manager = sandbox.module.exports;
    failCopy = true;
    await assert.rejects(manager.install(), /已恢复安装前的程序文件/);
    assert.equal(jobs.size, 0);
    await manager.install();
    assert.equal(jobs.size, 2);
    const oldAgent = '// previous fixture agent';
    fs.writeFileSync(path.join(support, 'agent.cjs'), oldAgent);
    const state = path.join(support, 'startup-helper/state.json');
    for (const job of ['com.codexusagebadge.agent', 'com.codexusagebadge.startup']) {
      fs.writeFileSync(state, JSON.stringify({ lastAttemptAt: 123 }));
      failJob = job;
      await assert.rejects(manager.install(), /已恢复安装前的程序文件/);
      assert.equal(fs.readFileSync(path.join(support, 'agent.cjs'), 'utf8'), oldAgent);
      assert.equal(jobs.size, 2);
      assert.equal(JSON.parse(fs.readFileSync(state)).lastAttemptAt, 123);
    }
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
