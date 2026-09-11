import type { FastifyInstance } from 'fastify';
import type { SQLInputValue } from 'node:sqlite';
import { db, getNoteRow, noteToApi, noteToSummary, type NoteRow } from './db.js';
import { newId, nowIso } from './util.js';
import { cleanupAttachments } from './attachments.js';
import { descendantGroupIds, groupExists } from './groups.js';

const MAX_TITLE = 500;
const MAX_CONTENT = 1_500_000;
const MAX_PLAIN = 200_000;

interface NoteInput {
  type: 'text' | 'card';
  title: string;
  content: string;
  plainText: string;
  tags: string[];
  pinned: number;
  groupId?: string | null;
  enc?: boolean;
}

function parseNoteInput(body: unknown): { ok: true; value: NoteInput } | { ok: false; error: string } {
  if (!body || typeof body !== 'object') return { ok: false, error: '请求体格式错误' };
  const b = body as Record<string, unknown>;
  const type: 'text' | 'card' = b.type === 'card' ? 'card' : 'text';
  let title = typeof b.title === 'string' ? b.title.slice(0, MAX_TITLE) : '';
  let content = typeof b.content === 'string' ? b.content : '';
  if (content.length > MAX_CONTENT) return { ok: false, error: '内容过大' };
  let plainText = typeof b.plainText === 'string' ? b.plainText.slice(0, MAX_PLAIN) : '';
  // 密码卡片：默认加密；加密卡标题明文保留（可搜索），正文摘要不存；明文卡全部保留
  let enc = type === 'card';
  if (type === 'card' && 'enc' in b) {
    if (typeof b.enc !== 'boolean') return { ok: false, error: '参数格式错误' };
    enc = b.enc;
  }
  if (type === 'card' && enc) {
    if (content.length > 65536) return { ok: false, error: '卡片内容过大' };
    plainText = '';
  }
  const rawTags = Array.isArray(b.tags) ? b.tags : [];
  const tags = [
    ...new Set(
      rawTags
        .filter((t): t is string => typeof t === 'string')
        .map((t) => t.trim().slice(0, 32))
        .filter(Boolean),
    ),
  ].slice(0, 20);
  const pinned = b.pinned === true ? 1 : 0;
  let groupId: string | null | undefined;
  if ('groupId' in b) {
    if (b.groupId === null || b.groupId === undefined) groupId = null;
    else {
      if (!groupExists(b.groupId)) return { ok: false, error: '分组不存在' };
      groupId = b.groupId as string;
    }
  }
  return { ok: true, value: { type, title, content, plainText, tags, pinned, groupId, enc } };
}

