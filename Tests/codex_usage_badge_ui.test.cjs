'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const agent = require('../Resources/CodexUsageBadge/agent.cjs');

function createBadgeDocument(height = 270) {
  let document;

  class FakeElement {
    constructor(tagName) {
      this.tagName = tagName.toUpperCase();
      this.parentElement = null;
      this.childNodes = [];
      this.attributes = new Map();
      this.dataset = Object.create(null);
      this.style = Object.create(null);
      this.className = '';
      this.id = '';
      this.hidden = false;
      this._textContent = '';
      this.listeners = new Map();
    }

    get children() { return this.childNodes; }
    get isConnected() {
      let element = this;
      while (element) {
        if (element === document.documentElement) return true;
        element = element.parentElement;
      }
      return false;
    }
    get nextElementSibling() {
      if (!this.parentElement) return null;
      const siblings = this.parentElement.children;
      return siblings[siblings.indexOf(this) + 1] ?? null;
    }
    get offsetWidth() { return this.id === 'codex-usage-tooltip' ? 120 : 0; }
    get offsetHeight() { return this.id === 'codex-usage-tooltip' ? 60 : 0; }
    get textContent() {
      return this.childNodes.length ? this.childNodes.map(child => child.textContent).join('') : this._textContent;
    }
    set textContent(value) {
      this.childNodes = [];
      this._textContent = String(value);
    }
    set innerHTML(markup) {
      this._innerHTML = markup;
      this.childNodes = [];
      const add = (tag, className = '', text = '') => {
        const element = document.createElement(tag);
        element.className = className;
        if (text) element.textContent = text;
        this.append(element);
        return element;
      };
      if (this.className === 'usage-primary' || this.className === 'usage-secondary') {
        const ring = add('svg', 'usage-ring');
        const value = document.createElement('circle');
        value.className = 'usage-ring-value';
        ring.append(value);
        add('span', 'usage-number', '—');
        add('span', 'usage-window');
      } else if (this.className === 'usage-combined') {
        const rings = add('div', 'gemini-rings');
        for (const [ringName, valueName] of [
          ['gemini-ring-five-hour', 'gemini-five-hour-value'],
          ['gemini-ring-weekly', 'gemini-weekly-value']
        ]) {
          const ring = document.createElement('svg');
          ring.className = `gemini-ring ${ringName}`;
          const value = document.createElement('circle');
          value.className = `gemini-value ${valueName}`;
          ring.append(value);
          rings.append(ring);
        }
        add('span', 'gemini-name', 'Gemini');
        const codex = add('div', 'codex-summary');
        addTo(codex, 'span', 'codex-label', 'Codex');
        addTo(codex, 'span', 'codex-number', '—');
      }
      function addTo(parent, tag, className, text = '') {
        const element = document.createElement(tag);
        element.className = className;
        if (text) element.textContent = text;
        parent.append(element);
        return element;
      }
    }
    get innerHTML() { return this._innerHTML ?? ''; }
    append(...elements) {
      for (const element of elements) {
        element.remove();
        element.parentElement = this;
        this.childNodes.push(element);
      }
    }
    appendChild(element) { this.append(element); return element; }
    insertBefore(element, before) {
      element.remove();
      const index = before ? this.childNodes.indexOf(before) : -1;
      element.parentElement = this;
      this.childNodes.splice(index < 0 ? this.childNodes.length : index, 0, element);
    }
    remove() {
      if (!this.parentElement) return;
      const siblings = this.parentElement.childNodes;
      const index = siblings.indexOf(this);
      if (index >= 0) siblings.splice(index, 1);
      this.parentElement = null;
    }
    contains(target) { return this === target || this.childNodes.some(child => child.contains(target)); }
    setAttribute(name, value) {
      this.attributes.set(name, String(value));
      if (name === 'id') this.id = String(value);
    }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    removeAttribute(name) { this.attributes.delete(name); }
    addEventListener(name, callback) {
      const callbacks = this.listeners.get(name) ?? [];
      callbacks.push(callback);
      this.listeners.set(name, callbacks);
    }
    removeEventListener(name) {
      this.listeners.delete(name);
    }
    dispatch(name, event = {}) {
      for (const callback of this.listeners.get(name) ?? []) callback({ target: this, key: '', ...event });
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
    querySelectorAll(selector) {
      const matches = element => {
        if (selector.startsWith('.')) return element.className.split(/\s+/).includes(selector.slice(1));
        if (selector.startsWith('#')) return element.id === selector.slice(1);
        if (selector.startsWith('nav[')) return element.tagName === 'NAV' && element.getAttribute('data-app-navigation-rail') !== null;
        if (selector === '[role="meter"]') return element.getAttribute('role') === 'meter';
        return false;
      };
      const found = [];
      const visit = element => {
        for (const child of element.childNodes) {
          if (matches(child)) found.push(child);
          visit(child);
        }
      };
      visit(this);
      return found;
    }
    getBoundingClientRect() {
      if (this.tagName === 'NAV') return { x: 0, y: 0, width: 52, height };
      const footerY = height - 70;
      if (this.className === 'footer') return { x: 8, y: footerY, width: 36, height: 60 };
      if (this.className === 'help') return { x: 10, y: footerY, width: 32, height: 32 };
      if (this.id === 'codex-usage-badge') {
        const mode = this.dataset.mode;
        const badgeHeight = mode === 'dual' ? 144 : 84;
        const width = 34;
        return { x: (52 - width) / 2, y: footerY - badgeHeight - 8, width, height: badgeHeight, right: (52 + width) / 2, top: footerY - badgeHeight - 8 };
      }
      return { x: 0, y: 0, width: this.isConnected ? 1 : 0, height: this.isConnected ? 1 : 0, right: 1, top: 0 };
    }
  }

  document = {
    hidden: false,
    createElement: tag => new FakeElement(tag),
    addEventListener() {},
    removeEventListener() {},
    querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  };
  const html = document.createElement('html');
  const head = document.createElement('head');
  const body = document.createElement('body');
  html.append(head, body);
  document.documentElement = html;
  document.head = head;
  document.body = body;
  const rail = document.createElement('nav');
  rail.setAttribute('data-app-navigation-rail', 'true');
  const list = document.createElement('div');
  const footer = document.createElement('div');
  footer.className = 'footer';
  const help = document.createElement('button');
  help.className = 'help';
  footer.append(help);
  rail.append(list, footer);
  body.append(rail);
  return { document, rail, footer, help };
}

function createBadgeRuntime(height = 270) {
  const { document, rail, footer, help } = createBadgeDocument(height);
  const window = { addEventListener() {}, removeEventListener() {} };
  class Observer { observe() {} unobserve() {} disconnect() {} }
  const sandbox = {
    window, document, innerWidth: 320, innerHeight: height,
    getComputedStyle: element => ({ visibility: 'visible', position: element.style.position ?? 'static' }),
    MutationObserver: Observer, ResizeObserver: Observer,
    setInterval: () => 1, clearInterval() {}, setTimeout, clearTimeout
  };
  vm.runInNewContext(`(${agent.installUsageBadge.toString()})()`, sandbox);
  return { ...sandbox, rail, footer, help, badge: document.querySelectorAll('#codex-usage-badge')[0] };
}

const codexPlus = {
  rateLimits: {
    limitId: 'codex', planType: 'plus',
    primary: { usedPercent: 64, windowDurationMins: 300, resetsAt: 1_800_000_000 },
    secondary: { usedPercent: 27, windowDurationMins: 10080, resetsAt: 1_800_000_000 }
  }
};

test('merge and display routing preserve fresh Gemini quota beside the Codex quota', () => {
  const response = {
    ...codexPlus,
    geminiQuota: {
      weekly: { remainingPercent: 62, resetsAt: Date.now() + 3_600_000 },
      fiveHour: { remainingPercent: 91, resetsAt: Date.now() + 1_800_000 },
      fetchedAt: Date.now()
    }
  };
  const merged = agent.mergeRateLimitsResponse(null, response);
  assert.deepEqual(merged.geminiQuota, response.geminiQuota);
  const display = agent.formatRateLimits(merged);
  assert.equal(display.mode, 'combined');
  assert.equal(display.percent, 36);
  assert.equal(display.codexLabel, 'Codex 5h');
  assert.equal(display.rings, null);
  assert.deepEqual([display.geminiQuota.fiveHour.percent, display.geminiQuota.weekly.percent], [91, 62]);
  assert.match(display.title, /Gemini 周额度：剩余 62%.*重置/);
  assert.match(display.title, /Gemini 5h额度：剩余 91%.*重置/);

  const codexOnly = agent.formatRateLimits(codexPlus);
  assert.equal(codexOnly.mode, 'dual');
  assert.equal(codexOnly.geminiQuota, null);
  assert.deepEqual(codexOnly.rings.map(ring => ring.percent), [36, 73]);

  const expired = agent.formatRateLimits({ ...response, geminiQuota: { ...response.geminiQuota, fetchedAt: Date.now() - 150_001 } });
  assert.equal(expired.mode, 'dual');
  assert.equal(expired.geminiQuota, null);
});

test('combined pill keeps footer placement and accessibility, then clears stale Gemini and falls back to Codex', () => {
  const runtime = createBadgeRuntime();
  const api = runtime.window.__codexUsageBadge;
  const helpBefore = runtime.help.getBoundingClientRect();
  const response = agent.mergeRateLimitsResponse(null, {
    rateLimits: {
      limitId: 'codex', planType: 'pro',
      primary: { usedPercent: 6, windowDurationMins: 300 },
      secondary: { usedPercent: 27, windowDurationMins: 10080 }
    },
    geminiQuota: {
      weekly: { remainingPercent: 62, resetsAt: Date.now() + 3_600_000 },
      fiveHour: { remainingPercent: 91, resetsAt: Date.now() + 1_800_000 },
      fetchedAt: Date.now()
    }
  });
  const combined = agent.formatRateLimits(response);
  api.update({ ...combined, updatedAt: Date.now(), stale: false });

  assert.equal(runtime.badge.dataset.mode, 'combined');
  assert.equal(runtime.badge.parentElement, runtime.rail);
  assert.equal(runtime.badge.nextElementSibling, runtime.footer);
  assert.equal(runtime.badge.getBoundingClientRect().width, 34);
  assert.ok(runtime.badge.getBoundingClientRect().x >= 0);
  assert.ok(runtime.badge.getBoundingClientRect().x + runtime.badge.getBoundingClientRect().width <= 52);
  assert.ok(runtime.badge.getBoundingClientRect().y + runtime.badge.getBoundingClientRect().height <= helpBefore.y);
  assert.equal(runtime.help.getBoundingClientRect().y, helpBefore.y);
  assert.equal(runtime.badge.getAttribute('role'), 'group');
  assert.equal(runtime.badge.getAttribute('aria-label'), 'Gemini 与 Codex 剩余用量');
  assert.doesNotMatch(runtime.badge.querySelector('.usage-combined').innerHTML, /gemini-stats|gemini-percent/);
  assert.deepEqual(runtime.badge.querySelectorAll('[role="meter"]').map(element => element.getAttribute('aria-valuenow')), ['91', '62', '73']);
  assert.deepEqual(runtime.badge.querySelectorAll('.gemini-value').map(element => element.style.strokeDashoffset), ['9', '38']);
  assert.equal(runtime.badge.querySelector('.codex-number').textContent, '73%');
  assert.equal(runtime.badge.querySelector('.codex-label').textContent, 'Codex');
  assert.match(runtime.badge.querySelector('.usage-combined').innerHTML, /codex-label[\s\S]*codex-number/);

  runtime.badge.dispatch('focus');
  const tooltip = runtime.document.querySelectorAll('#codex-usage-tooltip')[0];
  assert.equal(tooltip.hidden, false);
  assert.match(tooltip.textContent, /Gemini 周额度[\s\S]*Codex/);
  runtime.badge.dispatch('keydown', { key: 'Escape' });
  assert.equal(tooltip.hidden, true);

  api.update({ ...combined, updatedAt: Date.now() - 150_001, stale: false });
  assert.equal(api.status().stale, true);
  assert.equal(runtime.badge.dataset.mode, 'combined');
  assert.deepEqual(runtime.badge.querySelectorAll('.gemini-value').map(element => element.style.opacity), ['0', '0']);
  assert.equal(runtime.badge.querySelector('.codex-number').textContent, '—');
  assert.equal(runtime.badge.querySelectorAll('[role="meter"]')[0].getAttribute('aria-valuenow'), null);

  api.update(agent.formatRateLimits(codexPlus));
  assert.equal(runtime.badge.dataset.mode, 'dual');
  assert.equal(runtime.badge.querySelector('.usage-primary').querySelector('.usage-number').textContent, '36%');
  assert.equal(runtime.badge.querySelector('.usage-secondary').querySelector('.usage-number').textContent, '73%');
  assert.equal(runtime.badge.getAttribute('aria-label'), 'Codex 剩余用量');
  api.destroy();
});
