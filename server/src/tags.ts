import type { FastifyInstance } from 'fastify';
import { db } from './db.js';

function rewriteTag(oldName: string, newName: string | null): number {
  const rows = db.prepare('SELECT id, tags FROM notes').all() as { id: string; tags: string }[];
  const update = db.prepare('UPDATE notes SET tags = ? WHERE id = ?');
  let changed = 0;
  for (const row of rows) {
    let tags: unknown;
    try {
      tags = JSON.parse(row.tags);
    } catch {
      continue;
    }
    if (!Array.isArray(tags) || !tags.includes(oldName)) continue;
    const next = (tags as string[]).filter((t) => typeof t === 'string' && t !== oldName);
    if (newName && !next.includes(newName)) next.push(newName);
    update.run(JSON.stringify(next.slice(0, 20)), row.id);
    changed++;
  }
  return changed;
}

export async function tagRoutes(app: FastifyInstance): Promise<void> {
  app.put('/api/tags/:name', async (req, reply) => {
    const { name } = req.params as Record<string, string>;
    const { name: newName } = (req.body ?? {}) as Record<string, unknown>;
    if (typeof newName !== 'string' || !newName.trim() || newName.trim().length > 50) {
      return reply.code(400).send({ error: '新标签名需 1-50 个字符' });
    }
    if (newName.trim() === name) return { ok: true, changed: 0 };
    const changed = rewriteTag(name, newName.trim());
    return { ok: true, changed };
  });

  app.delete('/api/tags/:name', async (req) => {
    const { name } = req.params as Record<string, string>;
    const changed = rewriteTag(name, null);
    return { ok: true, changed };
  });
}
