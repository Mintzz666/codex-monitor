class ThreadTokenReader {
  constructor({ home = process.env.CODEX_HOME || require('node:path').join(require('node:os').homedir(), '.codex') } = {}) {
    this.home = home;
  }
  read(ids) {
    const checkedAt = Date.now();
    const totals = Object.create(null);
    const projectNames = Object.create(null);
    const requested = [...new Set(ids)].filter(id => typeof id === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id)).slice(0, 2000);
    if (!requested.length) return { ok: true, totals, projectNames, checkedAt };
    let db;
    try {
      const fs = require('node:fs');
      const path = require('node:path');
      // Follow the latest local state database; never fall back to an older account snapshot.
      const file = fs.readdirSync(this.home).filter(name => /^state_\d+\.sqlite$/.test(name))
        .sort((a, b) => Number(b.match(/\d+/)[0]) - Number(a.match(/\d+/)[0]))[0];
      if (!file) return { ok: false, totals, projectNames, checkedAt };
      const { DatabaseSync } = require('node:sqlite');
      db = new DatabaseSync(path.join(this.home, file), { readOnly: true, timeout: 200 });
      // Read only token counts, cwd/project IDs, and project roots. Never read titles,
      // messages, auth, or conversation bodies.
      const threadColumns = new Set(db.prepare('PRAGMA table_info(threads)').all().map(row => row.name));
      if (!threadColumns.has('id') || !threadColumns.has('tokens_used')) return { ok: false, totals, projectNames, checkedAt };
      const hasProjectId = threadColumns.has('project_id');
      const hasCwd = threadColumns.has('cwd');
      let roots = [];
      try {
        const rootColumns = new Set(db.prepare('PRAGMA table_info(project_roots)').all().map(row => row.name));
        if (rootColumns.has('project_id') && rootColumns.has('path')) roots = db.prepare('SELECT project_id, path FROM project_roots').all();
      } catch { /* Folder association is optional; token totals remain readable. */ }
      const projectNamesById = new Map();
      try {
        const projectColumns = new Set(db.prepare('PRAGMA table_info(projects)').all().map(row => row.name));
        if (projectColumns.has('id') && projectColumns.has('name')) {
          for (const row of db.prepare('SELECT id, name FROM projects').all()) {
            if (row.id !== null && typeof row.name === 'string' && row.name.length) projectNamesById.set(String(row.id), row.name);
          }
        }
      } catch { /* Without project labels, keep token totals and omit folder colors. */ }
      const normalizedPath = value => {
        if (typeof value !== 'string' || !path.isAbsolute(value)) return null;
        return path.resolve(value);
      };
      const projectRoots = roots.map(row => ({ projectId: row.project_id, root: normalizedPath(row.path) }))
        .filter(row => row.projectId !== null && row.root);
      const projectFor = row => {
        if (hasProjectId && row.project_id !== null && row.project_id !== undefined) return String(row.project_id);
        const cwd = hasCwd ? normalizedPath(row.cwd) : null;
        if (!cwd) return null;
        const matches = projectRoots.filter(({ root }) => cwd === root || cwd.startsWith(root.endsWith(path.sep) ? root : root + path.sep));
        if (!matches.length) return null;
        const maxLength = Math.max(...matches.map(match => match.root.length));
        const winners = new Set(matches.filter(match => match.root.length === maxLength).map(match => String(match.projectId)));
        return winners.size === 1 ? [...winners][0] : null;
      };
      for (let i = 0; i < requested.length; i += 200) {
        const chunk = requested.slice(i, i + 200);
        const fields = ['id', 'tokens_used', ...(hasProjectId ? ['project_id'] : []), ...(hasCwd ? ['cwd'] : [])];
        const rows = db.prepare(`SELECT ${fields.join(', ')} FROM threads WHERE id IN (${chunk.map(() => '?').join(',')})`).all(...chunk);
        for (const row of rows) {
          if (Number.isSafeInteger(row.tokens_used) && row.tokens_used >= 0) totals[row.id] = row.tokens_used;
          const projectId = projectFor(row);
          const projectName = projectId === null ? null : projectNamesById.get(projectId);
          if (projectName) projectNames[row.id] = projectName;
        }
      }
      return { ok: true, totals, projectNames, checkedAt };
    } catch {
      return { ok: false, totals: Object.create(null), projectNames: Object.create(null), checkedAt };
    } finally { try { db?.close(); } catch {} }
  }
}
async function refreshThreadTokens(injector, reader) {
  const sessions = [...injector.sessions.values()];
  if (!sessions.length) return;
  const requests = await Promise.all(sessions.map(async session => {
    try {
      const result = await session.evaluate('window.__codexThreadTokens?.requestedIds() ?? []');
      const ids = result?.result?.value;
      return { session, ids: Array.isArray(ids) ? ids : [] };
    } catch { return { session, ids: [] }; }
  }));
  const snapshot = reader.read(requests.flatMap(r => r.ids));
  await Promise.all(requests.map(async ({ session, ids }) => {
    const totals = Object.fromEntries(ids.filter(id => Object.hasOwn(snapshot.totals, id)).map(id => [id, snapshot.totals[id]]));
    const projectNames = Object.fromEntries(ids.filter(id => Object.hasOwn(snapshot.projectNames, id)).map(id => [id, snapshot.projectNames[id]]));
    try { await session.evaluate(`window.__codexThreadTokens?.update(${JSON.stringify({ ...snapshot, totals, projectNames })})`); } catch {}
  }));
}