function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (m) => '\\' + m)}%`;
}

// 更新前保存旧内容快照（内容有实际变化才存），每条笔记保留最近 5 个版本
const insertVersion = db.prepare(
  `INSERT INTO note_versions (note_id, title, content, plain_text, tags, version, updated_at)
   VALUES (?,?,?,?,?,?,?)`,
);
const pruneVersions = db.prepare(
  `DELETE FROM note_versions WHERE note_id = ? AND id NOT IN
   (SELECT id FROM note_versions WHERE note_id = ? ORDER BY id DESC LIMIT 5)`,
);

function snapshotVersion(row: NoteRow, newValues: NoteInput): void {
  const changed =
    row.title !== newValues.title ||
    row.content !== newValues.content ||
    row.plain_text !== newValues.plainText ||
    row.tags !== JSON.stringify(newValues.tags);
  if (!changed) return;
  insertVersion.run(
    row.id,
    row.title,
    row.content,
    row.plain_text,
    row.tags,
    row.version,
    row.updated_at,
  );
  pruneVersions.run(row.id, row.id);
}

export async function notesRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/notes', async (req) => {
    const q = req.query as Record<string, string | undefined>;
    const where: string[] = [];
    const params: SQLInputValue[] = [];
    where.push(q.trash === '1' ? 'deleted_at IS NOT NULL' : 'deleted_at IS NULL');
    if (q.pinned === '1') where.push('pinned = 1');
    if (q.tag) {
      where.push('EXISTS (SELECT 1 FROM json_each(notes.tags) je WHERE je.value = ?)');
      params.push(q.tag);
    }
    if (q.q && q.q.trim()) {
      const like = likePattern(q.q.trim());
      where.push("(title LIKE ? ESCAPE '\\' OR plain_text LIKE ? ESCAPE '\\')");
      params.push(like, like);
    }
    if (q.group === 'none') {
      where.push('group_id IS NULL');
    } else if (q.group && q.group !== 'all') {
      const ids = descendantGroupIds(q.group);
      where.push(`group_id IN (${ids.map(() => '?').join(',')})`);
      params.push(...ids);
    }
    const rows = db
      .prepare(
        `SELECT * FROM notes WHERE ${where.join(' AND ')}
         ORDER BY pinned DESC, updated_at DESC LIMIT 2000`,
      )
      .all(...params) as unknown as NoteRow[];
    return { notes: rows.map(noteToSummary) };
  });

  // App 全量同步：所有笔记（含回收站、含卡片密文），客户端本地缓存用
  app.get('/api/notes/full', async () => {
    const rows = db
      .prepare('SELECT * FROM notes ORDER BY updated_at DESC LIMIT 5000')
      .all() as unknown as NoteRow[];
    return { notes: rows.map(noteToApi) };
  });

  app.post('/api/notes', async (req, reply) => {
    const parsed = parseNoteInput(req.body);
    if (!parsed.ok) return reply.code(400).send({ error: parsed.error });
    const v = parsed.value;
    const id = newId();
    const now = nowIso();
    db.prepare(
      `INSERT INTO notes (id, type, title, content, plain_text, tags, pinned, group_id, enc, version, created_at, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,1,?,?)`,
    ).run(
      id,
      v.type,
      v.title,
      v.content,
      v.plainText,
      JSON.stringify(v.tags),
      v.pinned,
      v.groupId ?? null,
      v.enc ? 1 : 0,
      now,
      now,
    );
    return reply.code(201).send({ note: noteToApi(getNoteRow(id)!) });
  });

  app.get('/api/notes/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    return { note: noteToApi(row) };
  });

  app.put('/api/notes/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    const parsed = parseNoteInput(req.body);
    if (!parsed.ok) return reply.code(400).send({ error: parsed.error });
    const expectedVersion = (req.body as Record<string, unknown>)?.expectedVersion;
    if (typeof expectedVersion !== 'number') {
      return reply.code(400).send({ error: '缺少版本号' });
    }
    if (row.version !== expectedVersion) {
      return reply.code(409).send({ error: 'conflict', message: '笔记已在其他端修改', note: noteToApi(row) });
    }
    const v = parsed.value;
    snapshotVersion(row, v);
    const setCols = ['title = ?', 'content = ?', 'plain_text = ?', 'tags = ?', 'pinned = ?', 'version = version + 1', 'updated_at = ?'];
    const params: SQLInputValue[] = [v.title, v.content, v.plainText, JSON.stringify(v.tags), v.pinned, nowIso()];
    if (v.groupId !== undefined) {
      setCols.unshift('group_id = ?');
      params.unshift(v.groupId ?? null);
    }
    if (v.enc !== undefined) {
      setCols.unshift('enc = ?');
      params.unshift(v.enc ? 1 : 0);
    }
    params.push(id);
    db.prepare(`UPDATE notes SET ${setCols.join(', ')} WHERE id = ?`).run(...params);
    return { note: noteToApi(getNoteRow(id)!) };
  });

  // 仅改分组：不递增 version，避免拖拽移动导致别处编辑冲突
  app.post('/api/notes/:id/move', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    const { groupId } = (req.body ?? {}) as Record<string, unknown>;
    if (groupId !== null && groupId !== undefined && !groupExists(groupId)) {
      return reply.code(400).send({ error: '分组不存在' });
    }
    const gid = typeof groupId === 'string' ? groupId : null;
    db.prepare('UPDATE notes SET group_id = ?, updated_at = ? WHERE id = ?').run(
      gid,
      nowIso(),
      id,
    );
    return { note: noteToApi(getNoteRow(id)!) };
  });

  // 版本历史：列表（仅元数据）/ 单个版本内容 / 恢复到指定版本（恢复前先快照当前）
  app.get('/api/notes/:id/versions', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    const versions = db
      .prepare(
        `SELECT version, title, updated_at AS updatedAt FROM note_versions
         WHERE note_id = ? ORDER BY id DESC`,
      )
      .all(id);
    return { versions };
  });

  app.get('/api/notes/:id/versions/:version', async (req, reply) => {
    const { id, version } = req.params as Record<string, string>;
    const row = db
      .prepare('SELECT * FROM note_versions WHERE note_id = ? AND version = ? ORDER BY id DESC')
      .get(id, Number(version)) as unknown as
      | { title: string; content: string; plain_text: string; tags: string; version: number; updated_at: string }
      | undefined;
    if (!row) return reply.code(404).send({ error: '版本不存在' });
    return {
      version: {
        title: row.title,
        content: row.content,
        plainText: row.plain_text,
        tags: JSON.parse(row.tags || '[]'),
        version: row.version,
        updatedAt: row.updated_at,
      },
    };
  });

  app.post('/api/notes/:id/restore-version', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const { version } = (req.body ?? {}) as Record<string, unknown>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    if (row.deleted_at) return reply.code(400).send({ error: '回收站中的笔记不能恢复版本' });
    const snap = db
      .prepare('SELECT * FROM note_versions WHERE note_id = ? AND version = ? ORDER BY id DESC')
      .get(id, Number(version)) as unknown as
      | { title: string; content: string; plain_text: string; tags: string; version: number; updated_at: string }
      | undefined;
    if (!snap) return reply.code(404).send({ error: '版本不存在' });
    // 恢复前先把当前内容强制留档（不能走“有变化才存”的判断）
    insertVersion.run(
      row.id,
      row.title,
      row.content,
      row.plain_text,
      row.tags,
      row.version,
      row.updated_at,
    );
    pruneVersions.run(row.id, row.id);
    db.prepare(
      `UPDATE notes SET title = ?, content = ?, plain_text = ?, tags = ?, version = version + 1, updated_at = ? WHERE id = ?`,
    ).run(snap.title, snap.content, snap.plain_text, snap.tags, nowIso(), id);
    return { note: noteToApi(getNoteRow(id)!) };
  });

  app.delete('/api/notes/:id', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    if (!row.deleted_at) {
      db.prepare('UPDATE notes SET deleted_at=?, version=version+1 WHERE id=?').run(nowIso(), id);
    } else {
      db.prepare('DELETE FROM notes WHERE id=?').run(id);
      cleanupAttachments();
    }
    return { ok: true };
  });

  app.post('/api/notes/:id/restore', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    if (row.deleted_at) {
      db.prepare('UPDATE notes SET deleted_at=NULL, version=version+1 WHERE id=?').run(id);
    }
    return { note: noteToApi(getNoteRow(id)!) };
  });

  app.post('/api/notes/:id/purge', async (req, reply) => {
    const { id } = req.params as Record<string, string>;
    const row = getNoteRow(id);
    if (!row) return reply.code(404).send({ error: '笔记不存在' });
    db.prepare('DELETE FROM note_versions WHERE note_id = ?').run(id);
    db.prepare('DELETE FROM notes WHERE id=?').run(id);
    cleanupAttachments();
    return { ok: true };
  });

  app.post('/api/trash/empty', async () => {
    const ids = db.prepare('SELECT id FROM notes WHERE deleted_at IS NOT NULL').all() as {
      id: string;
    }[];
    const delVersions = db.prepare('DELETE FROM note_versions WHERE note_id = ?');
    for (const r of ids) delVersions.run(r.id);
    db.prepare('DELETE FROM notes WHERE deleted_at IS NOT NULL').run();
    cleanupAttachments();
    return { ok: true };
  });
}
