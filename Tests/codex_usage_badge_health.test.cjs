'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { assessHealth } = require('../Resources/CodexUsageBadge/health.cjs');
const { classifyNetwork, parseScutilProxy, resolveProxy } = require('../Resources/CodexUsageBadge/network-health.cjs');

function healthyFixture(overrides = {}) {
  return {
    monitor: { installed: true, running: true, signatureValid: true },
    quotaSnapshotFresh: true,
    badgeBundleHashValid: true,
    badgeActiveHashValid: true,
    badgeManagerHashValid: true,
    badgeActiveFilesValid: true,
    badgeAgentRunning: true,
    badgeStartupAgentRunning: true,
    chatGPTInstalled: true,
    cdpReachable: true,
    mainWindowCount: 1,
    injectedWindowCount: 1,
    ...overrides
  };
}

test('full Monitor-to-ChatGPT chain is healthy', () => {
  assert.deepEqual(assessHealth(healthyFixture()), { overall: 'healthy', errors: [] });
});

test('a stale or missing snapshot is attributed to the quota bridge', () => {
  const result = assessHealth(healthyFixture({ quotaSnapshotFresh: false }));
  assert.equal(result.overall, 'attention');
  assert.deepEqual(result.errors, ['quota_snapshot_unavailable_or_stale']);
});

test('a stopped Badge agent is distinct from a UI injection failure', () => {
  const result = assessHealth(healthyFixture({ badgeAgentRunning: false }));
  assert.ok(result.errors.includes('badge_agent_not_running'));
  assert.ok(!result.errors.includes('badge_ui_not_confirmed'));
});

test('an unavailable ChatGPT debug port is classified separately', () => {
  const result = assessHealth(healthyFixture({ cdpReachable: false, mainWindowCount: 0, injectedWindowCount: 0 }));
  assert.ok(result.errors.includes('chatgpt_debug_port_unreachable'));
  assert.ok(!result.errors.includes('badge_ui_not_confirmed'));
});

test('a stopped startup watcher is detected even when the injection agent is running', () => {
  const result = assessHealth(healthyFixture({ badgeStartupAgentRunning: false }));
  assert.deepEqual(result.errors, ['badge_startup_agent_not_running']);
});

test('a connected debug port without verified modules is not accepted as injection', () => {
  const result = assessHealth(healthyFixture({ injectedWindowCount: 0 }));
  assert.deepEqual(result.errors, ['badge_ui_not_confirmed']);
});

test('system proxy and DNS failures are classified as network layers', () => {
  const settings = parseScutilProxy('HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7897');
  assert.deepEqual(settings, { HTTPSEnable: '1', HTTPSProxy: '127.0.0.1', HTTPSPort: '7897' });
  assert.equal(resolveProxy({}, settings)?.port, 7897);
  const report = {
    defaultRouteAvailable: true,
    proxy: { configured: true, listenerReachable: false },
    dns: { 'chatgpt.com': false, 'api.openai.com': false },
    https: { 'chatgpt.com': { reachable: false }, 'api.openai.com': { reachable: false } }
  };
  assert.equal(classifyNetwork(report), 'proxy_unreachable');
  report.proxy.listenerReachable = true;
  assert.equal(classifyNetwork(report), 'dns_unavailable');
});

test('proxy authentication errors are not mislabeled as DNS or general outage', () => {
  const report = {
    defaultRouteAvailable: true,
    proxy: { configured: true, listenerReachable: true },
    dns: { 'chatgpt.com': true, 'api.openai.com': true },
    https: {
      'chatgpt.com': { reachable: false, proxyAuthRequired: true },
      'api.openai.com': { reachable: false, proxyAuthRequired: true }
    }
  };
  assert.equal(classifyNetwork(report), 'proxy_auth_required');
});
