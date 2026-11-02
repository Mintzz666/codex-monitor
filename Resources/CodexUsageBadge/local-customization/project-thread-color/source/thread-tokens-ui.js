function installThreadTokens() {
  const VERSION = 12;
  const KEY = '__codexThreadTokens';
  const ROW = '[data-app-action-sidebar-thread-row][data-app-action-sidebar-thread-id]';
  const PROJECT_ROW = '[data-app-action-sidebar-project-row][data-app-action-sidebar-project-id]';
  const PROJECT_CONTAINER = '[data-sidebar-project-container-id^="project:"]';
  const MARK = 'data-codex-thread-tokens';
  if (window[KEY]?.version === VERSION) { window[KEY].refresh(); return; }
  window[KEY]?.destroy?.();
  let snapshot = { ok: false, totals: {}, projectNames: {}, checkedAt: null };
  let received = false;
  let disposed = false;
  let refreshTimer = null;
  let tooltipTimer = null;
  let hovered = null;
  let pointer = null;
  const badges = new Map();
  const projectPalette = [
    ['red', '#cf4b43', '#ff5f57'], ['orange', '#b76c10', '#ff9f0a'], ['yellow', '#92700b', '#ffd60a'],
    ['green', '#268347', '#30d158'], ['blue', '#2674bf', '#0a84ff'], ['purple', '#9950c0', '#bf5af2'], ['gray', '#717980', '#98989d']
  ];
  const shadeMix = [18, 34, 54, 78, 100];
  const style = document.createElement('style');
  style.id = 'codex-thread-tokens-style';
  style.textContent = `
    [${MARK}] { --token-0: #d6dce2; --token-1: #c4d5ec; --token-2: #90b2e1; --token-3: #5e90d0; --token-4: #2f6ebf;
      position: relative; display: inline-block; align-self: center; flex: 0 0 12px; width: 12px; height: 12px;
      margin-inline-end: 8px; vertical-align: middle;
      box-sizing: border-box; border-radius: 3px; border: 0; background: var(--token-0);
      cursor: inherit; user-select: none; -webkit-app-region: no-drag; }
    [${MARK}]::before { content: ''; position: absolute; inset: -6px; }
    html.dark [${MARK}], html[data-theme="dark"] [${MARK}] {
      --token-0: #282828; --token-1: #1d293e; --token-2: #223b60; --token-3: #27528c; --token-4: #2d70ca; }
    @media (prefers-color-scheme: dark) {
      html:not(.light):not([data-theme="light"]) [${MARK}] {
        --token-0: #282828; --token-1: #1d293e; --token-2: #223b60; --token-3: #27528c; --token-4: #2d70ca;
      }
      html:not(.light):not([data-theme="light"]) #codex-thread-tokens-tooltip {
        background: var(--color-surface-elevated-secondary, #2c2e2c); color: var(--color-text-primary, #edf0ed);
      }
    }
    [${MARK}][data-level="1"] { background: var(--token-1); }
    [${MARK}][data-level="2"] { background: var(--token-2); }
    [${MARK}][data-level="3"] { background: var(--token-3); }
    [${MARK}][data-level="4"] { background: var(--token-4); }
    ${projectPalette.flatMap(([id, light]) => shadeMix.map((mix, level) =>
      `[${MARK}][data-project-color="${id}"][data-level="${level}"] { background: color-mix(in srgb, ${light} ${mix}%, #ffffff); }`)).join('\n')}
    ${projectPalette.flatMap(([id, , dark]) => shadeMix.map((mix, level) =>
      `html.dark [${MARK}][data-project-color="${id}"][data-level="${level}"], html[data-theme="dark"] [${MARK}][data-project-color="${id}"][data-level="${level}"] { background: color-mix(in srgb, ${dark} ${mix}%, #282828) !important; }`)).join('\n')}
    @media (prefers-color-scheme: dark) {
      ${projectPalette.flatMap(([id, , dark]) => shadeMix.map((mix, level) =>
        `html:not(.light):not([data-theme="light"]) [${MARK}][data-project-color="${id}"][data-level="${level}"] { background: color-mix(in srgb, ${dark} ${mix}%, #282828) !important; }`)).join('\n')}
    }
    #codex-thread-tokens-tooltip { position: fixed; z-index: 2147483000; pointer-events: none; box-sizing: border-box;
      max-width: min(300px, calc(100vw - 16px)); padding: 9px 12px; border-radius: 9px; border: 1px solid #8883;
      box-shadow: 0 4px 18px #0002; background: var(--color-surface-elevated-secondary, #f8f8f7);
      color: var(--color-text-primary, #303630); white-space: pre-line; font: 12px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; }
    html.dark #codex-thread-tokens-tooltip, html[data-theme="dark"] #codex-thread-tokens-tooltip {
      background: var(--color-surface-elevated-secondary, #2c2e2c); color: var(--color-text-primary, #edf0ed); }
    #codex-thread-tokens-tooltip[hidden] { display: none !important; }
  `;
  const tooltip = document.createElement('div'); tooltip.id = 'codex-thread-tokens-tooltip'; tooltip.setAttribute('role', 'tooltip'); tooltip.hidden = true;
  let projectAssignments = new Map();
  function identity(row) {
    const key = row.getAttribute('data-app-action-sidebar-thread-id') ?? '';
    const host = row.getAttribute('data-app-action-sidebar-thread-host-id');
    const kind = row.getAttribute('data-app-action-sidebar-thread-kind');
    const match = /^local:([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$/i.exec(key);
    return { key, id: match && host === 'local' && kind === 'local' ? match[1] : null };
  }
  function projectContext(row) {
    const container = row.closest(PROJECT_CONTAINER);
    if (!container) return null;
    const containerId = container.getAttribute('data-sidebar-project-container-id') ?? '';
    if (!containerId.startsWith('project:')) return null;
    const projectId = containerId.slice('project:'.length);
    if (!projectId) return null;
    const matches = [...container.querySelectorAll(PROJECT_ROW)].filter(projectRow =>
      projectRow.closest(PROJECT_CONTAINER) === container &&
      projectRow.getAttribute('data-app-action-sidebar-project-id') === projectId);
    if (matches.length !== 1) return null;
    const projectRow = matches[0];
    const api = window.__codexProjectColors;
    if (typeof api?.colorForProjectRow !== 'function') return null;
    const kind = projectRow.querySelector('[data-sidebar-project-kind]')?.getAttribute('data-sidebar-project-kind')
      ?? projectRow.closest('[data-sidebar-project-kind]')?.getAttribute('data-sidebar-project-kind') ?? 'project';
    return { key: `${kind}:${projectId}`, color: api.colorForProjectRow(projectRow) };
  }
  function buildProjectAssignments(rows) {
    const assignments = new Map();
    for (const row of rows) {
      const id = identity(row).id;
      if (!id) continue;
      const context = projectContext(row);
      if (!context) continue;
      const current = assignments.get(id);
      if (!current) assignments.set(id, context);
      else if (current.key !== context.key) assignments.set(id, { ambiguous: true });
    }
    return assignments;
  }
  function markerSlot(title) {
    // ChatGPT Work wraps thread titles in several block-level spans. Inserting
    // beside the outer title creates a new flex/line item and distorts the list.
    // Anchor beside its inline text run instead, without moving or wrapping text.
    const walker = document.createTreeWalker(title, NodeFilter.SHOW_TEXT);
    let textNode = null;
    while (walker.nextNode()) textNode = walker.currentNode;
    const leaf = textNode?.parentElement;
    if (!leaf) return null;
    const leafDisplay = getComputedStyle(leaf).display;
    if (leafDisplay.startsWith('inline') && leaf.parentElement &&
        getComputedStyle(leaf.parentElement).display.startsWith('inline')) {
      return { parent: leaf.parentElement, before: leaf };
    }
    if (['block', 'flow-root', 'inline', 'inline-block', 'list-item', 'table-cell'].includes(leafDisplay)) {
      return { parent: leaf, before: textNode };
    }
    return null;
  }
  function level(total) {
    // Fixed thresholds keep the same color when the sidebar list changes.
    if (total === 0) return 0;
    if (total < 1e6) return 1;
    if (total < 1e7) return 2;
    if (total < 1e8) return 3;
    return 4;
  }
  function formatTokens(total) {
    const units = [[1e8, '亿'], [1e7, '千万'], [1e4, '万']];
    for (let i = 0; i < units.length; i++) {
      const [divisor, suffix] = units[i];
      if (total < divisor) continue;
      const rounded = Number((total / divisor).toFixed(2));
      if (i > 0 && rounded * divisor >= units[i - 1][0]) return `1${units[i - 1][1]}`;
      return `${rounded}${suffix}`;
    }
    return total.toLocaleString('zh-CN');
  }
  function reading(row) {
    const { id } = identity(row);
    if (!id) return { state: 'unknown', detail: '此会话暂无可读取的本地 Token 记录' };
    const stale = Number.isFinite(snapshot.checkedAt) && Date.now() - snapshot.checkedAt > 30000;
    if (stale) return { state: 'stale', detail: 'Token 用量数据已过期，正在等待重新连接' };
    const total = snapshot.totals[id];
    if (!received) return { state: 'unknown', detail: '正在读取会话累计 Token' };
    if (!snapshot.ok) return { state: 'unknown', detail: '暂时无法读取本地 Token 记录，正在自动重试' };
    if (!Number.isSafeInteger(total) || total < 0) return { state: 'unknown', detail: '此会话暂无可读取的本地 Token 记录' };
    return { level: level(total), state: 'ready', detail: `累计使用 ${formatTokens(total)} Token` };
  }
  function hideTooltip() { clearTimeout(tooltipTimer); tooltipTimer = null; hovered = null; tooltip.hidden = true; }
  function positionTooltip() {
    if (!hovered?.isConnected) { hideTooltip(); return; }
    const r = hovered.getBoundingClientRect();
    tooltip.style.left = `${Math.max(8, Math.min(r.left, innerWidth - tooltip.offsetWidth - 8))}px`;
    const top = r.bottom + 8 + tooltip.offsetHeight <= innerHeight - 8 ? r.bottom + 8 : r.top - tooltip.offsetHeight - 8;
    tooltip.style.top = `${Math.max(8, top)}px`;
  }
  function render(row, badge) {
    const value = reading(row);
    const id = identity(row).id;
    const assignment = id ? projectAssignments.get(id) : null;
    const projectName = id ? snapshot.projectNames?.[id] : null;
    const projectColor = assignment
      ? (assignment.ambiguous ? null : assignment.color)
      : (projectName ? window.__codexProjectColors?.colorForProjectName?.(projectName) : null);
    if (badge.textContent) badge.textContent = '';
    const colorLevel = String(value.level ?? 0);
    if (badge.dataset.level !== colorLevel) badge.dataset.level = colorLevel;
    if (projectColor) {
      if (badge.dataset.projectColor !== projectColor) badge.dataset.projectColor = projectColor;
    } else if (badge.hasAttribute('data-project-color')) badge.removeAttribute('data-project-color');
    if (badge.dataset.state !== value.state) badge.dataset.state = value.state;
    const label = value.detail.replaceAll('\n', '，');
    if (badge.getAttribute('aria-label') !== label) badge.setAttribute('aria-label', label);
    if (badge.dataset.tooltip !== value.detail) badge.dataset.tooltip = value.detail;
    if (hovered === badge && !tooltip.hidden) {
      if (tooltip.textContent !== value.detail) tooltip.textContent = value.detail;
      positionTooltip();
    }
  }
  function refresh() {
    if (disposed || !document.body) return;
    if (!style.isConnected) (document.head ?? document.documentElement).append(style);
    if (!tooltip.isConnected) document.body.append(tooltip);
    const rows = [...document.querySelectorAll(ROW)];
    projectAssignments = buildProjectAssignments(rows);
    const owned = new Set(badges.values());
    for (const badge of document.querySelectorAll(`[${MARK}]`)) if (!owned.has(badge)) badge.remove();
    for (const [row, badge] of badges) {
      const title = row.querySelector('[data-thread-title]');
      const slot = title && markerSlot(title);
      if (!row.isConnected || !row.matches(ROW) || !slot || badge.parentNode !== slot.parent || badge.nextSibling !== slot.before) {
        if (hovered === badge) hideTooltip(); badge.remove(); badges.delete(row);
      }
    }
    for (const row of rows) {
      const title = row.querySelector('[data-thread-title]');
      if (!title?.parentElement) continue;
      const slot = markerSlot(title);
      if (!slot) continue;
      let badge = badges.get(row);
      if (!badge) {
        // Insert into the title's inline text flow; never wrap or move React content.
        badge = document.createElement('span'); badge.setAttribute(MARK, ''); badge.setAttribute('role', 'img');
        badge.setAttribute('aria-describedby', tooltip.id);
        slot.parent.insertBefore(badge, slot.before); badges.set(row, badge);
      }
      render(row, badge);
    }
    syncHover();
  }
  function scheduleRefresh() {
    if (disposed || refreshTimer !== null) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; refresh(); }, 80);
  }
  function badgeAtPointer() {
    if (!pointer || document.hidden) return null;
    const el = document.elementFromPoint(pointer.x, pointer.y);
    const badge = el?.closest(`[${MARK}]`);
    return badge && badges.get(badge.closest(ROW)) === badge ? badge : null;
  }
  function syncHover() {
    const badge = badgeAtPointer();
    if (badge === hovered) return;
    hideTooltip();
    if (!badge) return;
    hovered = badge;
    tooltipTimer = setTimeout(() => {
      tooltipTimer = null;
      if (badgeAtPointer() !== hovered || !hovered?.isConnected) { hideTooltip(); return; }
      tooltip.textContent = hovered.dataset.tooltip; tooltip.hidden = false; positionTooltip();
    }, 150);
  }
  function onPointer(event) {
    if (event.pointerType === 'touch') return;
    if (event.buttons) { clearHover(); return; }
    pointer = { x: event.clientX, y: event.clientY };
    syncHover();
  }
  function onOut(event) { if (!event.relatedTarget) clearHover(); }
  function clearHover() { pointer = null; hideTooltip(); }
  function onKey(event) { if (event.key === 'Escape') clearHover(); }
  function onLayout(event) {
    // Streaming replies scroll the conversation pane, not the sidebar hover target.
    if (event.type === 'scroll' && event.target instanceof Element) {
      const badge = hovered ?? badgeAtPointer();
      if (!badge || !event.target.contains(badge)) return;
    }
    hideTooltip(); scheduleRefresh();
  }
  const observer = new MutationObserver(records => {
    if (records.some(r => !r.target.closest?.(`[${MARK}]`) && r.target !== tooltip && !tooltip.contains(r.target) && r.target !== style)) scheduleRefresh();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true,
    attributeFilter: ['data-app-action-sidebar-thread-id', 'data-app-action-sidebar-thread-host-id', 'data-app-action-sidebar-thread-kind',
      'data-app-action-sidebar-project-id', 'data-sidebar-project-kind', 'data-sidebar-project-container-id'] });
  const freshnessTimer = setInterval(() => { for (const [row, badge] of badges) render(row, badge); }, 1000);
  // Capture before the native sidebar can stop bubbling; movement also repairs missed enters.
  document.addEventListener('pointerover', onPointer, true);
  document.addEventListener('pointermove', onPointer, true);
  document.addEventListener('pointerout', onOut, true);
  document.addEventListener('pointerdown', clearHover, true);
  document.addEventListener('keydown', onKey);
  document.addEventListener('visibilitychange', clearHover);
  document.addEventListener('scroll', onLayout, true);
  window.addEventListener('resize', onLayout);
  window.addEventListener('blur', clearHover);
  window[KEY] = {
    version: VERSION, refresh,
    requestedIds() { return [...new Set([...document.querySelectorAll(ROW)].map(row => identity(row).id).filter(Boolean))].slice(0, 2000); },
    update(next) {
      snapshot = { ok: next?.ok === true, checkedAt: Number.isFinite(next?.checkedAt) ? next.checkedAt : null,
        totals: next?.totals && typeof next.totals === 'object' ? next.totals : {},
        projectNames: next?.projectNames && typeof next.projectNames === 'object' ? next.projectNames : {} };
      received = true; refresh();
    },
    status() { return { version: VERSION, badges: [...badges.values()].filter(el => el.isConnected).length,
      available: [...badges.values()].filter(el => el.isConnected && el.dataset.state === 'ready').length,
      projectMapped: [...badges].filter(([row, badge]) => {
        const id = identity(row).id;
        return badge.isConnected && (!!snapshot.projectNames?.[id] || !!projectAssignments.get(id));
      }).length,
      projectResolved: [...badges].filter(([row, badge]) => {
        if (!badge.isConnected) return false;
        const id = identity(row).id;
        const assignment = projectAssignments.get(id);
        if (assignment) return !assignment.ambiguous;
        const name = snapshot.projectNames?.[id];
        return badge.isConnected && !!name && !!window.__codexProjectColors?.hasUniqueProjectName?.(name);
      }).length,
      projectColored: [...badges.values()].filter(el => el.isConnected && !!el.dataset.projectColor).length,
      source: 'local-session-total', checkedAt: snapshot.checkedAt, ok: snapshot.ok }; },
    destroy() {
      disposed = true; observer.disconnect(); clearTimeout(refreshTimer); clearInterval(freshnessTimer); hideTooltip();
      document.removeEventListener('pointerover', onPointer, true); document.removeEventListener('pointermove', onPointer, true);
      document.removeEventListener('pointerout', onOut, true); document.removeEventListener('pointerdown', clearHover, true);
      document.removeEventListener('keydown', onKey); document.removeEventListener('visibilitychange', clearHover);
      document.removeEventListener('scroll', onLayout, true); window.removeEventListener('resize', onLayout);
      window.removeEventListener('blur', clearHover);
      for (const badge of badges.values()) badge.remove(); badges.clear(); style.remove(); tooltip.remove(); delete window[KEY];
    }
  };
  refresh();
}
