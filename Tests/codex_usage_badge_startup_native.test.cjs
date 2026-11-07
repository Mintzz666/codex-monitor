'use strict';
// Exercise the packaged watcher against a windowless disposable app, never ChatGPT.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFile, spawn} = require('node:child_process');
const {promisify} = require('node:util');
const run = promisify(execFile);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

test('packaged watcher recovers an unused background app launched before it, after eight seconds',
  {skip: process.platform !== 'darwin', timeout: 45000}, async t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'badge-login-recovery-'));
    const app = path.join(root, 'Startup Test.app');
    const macos = path.join(app, 'Contents/MacOS');
    const helper = path.join(root, 'startup-helper');
    const resource = path.resolve(__dirname, '../Resources/CodexUsageBadge');
    let watcher;
    const call = async (action, ...args) => JSON.parse((await run(path.join(helper, 'bridge'),
      [action, app, ...args.map(String)], {timeout: 35000})).stdout);
    async function until(check) {
      for (let i = 0; i < 100; i++) {
        const value = await check();
        if (value) return value;
        await sleep(100);
      }
      throw Error('Timed out waiting for isolated startup fixture');
    }
    try {
      fs.mkdirSync(macos, {recursive: true});
      fs.mkdirSync(helper);
      for (const name of ['bridge', 'controller.cjs', 'watch.cjs']) {
        fs.copyFileSync(path.join(resource, 'macos/startup', name), path.join(helper, name));
      }
      fs.chmodSync(path.join(helper, 'bridge'), 0o700);
      fs.writeFileSync(path.join(helper, 'settings.json'), JSON.stringify({app}));
      fs.writeFileSync(path.join(root, 'agent.cjs'), '// Fixture installation marker.\n');
      fs.writeFileSync(path.join(root, 'fixture.m'), '#import <AppKit/AppKit.h>\nint main(void){@autoreleasepool{NSApplication *a=NSApplication.sharedApplication;[a setActivationPolicy:NSApplicationActivationPolicyProhibited];[a run];}return 0;}\n');
      fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>fixture</string><key>CFBundleIdentifier</key><string>local.codexusagebadge.login-test-${process.pid}</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
      const sdk = (await run('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-path'])).stdout.trim();
      await run('/usr/bin/xcrun', ['clang', '-isysroot', sdk, '-fobjc-arc', '-framework', 'AppKit',
        path.join(root, 'fixture.m'), '-o', path.join(macos, 'fixture')]);
      await run('/usr/bin/open', ['-g', '-j', app]);
      const original = await until(async () => (await call('snapshot')).apps[0]);
      assert.equal(original.debugPort, null);
      await sleep(9000); // Previously the native eight-second guard rejected this.
      const before = await call('snapshot');
      if (before.inputIdleMs < Date.now() - original.launchedAt) {
        assert.equal((await call('quit', original.pid, original.key, before.inputStamp)).accepted, false,
          'Native guard must refuse recovery after user input');
        t.skip('Interactive-window guard passed; unused-window recovery needs an idle desktop');
        return;
      }
      assert.equal((await call('quit', original.pid, original.key, 'invalid-stamp')).accepted, false);
      // The disposable AppKit app has no CDP server. Isolate just the port
      // probe so a real client's port cannot make this fixture touch that client.
      // Actual occupied-port behavior is covered by startup-controller tests.
      const probe = path.join(root, 'fixture-port.cjs');
      fs.writeFileSync(probe, `const net = require('node:net');
net.createConnection = () => {
  const socket = new net.Socket();
  process.nextTick(() => socket.emit('error', Object.assign(new Error('fixture'), {code: 'ECONNREFUSED'})));
  return socket;
};\n`);
      watcher = spawn(process.execPath, ['--require', probe, path.join(helper, 'watch.cjs')], {stdio: 'ignore'});
      const receipt = await until(async () => {
        try {
          const state = JSON.parse(fs.readFileSync(path.join(helper, 'state.json')));
          return /^(reopened|skipped-active-or-background|quit-refused|canceled-by-input|reopen-canceled)$/.test(state.event) && state;
        } catch { return null; }
      });
      if (receipt.event !== 'reopened') {
        const interrupted = await call('snapshot');
        assert.notEqual(interrupted.inputStamp, before.inputStamp,
          'Recovery was refused without intervening input: ' + receipt.event);
        t.skip('User input interrupted the disposable recovery; the guard refused reopening');
        return;
      }
      assert.equal(receipt.shown, false);
      const restored = await call('snapshot');
      assert.equal(restored.apps.length, 1);
      assert.notEqual(restored.apps[0].key, original.key);
      assert.equal(restored.apps[0].debugPort, '39222');
      assert.equal(restored.frontmostPid, before.frontmostPid, 'Background restoration stole focus');
      assert.equal((await call('quit', restored.apps[0].pid, restored.apps[0].key, restored.inputStamp)).accepted, false);
    } finally {
      if (watcher && watcher.exitCode === null && watcher.signalCode === null) {
        const exited = new Promise(resolve => watcher.once('exit', resolve));
        watcher.kill('SIGTERM');
        await exited;
      }
      for (const app of (await call('snapshot')).apps) {
        try { process.kill(app.pid, 'SIGTERM'); } catch {}
      }
      await sleep(200);
      fs.rmSync(root, {recursive: true, force: true});
    }
  });
