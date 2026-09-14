import type { FastifyInstance } from 'fastify';
import { db } from './db.js';
import { isUuid, newId, nowIso } from './util.js';

export interface GroupRow {
  id: string;
  name: string;
  parent_id: string | null;
  created_at: string;
  count?: number;
}

export function groupExists(id: unknown): boolean {
  return isUuid(id) && !!db.prepare('SELECT 1 FROM groups WHERE id = ?').get(id);
}

function parentOf(id: string): string | null {
  const row = db.prepare('SELECT parent_id FROM groups WHERE id = ?').get(id) as
    | { parent_id: string | null }
    | undefined;
  return row?.parent_id ?? null;
}

// 目标分组的全部后代（含自身），用于"点父分组看子分组笔记"
export function descendantGroupIds(rootId: string): string[] {
  const all = db.prepare('SELECT id, parent_id FROM groups').all() as {
    id: string;
    parent_id: string | null;
  }[];
  const result = [rootId];
  let frontier = [rootId];
  while (frontier.length) {
    const next = all.filter((g) => g.parent_id && frontier.includes(g.parent_id)).map((g) => g.id);
    result.push(...next);
    frontier = next;
  }
  return result;
}

function listGroups() {
  const rows = db
    .prepare(
      `SELECT g.*, (SELECT COUNT(*) FROM notes n WHERE n.group_id = g.id AND n.deleted_at IS NULL) AS count
       FROM groups g ORDER BY g.created_at, g.name`,
    )
    .all() as unknown as GroupRow[];
  return rows.map((g) => ({
    id: g.id,
    name: g.name,
    parentId: g.parent_id,
    createdAt: g.created_at,
    count: g.count ?? 0,
  }));
}

function validName(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const name = v.trim();
  return name.length >= 1 && name.length <= 50 ? name : null;
}

export async function groupRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/groups', async () => ({ groups: listGroups() }));

  app.post('/api/groups', async (req, reply) => {
    const { name, parentId } = (req.body ?? {}) as Record<string, unknown>;
    const n = validName(name);
    if (!n) return reply.code(400).send({ error: '分组名需 1-50 个字符' });
    if (parentId != null && !groupExists(parentId)) {
      return reply.code(400).send({ error: '父分组不存在' });
    }
    const id = newId();
    db.prepare('INSERT INTO groups (id, name, parent_id, created_at) VALUES (?,?,?,?)').run(
      id,
      n,
      (parentId as string) ?? null,
      nowIso(),
    );
    return reply.code(201).send({
      group: { id, name: n, parentId: (parentId as string) ?? null, count: 0 },
    });
  });

  app.put('/api/groups/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    if (!groupExists(id)) return reply.code(404).send({ error: '分组不存在' });
    const { name, parentId } = (req.body ?? {}) as Record<string, unknown>;
    const n = validName(name);
    if (!n) return reply.code(400).send({ error: '分组名需 1-50 个字符' });
    if (parentId != null) {
      if (!groupExists(parentId)) return reply.code(400).send({ error: '父分组不存在' });
      if (parentId === id) return reply.code(400).send({ error: '分组不能作为自己的父分组' });
      let p = parentOf(parentId as string);
      while (p) {
        if (p === id) return reply.code(400).send({ error: '不能把分组移动到自己的子分组下' });
        p = parentOf(p);
      }
    }
    db.prepare('UPDATE groups SET name = ?, parent_id = ? WHERE id = ?').run(
      n,
      parentId != null ? (parentId as string) : null,
      id,
    );
    return { ok: true };
  });

  app.delete('/api/groups/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    if (!groupExists(id)) return reply.code(404).send({ error: '分组不存在' });
    // 子分组升为一级、组内笔记移到未分组，均由外键 ON DELETE SET NULL 完成
    db.prepare('DELETE FROM groups WHERE id = ?').run(id);
    return { ok: true };
  });
}
